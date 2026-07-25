// Testbench for the RV32I SoC.
//
// Its only job is to produce a trace in byte-identical format to the C++ ISS, so that
// correctness is decided by `diff` rather than by a human reading waveforms. Anything
// the two models disagree about shows up as the first differing line, which names the
// exact PC and instruction that broke.

`timescale 1ns / 1ps

module tb_soc;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    wire [31:0] retire_pc, retire_insn, retire_val;
    wire [4:0]  retire_rd;
    wire        retire_we, halted;

    integer trace_fd;
    integer cycle_count = 0;
    integer max_cycles;
    integer i;

    reg [1023:0] hex_path;
    reg [1023:0] trace_path;
    reg [1023:0] vcd_path;

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

    always #5 clk = ~clk;   // 100 MHz nominal

    initial begin
        if (!$value$plusargs("hex=%s", hex_path)) begin
            $display("FATAL: pass +hex=<file>");
            $finish;
        end
        if (!$value$plusargs("trace=%s", trace_path)) trace_path = "rtl.trace";
        if (!$value$plusargs("max=%d", max_cycles))   max_cycles = 200000;

        // The ISS treats all untouched memory as zero. Explicitly zeroing here keeps the
        // two models' memory identical; without it, unwritten words read as X and the
        // mismatch would look like a core bug rather than an initialisation difference.
        for (i = 0; i < 65536; i = i + 1) dut.mem[i] = 32'd0;

        $readmemh(hex_path, dut.mem);

        trace_fd = $fopen(trace_path, "w");
        if (trace_fd == 0) begin
            $display("FATAL: cannot open trace file");
            $finish;
        end

        if ($value$plusargs("vcd=%s", vcd_path)) begin
            $dumpfile("dump.vcd");
            $dumpvars(0, tb_soc);
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;         // release reset away from an active edge
    end

    // One line per retiring instruction. Reading the retire_* signals inside a posedge
    // block yields their pre-edge values, which is precisely the instruction committing
    // on this edge.
    always @(posedge clk) begin
        if (rst_n && !halted) begin
            $fwrite(trace_fd, "%08x %08x %2d %08x\n",
                    retire_pc, retire_insn, retire_rd, retire_val);
            cycle_count = cycle_count + 1;

            if (cycle_count >= max_cycles) begin
                $display("TIMEOUT after %0d instructions", cycle_count);
                $fclose(trace_fd);
                $finish;
            end
        end
    end

    // Halt is observed one edge after the SYSTEM instruction retires, so the trace
    // contains the ECALL itself, matching the ISS.
    always @(posedge clk) begin
        if (rst_n && halted) begin
            $display("RTL: retired %0d instruction(s), halted", cycle_count);
            $fwrite(trace_fd, "");
            $fclose(trace_fd);
            dump_regs;
            $finish;
        end
    end

    task dump_regs;
        integer r;
        begin
            for (r = 0; r < 32; r = r + 4) begin
                $display("  x%0d=%08x  x%0d=%08x  x%0d=%08x  x%0d=%08x",
                    r,   (r==0)   ? 32'd0 : dut.core.regs[r],
                    r+1, dut.core.regs[r+1],
                    r+2, dut.core.regs[r+2],
                    r+3, dut.core.regs[r+3]);
            end
        end
    endtask

endmodule
