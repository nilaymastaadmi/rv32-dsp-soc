// Top level: core plus a unified memory.
//
// Instruction fetch and data access share one memory array with asynchronous read, which
// mirrors the C++ ISS's flat address space exactly. That equivalence is deliberate: the
// two models must disagree only when the RTL is wrong, never because their memory maps
// differ.
//
// The peripheral address decode is already carved out here (anything at or above
// PERIPH_BASE bypasses the memory array) so the correlator can be attached without
// disturbing the verified core-plus-memory path.

module soc_top #(
    parameter MEM_WORDS   = 65536,          // must match the ISS
    parameter PERIPH_BASE = 32'h1000_0000
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] retire_pc,
    output wire [31:0] retire_insn,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_val,
    output wire        retire_we,
    output wire        halted
);

    wire [31:0] imem_addr, imem_data;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;

    rv32i_core core (
        .clk        (clk),
        .rst_n      (rst_n),
        .imem_addr  (imem_addr),
        .imem_data  (imem_data),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_we    (dmem_we),
        .dmem_rdata (dmem_rdata),
        .retire_pc  (retire_pc),
        .retire_insn(retire_insn),
        .retire_rd  (retire_rd),
        .retire_val (retire_val),
        .retire_we  (retire_we),
        .halted     (halted)
    );

    // Word-addressed store. `mem` is public so the testbench can $readmemh into it.
    reg [31:0] mem [0:MEM_WORDS-1];

    wire is_periph = (dmem_addr >= PERIPH_BASE);

    assign imem_data  = mem[imem_addr[31:2]];
    assign dmem_rdata = is_periph ? 32'd0 : mem[dmem_addr[31:2]];

    // Per-lane commit, so SB and SH leave the untouched bytes of the word intact.
    always @(posedge clk) begin
        if (dmem_we && !is_periph) begin
            if (dmem_wstrb[0]) mem[dmem_addr[31:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) mem[dmem_addr[31:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) mem[dmem_addr[31:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[31:2]][31:24] <= dmem_wdata[31:24];
        end
    end

endmodule
