// SoC-level UART test: the CPU drives the UART peripheral through its register interface
// while tx is looped back to rx, so the whole path (core -> bus -> UART -> wire -> UART ->
// bus -> core) is exercised rather than the peripheral in isolation.
//
// Results are dumped as plain text for the Python host controller to score, which keeps the
// pass/fail decision outside the testbench: the same vectors and the same expected values
// live in one place on the host side, and the RTL never gets to grade its own work.

`timescale 1ns / 1ps

module tb_soc_uart;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [31:0] retire_pc, retire_insn, retire_val;
    wire [4:0]  retire_rd;
    wire        retire_we, halted;
    wire        uart_tx, uart_rx;

    // The loopback itself. On a bench this is a jumper between two pins; here it is one
    // wire, and the RTL cannot tell the difference.
    assign uart_rx = uart_tx;

    soc_top dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .retire_pc   (retire_pc),
        .retire_insn (retire_insn),
        .retire_rd   (retire_rd),
        .retire_val  (retire_val),
        .retire_we   (retire_we),
        .halted      (halted),
        .uart_tx_pin (uart_tx),
        .uart_rx_pin (uart_rx)
    );

    integer i, fd, cycles = 0, max_cycles;
    integer count, pass_n, fail_n;
    reg [1023:0] hex_path, vec_path, out_path;

    initial begin
        if (!$value$plusargs("hex=%s", hex_path)) begin
            $display("FATAL: pass +hex=<file>");
            $finish;
        end
        if (!$value$plusargs("vectors=%s", vec_path)) vec_path = "build/uart_vectors.hex";
        if (!$value$plusargs("out=%s", out_path))     out_path = "build/uart_results.txt";
        if (!$value$plusargs("max=%d", max_cycles))   max_cycles = 50_000_000;

        for (i = 0; i < 65536; i = i + 1) dut.mem[i] = 32'd0;
        $readmemh(hex_path, dut.mem);
        // Vectors land at 0x5000: word 0 is the count, then one test byte per word.
        $readmemh(vec_path, dut.mem, 32'h5000 >> 2);

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && !halted) begin
            cycles = cycles + 1;
            if (cycles >= max_cycles) begin
                $display("TIMEOUT after %0d cycles", cycles);
                $finish;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && halted) begin
            count  = dut.mem[32'h5000 >> 2];
            pass_n = dut.mem[32'h6000 >> 2];
            fail_n = dut.mem[32'h6004 >> 2];

            $display("SoC UART test: %0d vectors, %0d pass, %0d fail, %0d cycles",
                     count, pass_n, fail_n, cycles);

            fd = $fopen(out_path, "w");
            $fwrite(fd, "count %0d\n", count);
            $fwrite(fd, "pass %0d\n", pass_n);
            $fwrite(fd, "fail %0d\n", fail_n);
            $fwrite(fd, "cycles %0d\n", cycles);
            for (i = 0; i < count; i = i + 1)
                $fwrite(fd, "rx %0d %0d\n", i, dut.mem[(32'h7000 >> 2) + i]);
            $fclose(fd);

            $finish;
        end
    end

endmodule
