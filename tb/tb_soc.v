// Testbench for the RV32I SoC.
//
// Primary job: produce a trace in byte-identical format to the C++ ISS, so correctness
// is decided by `diff` rather than by reading waveforms. For programs that drive the
// correlator the ISS has no counterpart peripheral, so those runs are judged instead on
// the answer the program computes and on the cycle count it took, which is what the
// hardware-versus-software comparison needs.

`timescale 1ns / 1ps

module tb_soc;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    wire [31:0] retire_pc, retire_insn, retire_val;
    wire [4:0]  retire_rd;
    wire        retire_we, halted;

    integer trace_fd = 0;
    integer retired = 0;
    integer cycles = 0;
    integer max_cycles;
    integer i;
    integer expect_phase;
    integer got_phase, got_mag;

    reg [1023:0] hex_path;
    reg [1023:0] trace_path;
    reg [1023:0] sample_path;
    reg [1023:0] code_path;
    reg          do_trace;
    reg          do_check;

    soc_top dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .retire_pc  (retire_pc),
        .retire_insn(retire_insn),
        .retire_rd  (retire_rd),
        .retire_val (retire_val),
        .retire_we  (retire_we),
        .halted     (halted)
    );

    always #5 clk = ~clk;

    initial begin
        if (!$value$plusargs("hex=%s", hex_path)) begin
            $display("FATAL: pass +hex=<file>");
            $finish;
        end
        if (!$value$plusargs("max=%d", max_cycles)) max_cycles = 20000000;

        // The ISS treats all untouched memory as zero. Zeroing here keeps the two models
        // identical; otherwise unwritten words read as X and the mismatch would look
        // like a core bug rather than an initialisation difference.
        for (i = 0; i < 65536; i = i + 1) dut.mem[i] = 32'd0;

        $readmemh(hex_path, dut.mem);

        // Optional sample block for accelerator runs, loaded at byte address 0x4000.
        if ($value$plusargs("samples=%s", sample_path))
            $readmemh(sample_path, dut.mem, 32'h4000 >> 2);

        // Optional code table at 0x8000 for the software baseline, written twice back to
        // back. The duplicate copy lets the software indexer run off the end of one
        // period into the next instead of taking a modulo every sample, which removes an
        // instruction from its inner loop and so makes the comparison generous to
        // software rather than flattering to the accelerator.
        if ($value$plusargs("code=%s", code_path)) begin
            $readmemh(code_path, dut.mem, 32'h8000 >> 2);
            $readmemh(code_path, dut.mem, (32'h8000 >> 2) + 1023);
        end

        do_trace = $value$plusargs("trace=%s", trace_path);
        if (do_trace) begin
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0) begin
                $display("FATAL: cannot open trace file");
                $finish;
            end
        end

        do_check = $value$plusargs("expect_phase=%d", expect_phase);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    // One line per retiring instruction. Reading the retire_* signals inside a posedge
    // block yields their pre-edge values, which is precisely the instruction committing
    // on this edge.
    always @(posedge clk) begin
        if (rst_n && !halted) begin
            if (do_trace)
                $fwrite(trace_fd, "%08x %08x %2d %08x\n",
                        retire_pc, retire_insn, retire_rd, retire_val);
            retired = retired + 1;
            cycles  = cycles + 1;

            if (cycles >= max_cycles) begin
                $display("TIMEOUT after %0d cycles", cycles);
                if (do_trace) $fclose(trace_fd);
                $finish;
            end
        end
    end

    // Halt is observed one edge after the SYSTEM instruction retires, so the trace
    // contains the ECALL itself, matching the ISS.
    always @(posedge clk) begin
        if (rst_n && halted) begin
            $display("RTL: retired %0d instruction(s) in %0d cycles, halted",
                     retired, cycles);
            if (do_trace) $fclose(trace_fd);

            if (do_check) begin
                got_phase = dut.mem[32'h3000 >> 2];
                got_mag   = dut.mem[32'h3004 >> 2];
                $display("ACQUISITION: phase %0d, peak magnitude %0d", got_phase, got_mag);
                if (got_phase == expect_phase)
                    $display("RESULT     : PASS (expected phase %0d)", expect_phase);
                else
                    $display("RESULT     : FAIL (expected phase %0d)", expect_phase);
            end else begin
                dump_regs;
            end
            $finish;
        end
    end

    task dump_regs;
        integer r;
        begin
            for (r = 0; r < 32; r = r + 4) begin
                $display("  x%0d=%08x  x%0d=%08x  x%0d=%08x  x%0d=%08x",
                    r,   (r==0) ? 32'd0 : dut.core.regs[r],
                    r+1, dut.core.regs[r+1],
                    r+2, dut.core.regs[r+2],
                    r+3, dut.core.regs[r+3]);
            end
        end
    endtask

endmodule
