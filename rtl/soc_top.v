// Top level: RV32I core, unified memory, and the correlator accelerator.
//
// Instruction fetch and CPU data access share one memory array with asynchronous read,
// which mirrors the C++ ISS's flat address space exactly. That equivalence is deliberate:
// the two models must disagree only when the RTL is wrong, never because their memory
// maps differ.
//
// The accelerator gets its own read port into the same array. Giving it a private port
// rather than arbitrating for the CPU's is what lets it consume one sample per cycle
// while the CPU is doing something else, and in a physical design this is where a real
// arbiter or a dedicated sample buffer would go.

module soc_top #(
    parameter MEM_WORDS   = 65536,
    parameter PERIPH_BASE = 32'h1000_0000,
    parameter ACC_W       = 32
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
    wire [31:0] dmem_addr, dmem_wdata;
    wire [3:0]  dmem_wstrb;
    wire        dmem_we;
    reg  [31:0] dmem_rdata;

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

    reg [31:0] mem [0:MEM_WORDS-1];

    wire is_periph = (dmem_addr >= PERIPH_BASE);

    // Accelerator sample fetch port.
    wire [31:0] sample_addr;
    wire signed [31:0] sample_data = mem[sample_addr[31:2]];

    wire [31:0] periph_rdata;

    correlator_bus #(.ACC_W(ACC_W)) u_corr_bus (
        .clk         (clk),
        .rst_n       (rst_n),
        .sel         (is_periph),
        .we          (dmem_we),
        .addr        (dmem_addr),
        .wdata       (dmem_wdata),
        .rdata       (periph_rdata),
        .sample_addr (sample_addr),
        .sample_data (sample_data)
    );

    assign imem_data = mem[imem_addr[31:2]];

    always @(*) begin
        if (is_periph) dmem_rdata = periph_rdata;
        else           dmem_rdata = mem[dmem_addr[31:2]];
    end

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
