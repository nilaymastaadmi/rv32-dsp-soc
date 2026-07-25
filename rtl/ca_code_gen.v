// GPS L1 C/A gold-code generator.
//
// Two 10-stage LFSRs: G1 with taps 3 and 10, G2 with taps 2,3,6,8,9,10. The per-satellite
// code is G1 XORed with a delayed G2, and that delay is realised by XORing a
// satellite-specific pair of G2 stages rather than by an actual shift register, which is
// why a 32-satellite family costs one small tap LUT instead of 32 delay lines.
//
// Output convention matches the reference model: chip = 1 means the BPSK symbol -1.

module ca_code_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,      // synchronous restart to the all-ones state
    input  wire        en,        // advance exactly one chip
    input  wire [4:0]  prn,       // 1..32
    output wire        chip
);

    reg [10:1] g1, g2;

    // Per-PRN G2 tap pair, IS-GPS-200 Table 3-Ia.
    reg [3:0] tap_a, tap_b;
    always @(*) begin
        case (prn)
            5'd1:  begin tap_a = 4'd2;  tap_b = 4'd6;  end
            5'd2:  begin tap_a = 4'd3;  tap_b = 4'd7;  end
            5'd3:  begin tap_a = 4'd4;  tap_b = 4'd8;  end
            5'd4:  begin tap_a = 4'd5;  tap_b = 4'd9;  end
            5'd5:  begin tap_a = 4'd1;  tap_b = 4'd9;  end
            5'd6:  begin tap_a = 4'd2;  tap_b = 4'd10; end
            5'd7:  begin tap_a = 4'd1;  tap_b = 4'd8;  end
            5'd8:  begin tap_a = 4'd2;  tap_b = 4'd9;  end
            5'd9:  begin tap_a = 4'd3;  tap_b = 4'd10; end
            5'd10: begin tap_a = 4'd2;  tap_b = 4'd3;  end
            5'd11: begin tap_a = 4'd3;  tap_b = 4'd4;  end
            5'd12: begin tap_a = 4'd5;  tap_b = 4'd6;  end
            5'd13: begin tap_a = 4'd6;  tap_b = 4'd7;  end
            5'd14: begin tap_a = 4'd7;  tap_b = 4'd8;  end
            5'd15: begin tap_a = 4'd8;  tap_b = 4'd9;  end
            5'd16: begin tap_a = 4'd9;  tap_b = 4'd10; end
            5'd17: begin tap_a = 4'd1;  tap_b = 4'd4;  end
            5'd18: begin tap_a = 4'd2;  tap_b = 4'd5;  end
            5'd19: begin tap_a = 4'd3;  tap_b = 4'd6;  end
            5'd20: begin tap_a = 4'd4;  tap_b = 4'd7;  end
            5'd21: begin tap_a = 4'd5;  tap_b = 4'd8;  end
            5'd22: begin tap_a = 4'd6;  tap_b = 4'd9;  end
            5'd23: begin tap_a = 4'd1;  tap_b = 4'd3;  end
            5'd24: begin tap_a = 4'd4;  tap_b = 4'd6;  end
            5'd25: begin tap_a = 4'd5;  tap_b = 4'd7;  end
            5'd26: begin tap_a = 4'd6;  tap_b = 4'd8;  end
            5'd27: begin tap_a = 4'd7;  tap_b = 4'd9;  end
            5'd28: begin tap_a = 4'd8;  tap_b = 4'd10; end
            5'd29: begin tap_a = 4'd1;  tap_b = 4'd6;  end
            5'd30: begin tap_a = 4'd2;  tap_b = 4'd7;  end
            5'd31: begin tap_a = 4'd3;  tap_b = 4'd8;  end
            default: begin tap_a = 4'd4; tap_b = 4'd9; end   // PRN 32
        endcase
    end

    wire g1_out = g1[10];
    wire g2_out = g2[tap_a] ^ g2[tap_b];
    assign chip = g1_out ^ g2_out;

    wire fb1 = g1[3] ^ g1[10];
    wire fb2 = g2[2] ^ g2[3] ^ g2[6] ^ g2[8] ^ g2[9] ^ g2[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g1 <= 10'h3FF;
            g2 <= 10'h3FF;
        end else if (init) begin
            // All-ones is the specified initial state for both registers.
            g1 <= 10'h3FF;
            g2 <= 10'h3FF;
        end else if (en) begin
            g1 <= {g1[9:1], fb1};
            g2 <= {g2[9:1], fb2};
        end
    end

endmodule
