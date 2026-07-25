// Integrate-and-dump correlator for GPS L1 C/A acquisition.
//
// Given a code phase, it correlates a block of received samples against the locally
// generated PRN code and returns the accumulated result. One sample is consumed per
// clock, so a 1023-sample coherent integration costs 1023 cycles plus a short code-slew
// preamble.
//
// The code phase is applied by slewing the generator forward before accumulation starts,
// rather than by storing 1023 shifted copies of the code. That is the standard hardware
// trade: a few hundred idle cycles instead of a kilobit of storage per phase hypothesis.
//
// ACC_W is parameterised so the accumulator can be narrowed deliberately and the
// resulting loss of acquisition sensitivity measured, rather than guessed at.

module correlator #(
    parameter ACC_W      = 32,
    parameter SAMPLE_W   = 32,
    parameter CODE_LEN   = 1023
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // control
    input  wire                   start,
    input  wire [4:0]             prn,
    input  wire [15:0]            num_samples,
    input  wire [10:0]            code_phase,

    // sample fetch: one sample per cycle, addressed by index
    output reg  [15:0]            sample_idx,
    input  wire signed [SAMPLE_W-1:0] sample_data,

    // results
    output reg                    busy,
    output reg                    done,
    output reg signed [ACC_W-1:0] acc
);

    localparam S_IDLE = 2'd0,
               S_SLEW = 2'd1,
               S_RUN  = 2'd2,
               S_DONE = 2'd3;

    reg [1:0]  state;
    reg [10:0] slew_cnt;
    reg [15:0] run_cnt;

    // Control for the code generator is combinational, not registered. Registering it
    // put the slew one cycle out of step with the counter, which showed up as the whole
    // acquisition peak landing one chip late: the accumulated value was exactly right,
    // it was simply attributed to the wrong phase hypothesis. Driving init/en directly
    // from the current state makes the count unambiguous: after N cycles in S_SLEW the
    // generator has advanced exactly N chips.
    reg  code_init;
    reg  code_en;
    wire code_chip;

    always @(*) begin
        code_init = (state == S_IDLE) && start;
        code_en   = (state == S_SLEW) || (state == S_RUN);
    end

    ca_code_gen u_code (
        .clk   (clk),
        .rst_n (rst_n),
        .init  (code_init),
        .en    (code_en),
        .prn   (prn),
        .chip  (code_chip)
    );

    // chip == 1 encodes the BPSK symbol -1, so correlation is an add or a subtract
    // rather than a multiply. This is why a correlator is cheap in hardware.
    wire signed [ACC_W-1:0] sample_ext = {{(ACC_W-SAMPLE_W){sample_data[SAMPLE_W-1]}},
                                          sample_data};
    wire signed [ACC_W-1:0] contrib = code_chip ? -sample_ext : sample_ext;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            acc        <= {ACC_W{1'b0}};
            sample_idx <= 16'd0;
            slew_cnt   <= 11'd0;
            run_cnt    <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        acc        <= {ACC_W{1'b0}};
                        sample_idx <= 16'd0;
                        run_cnt    <= 16'd0;
                        slew_cnt   <= code_phase;
                        busy       <= 1'b1;
                        done       <= 1'b0;
                        // code_init is asserted combinationally this cycle, so the
                        // generator is back at its all-ones state on this same edge.
                        state      <= (code_phase == 11'd0) ? S_RUN : S_SLEW;
                    end
                end

                S_SLEW: begin
                    // One advance per cycle here, so exactly code_phase chips have been
                    // consumed by the time the first sample is accumulated.
                    slew_cnt <= slew_cnt - 11'd1;
                    if (slew_cnt == 11'd1) state <= S_RUN;
                end

                S_RUN: begin
                    acc <= acc + contrib;
                    if (run_cnt == num_samples - 16'd1) begin
                        state <= S_DONE;
                    end else begin
                        run_cnt    <= run_cnt + 16'd1;
                        sample_idx <= sample_idx + 16'd1;
                    end
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
