// Top level: RV32I core, unified memory, the GNSS correlator accelerator, a UART, and an
// INT8 dot-product accelerator for the neural-network firmware.
//
// Three peripherals now share the bus at distinct sub-regions, which is the standard shape
// of a real SoC address map: one region per device, decoded off the high address bits.
// Instruction fetch and CPU data access still share one memory array with asynchronous
// read, mirroring the C++ ISS's flat address space exactly, so the two models can only
// disagree when the RTL itself is wrong.

module soc_top #(
    parameter MEM_WORDS   = 65536,
    parameter PERIPH_BASE = 32'h1000_0000,
    parameter UART_BASE   = 32'h1000_1000,
    parameter MAC_BASE    = 32'h1000_2000,
    parameter ACC_W       = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] retire_pc,
    output wire [31:0] retire_insn,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_val,
    output wire        retire_we,
    output wire        halted,

    // UART pins, brought to the top level so a testbench can wire tx to rx for a
    // loopback test, or eventually to a real pin if this were ever taken to synthesis
    // on an actual FPGA.
    output wire        uart_tx_pin,
    input  wire        uart_rx_pin
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

    // Sub-decode within the peripheral region: UART_BASE sits above the correlator's
    // register file (which occupies 0x00-0x17 off PERIPH_BASE), so the two ranges cannot
    // overlap even as either grows.
    //
    // The UART's range is now bounded above as well. It used to be an open-ended
    // `>= UART_BASE`, which was correct while it was the topmost device but would have
    // silently swallowed every access to anything placed above it -- adding the MAC block
    // at MAC_BASE would have decoded as UART and the accelerator would simply never have
    // been selected. Worth naming as a real latent bug that adding a third peripheral
    // exposed, rather than a line that was always right.
    wire is_periph     = (dmem_addr >= PERIPH_BASE) && (dmem_addr < UART_BASE);
    wire is_uart       = (dmem_addr >= UART_BASE)   && (dmem_addr < MAC_BASE);
    wire is_mac        = (dmem_addr >= MAC_BASE);
    wire is_any_periph = is_periph || is_uart || is_mac;

    wire [31:0] sample_addr;
    wire signed [31:0] sample_data = mem[sample_addr[31:2]];

    // Operand fetch port for the MAC block. This is a fourth asynchronous read port on the
    // same array (instruction fetch, CPU data, correlator samples, and now MAC operands).
    // A real SRAM would not hand out four read ports for free; the flat async-read memory
    // is the same deliberate simplification documented in Scope, and the MAC is no more
    // optimistic about it than the correlator already was -- it uses a single port and
    // fetches its two operand streams on alternate cycles rather than asking for a fifth.
    wire [31:0] mac_addr;
    wire [31:0] mac_data = mem[mac_addr[31:2]];

    wire [31:0] corr_rdata, uart_rdata, mac_rdata;

    correlator_bus #(.ACC_W(ACC_W)) u_corr_bus (
        .clk         (clk),
        .rst_n       (rst_n),
        .sel         (is_periph),
        .we          (dmem_we),
        .addr        (dmem_addr),
        .wdata       (dmem_wdata),
        .rdata       (corr_rdata),
        .sample_addr (sample_addr),
        .sample_data (sample_data)
    );

    uart_bus #(.CLK_DIV_W(16)) u_uart_bus (
        .clk    (clk),
        .rst_n  (rst_n),
        .sel    (is_uart),
        .we     (dmem_we),
        .addr   (dmem_addr),
        .wdata  (dmem_wdata),
        .rdata  (uart_rdata),
        .tx_pin (uart_tx_pin),
        .rx_pin (uart_rx_pin)
    );

    mac_bus #(.ACC_W(ACC_W)) u_mac_bus (
        .clk      (clk),
        .rst_n    (rst_n),
        .sel      (is_mac),
        .we       (dmem_we),
        .addr     (dmem_addr),
        .wdata    (dmem_wdata),
        .rdata    (mac_rdata),
        .mem_addr (mac_addr),
        .mem_data (mac_data)
    );

    assign imem_data = mem[imem_addr[31:2]];

    always @(*) begin
        if (is_mac)          dmem_rdata = mac_rdata;
        else if (is_uart)    dmem_rdata = uart_rdata;
        else if (is_periph)  dmem_rdata = corr_rdata;
        else                 dmem_rdata = mem[dmem_addr[31:2]];
    end

    // Per-lane commit, so SB and SH leave the untouched bytes of the word intact.
    always @(posedge clk) begin
        if (dmem_we && !is_any_periph) begin
            if (dmem_wstrb[0]) mem[dmem_addr[31:2]][7:0]   <= dmem_wdata[7:0];
            if (dmem_wstrb[1]) mem[dmem_addr[31:2]][15:8]  <= dmem_wdata[15:8];
            if (dmem_wstrb[2]) mem[dmem_addr[31:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[31:2]][31:24] <= dmem_wdata[31:24];
        end
    end

endmodule
