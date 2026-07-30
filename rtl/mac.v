// INT8 dot-product unit: acc = sum over i of a[i] * b[i], both int8, accumulated in int32.
//
// Exists because the core is RV32I base with no M extension, so every multiply-accumulate
// in the neural network firmware costs a software shift-add loop. This block does four
// MACs per two clocks instead.
//
// Memory access follows the correlator's division of labour exactly: the accelerator walks
// memory itself rather than being fed operands by the CPU. That is the entire reason it
// wins -- the CPU's cost per dot product drops to a handful of register writes and a poll,
// independent of the vector length.
//
// It uses ONE memory read port, the same single async-read port the correlator uses, not
// two. Both operand streams are fetched through it on alternate cycles:
//
//   FETCH_A   drive addr = base_a + i, latch the word (4 activation bytes)
//   FETCH_B   drive addr = base_b + i, and in the same cycle multiply the four byte pairs
//             and add all four products into the accumulator
//
// so the steady-state rate is 4 terms per 2 cycles. Fetching both operands in one cycle
// would need a second read port, which a real single-port SRAM could not give; sticking to
// one port keeps this block no more optimistic about memory than the rest of the SoC
// already is. Deeper pipelining (overlapping the next fetch with the current accumulate)
// would get closer to 4 terms per cycle and is the obvious next step rather than something
// attempted here.
//
// Alignment: both base addresses must be 4-byte aligned and `len` must be a multiple of 4.
// The firmware satisfies this by construction -- every weight row is a whole number of
// words long (196 and 32 bytes) and .rodata/.bss are 4-aligned -- and the bus wrapper
// exposes an error flag if it is ever violated rather than silently computing nonsense.

module mac #(
    parameter ACC_W = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [15:0] len,          // number of int8 terms; must be a multiple of 4
    input  wire [31:0] base_a,       // byte address of the int8 activation vector
    input  wire [31:0] base_b,       // byte address of the int8 weight vector

    // single shared memory read port, byte address out, whole 32-bit word in
    output wire [31:0] mem_addr,
    input  wire [31:0] mem_data,

    output reg         busy,
    output reg         done,
    output wire signed [ACC_W-1:0] acc
);

    localparam S_IDLE = 2'd0,
               S_FA   = 2'd1,
               S_FB   = 2'd2,
               S_DONE = 2'd3;

    reg [1:0]  state;
    reg [15:0] idx;                  // byte offset into both vectors, steps by 4
    reg [31:0] a_word;
    reg signed [ACC_W-1:0] acc_r;

    assign acc = acc_r;

    // Address is driven combinationally from the state, not from a registered enable. The
    // correlator originally registered its code-generator enable and that put its phase
    // bookkeeping one cycle out of step with its own counter -- the "acquisition peak one
    // chip late" defect in the README. Driving the operand select straight off the state
    // means cycle N of S_FA fetches exactly the word S_FA is meant to fetch.
    assign mem_addr = ((state == S_FB) ? base_b : base_a) + {16'd0, idx};

    // Byte lanes, little-endian: byte at address 4k+n is bits [8n+7 : 8n] of word k, which
    // is the same lane order soc_top's per-strobe store uses.
    //
    // Each operand is pulled into its own explicitly signed wire before being multiplied.
    // That is deliberate rather than stylistic: this repo already lost a day to Verilog
    // signedness propagation, where pairing a signed and an unsigned branch in one ternary
    // made the whole expression unsigned and silently degraded >>> into >>. Self-determined
    // signed operands cannot be re-typed by their context.
    wire signed [7:0] a0 = a_word[7:0];
    wire signed [7:0] a1 = a_word[15:8];
    wire signed [7:0] a2 = a_word[23:16];
    wire signed [7:0] a3 = a_word[31:24];

    wire signed [7:0] b0 = mem_data[7:0];
    wire signed [7:0] b1 = mem_data[15:8];
    wire signed [7:0] b2 = mem_data[23:16];
    wire signed [7:0] b3 = mem_data[31:24];

    wire signed [15:0] p0 = a0 * b0;
    wire signed [15:0] p1 = a1 * b1;
    wire signed [15:0] p2 = a2 * b2;
    wire signed [15:0] p3 = a3 * b3;

    // Four 16-bit products sum into at most 18 bits. Written as an explicit sum of
    // individually sign-extended terms so no intermediate is truncated, and so the
    // extension is visible rather than left to width inference.
    wire signed [ACC_W-1:0] p0e = {{(ACC_W-16){p0[15]}}, p0};
    wire signed [ACC_W-1:0] p1e = {{(ACC_W-16){p1[15]}}, p1};
    wire signed [ACC_W-1:0] p2e = {{(ACC_W-16){p2[15]}}, p2};
    wire signed [ACC_W-1:0] p3e = {{(ACC_W-16){p3[15]}}, p3};
    wire signed [ACC_W-1:0] quad_sum = p0e + p1e + p2e + p3e;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            idx    <= 16'd0;
            a_word <= 32'd0;
            acc_r  <= {ACC_W{1'b0}};
            busy   <= 1'b0;
            done   <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        idx   <= 16'd0;
                        acc_r <= {ACC_W{1'b0}};
                        busy  <= 1'b1;
                        // Cleared on the same edge the run starts, so a poll can never read
                        // a stale done left over from the previous dot product.
                        done  <= 1'b0;
                        // A zero-length request has no terms to fetch, so it must complete
                        // rather than walk the vector once and wrap the counter.
                        state <= (len == 16'd0) ? S_DONE : S_FA;
                    end
                end

                S_FA: begin
                    a_word <= mem_data;
                    state  <= S_FB;
                end

                S_FB: begin
                    acc_r <= acc_r + quad_sum;
                    if ((idx + 16'd4) >= len) begin
                        state <= S_DONE;
                    end else begin
                        idx   <= idx + 16'd4;
                        state <= S_FA;
                    end
                end

                // busy drops and done rises on the same edge, matching correlator.v, so
                // there is never a cycle where both read low and a poll could mistake a
                // run in progress for an idle block.
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
