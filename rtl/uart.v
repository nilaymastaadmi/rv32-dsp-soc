// UART transmitter and receiver, 8 data bits, no parity, 1 stop bit (8N1).
//
// A configurable baud divisor drives both directions from the same input clock, so the
// same RTL works at any baud rate the test bench cares to exercise -- which matters here
// because the verification strategy is to run the loopback at several divisors, not just
// the one value that happened to be convenient.
//
// RX uses mid-bit sampling: after detecting the falling start-bit edge, it waits half a
// bit period to land in the middle of the start bit (confirming it wasn't a glitch), then
// samples every full bit period after that. Sampling at the bit edges instead would catch
// the signal transitioning, not the settled value -- a classic first-UART bug.

module uart_tx #(
    parameter CLK_DIV_W = 16
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire [CLK_DIV_W-1:0]   baud_div,   // clocks per bit period
    input  wire                   send,       // one-cycle pulse: start sending tx_data
    input  wire [7:0]             tx_data,
    output reg                    tx,         // idles high, per RS-232/TTL UART convention
    output reg                    busy
);

    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]           state;
    reg [CLK_DIV_W-1:0]  clk_cnt;
    reg [2:0]            bit_idx;
    reg [7:0]            shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            tx      <= 1'b1;
            busy    <= 1'b0;
            clk_cnt <= {CLK_DIV_W{1'b0}};
            bit_idx <= 3'd0;
            shift   <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (send) begin
                        shift   <= tx_data;
                        busy    <= 1'b1;
                        clk_cnt <= {CLK_DIV_W{1'b0}};
                        state   <= S_START;
                    end
                end

                S_START: begin
                    tx <= 1'b0;   // start bit
                    if (clk_cnt == baud_div - 1) begin
                        clk_cnt <= {CLK_DIV_W{1'b0}};
                        bit_idx <= 3'd0;
                        state   <= S_DATA;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end

                S_DATA: begin
                    tx <= shift[0];   // LSB first, the UART convention
                    if (clk_cnt == baud_div - 1) begin
                        clk_cnt <= {CLK_DIV_W{1'b0}};
                        shift   <= {1'b0, shift[7:1]};
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else bit_idx <= bit_idx + 1'b1;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end

                S_STOP: begin
                    tx <= 1'b1;   // stop bit
                    if (clk_cnt == baud_div - 1) begin
                        clk_cnt <= {CLK_DIV_W{1'b0}};
                        busy    <= 1'b0;
                        state   <= S_IDLE;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


module uart_rx #(
    parameter CLK_DIV_W = 16
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [CLK_DIV_W-1:0] baud_div,
    input  wire                 rx,
    output reg  [7:0]           rx_data,
    output reg                  rx_ready,   // one-cycle pulse: a byte landed in rx_data
    output reg                  framing_err // stop bit was not high -- misaligned sampling
);

    localparam S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]           state;
    reg [CLK_DIV_W-1:0]  clk_cnt;
    reg [2:0]            bit_idx;
    reg [7:0]            shift;
    reg                   rx_d1, rx_d2;   // two-flop synchroniser for the async rx line

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_d1 <= 1'b1; rx_d2 <= 1'b1; end
        else        begin rx_d1 <= rx; rx_d2 <= rx_d1; end
    end
    wire rx_sync = rx_d2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            clk_cnt     <= {CLK_DIV_W{1'b0}};
            bit_idx     <= 3'd0;
            shift       <= 8'd0;
            rx_data     <= 8'd0;
            rx_ready    <= 1'b0;
            framing_err <= 1'b0;
        end else begin
            rx_ready <= 1'b0;   // default: a pulse, not a level

            case (state)
                S_IDLE: begin
                    if (!rx_sync) begin   // falling edge: candidate start bit
                        clk_cnt <= {CLK_DIV_W{1'b0}};
                        state   <= S_START;
                    end
                end

                S_START: begin
                    // Wait to the middle of the start bit before trusting it -- this is
                    // what rejects a single-cycle glitch instead of mis-triggering on one.
                    if (clk_cnt == (baud_div >> 1) - 1) begin
                        if (!rx_sync) begin
                            clk_cnt <= {CLK_DIV_W{1'b0}};
                            bit_idx <= 3'd0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE;   // was a glitch, not a real start bit
                        end
                    end else clk_cnt <= clk_cnt + 1'b1;
                end

                S_DATA: begin
                    // Now sampling at the middle of each subsequent bit period.
                    if (clk_cnt == baud_div - 1) begin
                        clk_cnt        <= {CLK_DIV_W{1'b0}};
                        shift          <= {rx_sync, shift[7:1]};   // LSB first in
                        if (bit_idx == 3'd7) state <= S_STOP;
                        else bit_idx <= bit_idx + 1'b1;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end

                S_STOP: begin
                    if (clk_cnt == baud_div - 1) begin
                        rx_data     <= shift;
                        rx_ready    <= 1'b1;
                        framing_err <= !rx_sync;   // stop bit should read back as 1
                        state       <= S_IDLE;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
