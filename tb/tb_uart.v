// Standalone UART verification: self-checking loopback, driven purely through the
// register interface a real firmware driver would use, exactly as tb_correlator.v does
// for the GNSS block. tx is wired straight to rx here, the way you'd short two pins on a
// bench with a jumper for a self-test loop -- the RTL under test has no idea it isn't
// talking to a second chip.

`timescale 1ns / 1ps

module tb_uart;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg         sel = 1'b0, we = 1'b0;
    reg  [31:0] addr = 32'd0, wdata = 32'd0;
    wire [31:0] rdata;
    wire        loop_wire;

    uart_bus #(.CLK_DIV_W(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .sel(sel), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
        .tx_pin(loop_wire), .rx_pin(loop_wire)
    );

    // ---- bus helper tasks, modelling exactly what firmware would issue ----
    task automatic bus_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            sel = 1'b1; we = 1'b1; addr = a; wdata = d;
            @(negedge clk);
            sel = 1'b0; we = 1'b0;
        end
    endtask

    task automatic bus_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            sel = 1'b1; we = 1'b0; addr = a;
            #1; d = rdata;
            @(negedge clk);
            sel = 1'b0;
        end
    endtask

    reg [31:0] status, rxword;
    integer errors = 0;
    integer sent = 0;
    integer i;
    integer timeout;

    task automatic send_and_check(input [7:0] byte_val, input [15:0] baud_div);
        begin
            bus_write(32'h08, {16'd0, baud_div});   // BAUD_DIV
            bus_write(32'h04, {24'd0, byte_val});   // TXDATA
            bus_write(32'h00, 32'd1);               // pulse SEND

            // Poll STATUS for rx_ready, exactly the busy-wait a firmware driver would do.
            timeout = 0;
            status = 0;
            while (!status[1] && timeout < 20000) begin
                bus_read(32'h00, status);
                timeout = timeout + 1;
            end

            if (!status[1]) begin
                $display("TIMEOUT waiting for byte 0x%02x at baud_div=%0d", byte_val, baud_div);
                errors = errors + 1;
            end else begin
                bus_read(32'h04, rxword);
                sent = sent + 1;
                if (rxword[7:0] !== byte_val) begin
                    $display("MISMATCH: sent 0x%02x, received 0x%02x (baud_div=%0d)",
                             byte_val, rxword[7:0], baud_div);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Edge-value bytes first: all zeros, all ones, alternating patterns -- the
        // values most likely to expose an LSB/MSB ordering mistake.
        send_and_check(8'h00, 16'd4);
        send_and_check(8'hFF, 16'd4);
        send_and_check(8'hAA, 16'd4);   // 10101010
        send_and_check(8'h55, 16'd4);   // 01010101
        send_and_check(8'h01, 16'd4);   // only the LSB set
        send_and_check(8'h80, 16'd4);   // only the MSB set

        // Every byte value 0-255, at the fast simulation baud divisor.
        for (i = 0; i < 256; i = i + 1) send_and_check(i[7:0], 16'd4);

        // Repeat a smaller sweep at two other divisors, to catch anything that only
        // breaks at a particular baud/clock ratio (e.g. a rounding error in the
        // mid-bit-sample calculation for an odd divisor).
        for (i = 0; i < 32; i = i + 1) send_and_check(i[7:0] ^ 8'hF0, 16'd7);   // odd divisor
        for (i = 0; i < 32; i = i + 1) send_and_check(i[7:0] ^ 8'h0F, 16'd16);

        // Back-to-back burst: fire the next SEND the moment TX goes idle again, with no
        // extra settle time. send_and_check's poll loop already does this naturally (it
        // moves on as soon as rx_ready appears, not one bit period later), but this block
        // makes the intent explicit and pushes it across a full byte range so a
        // resynchronisation bug between consecutive frames has somewhere to show up.
        $display("--- back-to-back burst, no extra idle time ---");
        for (i = 0; i < 64; i = i + 1) send_and_check(i[7:0], 16'd4);

        $display("========================================");
        $display("bytes sent: %0d   errors: %0d", sent, errors);
        if (errors == 0) $display("RESULT: PASS");
        else              $display("RESULT: FAIL");
        $display("========================================");
        $finish;
    end

endmodule
