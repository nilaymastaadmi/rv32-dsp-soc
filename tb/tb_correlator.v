// Correlator verification.
//
// Two independent checks, in increasing order of strength:
//   1. The generated code sequence must match the reference model chip for chip. If this
//      fails nothing downstream is meaningful.
//   2. A full acquisition sweep over all 1023 code phases must place its peak at the same
//      phase the reference model found, on the same noisy input samples.
//
// The second check is the real one: it exercises the datapath end to end against a signal
// that has noise in it, and its pass criterion is the answer the receiver exists to
// produce, not an intermediate value.

`timescale 1ns / 1ps

module tb_correlator;

    localparam CODE_LEN = 1023;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------- code check
    reg        cg_init = 1'b0;
    reg        cg_en   = 1'b0;
    reg [4:0]  prn     = 5'd1;
    wire       cg_chip;

    ca_code_gen u_cg (
        .clk(clk), .rst_n(rst_n), .init(cg_init), .en(cg_en), .prn(prn), .chip(cg_chip)
    );

    reg [0:0] ref_code [0:CODE_LEN-1];

    // ------------------------------------------------------------- correlator
    reg         start = 1'b0;
    reg  [15:0] num_samples = CODE_LEN;
    reg  [10:0] code_phase = 11'd0;
    wire [15:0] sample_idx;
    wire        busy, done;
    wire signed [31:0] acc;

    reg signed [31:0] samples [0:CODE_LEN-1];
    wire signed [31:0] sample_data = samples[sample_idx];

    correlator #(.ACC_W(32), .SAMPLE_W(32), .CODE_LEN(CODE_LEN)) u_corr (
        .clk(clk), .rst_n(rst_n),
        .start(start), .prn(prn),
        .num_samples(num_samples), .code_phase(code_phase),
        .sample_idx(sample_idx), .sample_data(sample_data),
        .busy(busy), .done(done), .acc(acc)
    );

    integer i;
    integer code_errors = 0;
    integer best_phase;
    reg signed [31:0] best_acc;
    integer expect_phase;
    reg [1023:0] code_file, sample_file;

    initial begin
        if (!$value$plusargs("code=%s", code_file))     code_file   = "build/gnss.code.hex";
        if (!$value$plusargs("samples=%s", sample_file))sample_file = "build/gnss.samples.hex";
        if (!$value$plusargs("expect=%d", expect_phase))expect_phase = 511;

        $readmemb(code_file, ref_code);
        $readmemh(sample_file, samples);

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- check 1: generated chips against the reference sequence ----
        @(negedge clk); cg_init = 1'b1;
        @(negedge clk); cg_init = 1'b0;

        for (i = 0; i < CODE_LEN; i = i + 1) begin
            if (cg_chip !== ref_code[i][0]) begin
                if (code_errors < 5)
                    $display("  chip %0d: rtl=%b ref=%b", i, cg_chip, ref_code[i][0]);
                code_errors = code_errors + 1;
            end
            @(negedge clk); cg_en = 1'b1;
            @(negedge clk); cg_en = 1'b0;
        end

        if (code_errors == 0)
            $display("CODE CHECK : PASS (%0d chips match the reference model)", CODE_LEN);
        else
            $display("CODE CHECK : FAIL (%0d mismatches)", code_errors);

        // ---- check 2: full acquisition sweep ----
        best_acc = 0;
        best_phase = -1;

        for (i = 0; i < CODE_LEN; i = i + 1) begin
            code_phase = i[10:0];
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            wait (done == 1'b1);
            @(posedge clk);

            if ((acc > best_acc) || (-acc > best_acc)) begin
                best_acc   = (acc[31]) ? -acc : acc;
                best_phase = i;
            end
            @(negedge clk);
        end

        $display("ACQUISITION: peak |acc| = %0d at code phase %0d (model said %0d)",
                 best_acc, best_phase, expect_phase);

        if (code_errors == 0 && best_phase == expect_phase)
            $display("RESULT     : PASS");
        else
            $display("RESULT     : FAIL");

        $finish;
    end

endmodule
