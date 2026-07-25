// Memory-mapped register interface for the correlator.
//
// Register map, relative to the peripheral base:
//   0x00  W: bit0 = start          R: bit0 = busy, bit1 = done
//   0x04  RW: PRN (1..32)
//   0x08  RW: number of samples to integrate
//   0x0C  RW: code phase hypothesis, in chips
//   0x10  RW: sample block base, byte address in main memory
//   0x14  R : accumulator result (signed)
//
// The accelerator fetches its own samples from main memory rather than having the CPU
// feed them in, so the CPU cost per hypothesis is a handful of register writes and a
// poll rather than one instruction per sample. That distinction is the whole point of
// the block, and it is what the software-versus-hardware cycle comparison measures.

module correlator_bus #(
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

    // sample fetch into main memory
    output wire [31:0] sample_addr,
    input  wire signed [31:0] sample_data
);

    reg [4:0]  r_prn;
    reg [15:0] r_nsamp;
    reg [10:0] r_phase;
    reg [31:0] r_base;

    wire [3:0] off = addr[5:2];

    // A write of bit0 to offset 0 produces exactly one start pulse, because the CPU's
    // store asserts its write strobe for a single cycle.
    wire start_pulse = sel && we && (off == 4'd0) && wdata[0];

    wire [15:0] sample_idx;
    wire        busy, done;
    wire signed [ACC_W-1:0] acc;

    assign sample_addr = r_base + {14'd0, sample_idx, 2'b00};

    correlator #(.ACC_W(ACC_W), .SAMPLE_W(32)) u_corr (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start_pulse),
        .prn         (r_prn),
        .num_samples (r_nsamp),
        .code_phase  (r_phase),
        .sample_idx  (sample_idx),
        .sample_data (sample_data),
        .busy        (busy),
        .done        (done),
        .acc         (acc)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_prn   <= 5'd1;
            r_nsamp <= 16'd1023;
            r_phase <= 11'd0;
            r_base  <= 32'd0;
        end else if (sel && we) begin
            case (off)
                4'd1: r_prn   <= wdata[4:0];
                4'd2: r_nsamp <= wdata[15:0];
                4'd3: r_phase <= wdata[10:0];
                4'd4: r_base  <= wdata;
                default: ;
            endcase
        end
    end

    always @(*) begin
        case (off)
            4'd0: rdata = {30'd0, done, busy};
            4'd1: rdata = {27'd0, r_prn};
            4'd2: rdata = {16'd0, r_nsamp};
            4'd3: rdata = {21'd0, r_phase};
            4'd4: rdata = r_base;
            4'd5: rdata = acc;
            default: rdata = 32'd0;
        endcase
    end

endmodule
