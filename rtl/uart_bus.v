// Memory-mapped register interface for the UART, at a peripheral sub-address distinct
// from the correlator so both accelerators can coexist on the same bus.
//
// Register map, relative to UART_BASE:
//   0x00  W: bit0 = send (write pulses TX with tx_data)   R: bit0 = tx_busy, bit1 = rx_ready
//   0x04  W: tx_data (byte to send)                        R: rx_data (last received byte)
//   0x08  RW: baud_div
//   0x0C  R: framing_err (sticky until read-cleared by writing any value here)

module uart_bus #(
    parameter CLK_DIV_W = 16
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sel,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,

    output wire         tx_pin,   // wire tx_pin to rx_pin externally for a loopback test
    input  wire         rx_pin
);

    reg [CLK_DIV_W-1:0] baud_div;
    reg [7:0]           tx_data_r;
    reg                 send_pulse;

    wire       tx_busy;
    wire [7:0] rx_data;
    wire       rx_ready_pulse;
    wire       framing_err_w;

    reg        rx_ready_sticky;
    reg        framing_err_sticky;

    uart_tx #(.CLK_DIV_W(CLK_DIV_W)) u_tx (
        .clk(clk), .rst_n(rst_n), .baud_div(baud_div),
        .send(send_pulse), .tx_data(tx_data_r),
        .tx(tx_pin), .busy(tx_busy)
    );

    uart_rx #(.CLK_DIV_W(CLK_DIV_W)) u_rx (
        .clk(clk), .rst_n(rst_n), .baud_div(baud_div),
        .rx(rx_pin),
        .rx_data(rx_data), .rx_ready(rx_ready_pulse), .framing_err(framing_err_w)
    );

    wire [3:0] off = addr[5:2];

    // send is a genuine one-cycle pulse straight off the bus write strobe, exactly the
    // same idiom the correlator's start_pulse used -- a CPU store asserts we for one
    // cycle, so no separate pulse-stretching logic is needed.
    always @(*) send_pulse = sel && we && (off == 4'd0) && wdata[0];

    // rx_ready is a status bit the CPU polls, so it must be a level, not the underlying
    // one-cycle pulse -- otherwise a poll loop could sample between pulses and miss a
    // byte that genuinely arrived. It stays set until firmware reads RXDATA.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_ready_sticky    <= 1'b0;
            framing_err_sticky <= 1'b0;
        end else begin
            if (rx_ready_pulse) rx_ready_sticky <= 1'b1;
            else if (sel && !we && (off == 4'd1)) rx_ready_sticky <= 1'b0; // cleared by reading RXDATA

            if (framing_err_w) framing_err_sticky <= 1'b1;
            else if (sel && we && (off == 4'd3)) framing_err_sticky <= 1'b0; // cleared by writing STATUS2
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baud_div  <= 16'd4;   // fast default for simulation; firmware sets the real value
            tx_data_r <= 8'd0;
        end else if (sel && we) begin
            case (off)
                4'd1: tx_data_r <= wdata[7:0];
                4'd2: baud_div  <= wdata[CLK_DIV_W-1:0];
                default: ;
            endcase
        end
    end

    always @(*) begin
        case (off)
            4'd0: rdata = {30'd0, rx_ready_sticky, tx_busy};
            4'd1: rdata = {24'd0, rx_data};
            4'd2: rdata = {{(32-CLK_DIV_W){1'b0}}, baud_div};
            4'd3: rdata = {31'd0, framing_err_sticky};
            default: rdata = 32'd0;
        endcase
    end

endmodule
