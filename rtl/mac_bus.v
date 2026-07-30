// Memory-mapped register interface for the INT8 dot-product accelerator.
//
// Register map, relative to the peripheral base:
//   0x00  W: bit0 = start     R: bit0 = busy, bit1 = done, bit2 = align_err
//   0x04  RW: number of int8 terms (must be a multiple of 4)
//   0x08  RW: byte address of the int8 activation vector (must be 4-byte aligned)
//   0x0C  RW: byte address of the int8 weight vector (must be 4-byte aligned)
//   0x10  R : int32 dot product
//
// Third peripheral on the same sel/we/addr/wdata/rdata convention the correlator defined
// and the UART reused unchanged. Reusing it a second time is the actual test of whether
// that interface generalises: the correlator fetches its own samples and the UART touches
// no memory at all, so this block -- which fetches *two* operand streams -- is the first
// one to stress the pattern in a genuinely different direction, and it still needed no
// change to the bus convention itself.

module mac_bus #(
    parameter ACC_W = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    // CPU-side register interface
    input  wire        sel,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    // operand fetch into main memory, one shared read port
    output wire [31:0] mem_addr,
    input  wire [31:0] mem_data
);

    reg [15:0] r_len;
    reg [31:0] r_base_a;
    reg [31:0] r_base_b;

    wire [3:0] off = addr[5:2];

    // One-cycle start strobe straight off the bus write, the same idiom correlator_bus and
    // uart_bus both use: a CPU store asserts we for exactly one cycle, so no pulse
    // stretching is needed.
    wire start_pulse = sel && we && (off == 4'd0) && wdata[0];

    wire        busy, done;
    wire signed [ACC_W-1:0] acc;

    // The block reads whole words and indexes byte lanes, so a misaligned base or a length
    // that is not a multiple of 4 would silently compute a dot product over the wrong
    // bytes. Rather than document that as a caveat and hope, it is exposed as a status bit
    // the firmware (or a testbench) can assert on. The firmware satisfies the constraint by
    // construction; this exists so a future caller that does not finds out immediately.
    wire align_err = (r_base_a[1:0] != 2'b00)
                  || (r_base_b[1:0] != 2'b00)
                  || (r_len[1:0]    != 2'b00);

    mac #(.ACC_W(ACC_W)) u_mac (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start_pulse),
        .len      (r_len),
        .base_a   (r_base_a),
        .base_b   (r_base_b),
        .mem_addr (mem_addr),
        .mem_data (mem_data),
        .busy     (busy),
        .done     (done),
        .acc      (acc)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_len    <= 16'd0;
            r_base_a <= 32'd0;
            r_base_b <= 32'd0;
        end else if (sel && we) begin
            case (off)
                4'd1: r_len    <= wdata[15:0];
                4'd2: r_base_a <= wdata;
                4'd3: r_base_b <= wdata;
                default: ;
            endcase
        end
    end

    always @(*) begin
        case (off)
            4'd0: rdata = {29'd0, align_err, done, busy};
            4'd1: rdata = {16'd0, r_len};
            4'd2: rdata = r_base_a;
            4'd3: rdata = r_base_b;
            4'd4: rdata = acc;
            default: rdata = 32'd0;
        endcase
    end

endmodule
