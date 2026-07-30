// SoC-level neural-network inference test: the CPU runs the quantised MLP out of its own
// memory, either with the software shift-add multiply or by driving the MAC accelerator,
// and the resulting int32 logits are dumped for the Python host to score.
//
// Same principle as the UART test: the pass/fail decision lives on the host, where the
// quantised reference model is, and the RTL never grades its own work. The testbench's only
// jobs are to preload the vector count, run to halt, and write out what came back.
//
// Separate from tb_soc.v rather than a plusarg on it, following tb_soc_uart.v, because it
// needs to poke an input word before reset and read a result block back out afterwards.

`timescale 1ns / 1ps

module tb_soc_nn;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    wire [31:0] retire_pc, retire_insn, retire_val;
    wire [4:0]  retire_rd;
    wire        retire_we, halted;
    wire        uart_tx, uart_rx;

    assign uart_rx = uart_tx;   // unused here; tied so the port is not left floating

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

    // Must match firmware/soc.h.
    localparam RESULT_COUNT = 32'h0001_0000;
    localparam RESULT_MAGIC = 32'h0001_0004;
    localparam RESULT_LOGIT = 32'h0001_0008;
    localparam NVEC_ADDR    = 32'h0002_0000;
    localparam NN_MAGIC     = 32'h4E4E_3831;

    integer i, k, fd, cycles = 0, retired = 0, max_cycles;
    integer nvec_req, out_dim, count, magic;
    reg [1023:0] hex_path, out_path;

    initial begin
        if (!$value$plusargs("hex=%s", hex_path)) begin
            $display("FATAL: pass +hex=<file>");
            $finish;
        end
        if (!$value$plusargs("out=%s", out_path))   out_path = "build/nn_results.txt";
        if (!$value$plusargs("nvec=%d", nvec_req))  nvec_req = 0;   // 0 => firmware default
        if (!$value$plusargs("out_dim=%d", out_dim)) out_dim = 10;
        if (!$value$plusargs("max=%d", max_cycles)) max_cycles = 200_000_000;

        for (i = 0; i < 65536; i = i + 1) dut.mem[i] = 32'd0;
        $readmemh(hex_path, dut.mem);

        // How many inferences to run. Supplied here rather than compiled in so the same
        // firmware image can be measured at two vector counts, which is what separates
        // fixed startup cost from the per-inference steady state.
        dut.mem[NVEC_ADDR >> 2] = nvec_req;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
    end

    always @(posedge clk) begin
        if (rst_n && !halted) begin
            cycles  = cycles + 1;
            retired = retired + 1;
            if (cycles >= max_cycles) begin
                $display("TIMEOUT after %0d cycles", cycles);
                $finish;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n && halted) begin
            count = dut.mem[RESULT_COUNT >> 2];
            magic = dut.mem[RESULT_MAGIC >> 2];

            $display("NN: %0d inference(s), %0d cycles, %0d instructions retired",
                     count, cycles, retired);
            // Verilog-2005 has no adjacent-string-literal concatenation, so this stays on
            // one line rather than being split the way the C sources are.
            if (magic !== NN_MAGIC)
                $display("WARNING: sentinel %08x != %08x, firmware did not finish main()", magic, NN_MAGIC);

            fd = $fopen(out_path, "w");
            $fwrite(fd, "count %0d\n", count);
            $fwrite(fd, "cycles %0d\n", cycles);
            $fwrite(fd, "retired %0d\n", retired);
            $fwrite(fd, "magic %08x\n", magic);
            // Logits are int32 and frequently negative. Dumped as hex so the sign survives
            // the round trip through the text file without depending on how Verilog chose
            // to format a negative integer.
            for (i = 0; i < count; i = i + 1)
                for (k = 0; k < out_dim; k = k + 1)
                    $fwrite(fd, "logit %0d %0d %08x\n", i, k,
                            dut.mem[(RESULT_LOGIT >> 2) + i * out_dim + k]);
            $fclose(fd);

            $finish;
        end
    end

endmodule
