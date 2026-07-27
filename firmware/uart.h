// Driver interface for the memory-mapped UART.
//
// Register map (from rtl/uart_bus.v), relative to UART_BASE:
//
//   0x00  W: bit0 = send pulse       R: bit0 = tx_busy, bit1 = rx_ready
//   0x04  W: tx_data (byte)          R: rx_data  -- reading also clears rx_ready
//   0x08  RW: baud_div (clock cycles per bit)
//   0x0C  R: framing_err (sticky)    W: any value clears it

#ifndef UART_H
#define UART_H

#include <stdint.h>

#define UART_BASE 0x10001000u

// Every field is volatile: these are hardware registers, not memory. Without volatile
// the compiler is entitled to cache a status read in a register, and a polling loop on a
// cached value never terminates -- the single most common bare-metal bug there is.
typedef struct {
    volatile uint32_t ctrl_status;   // 0x00
    volatile uint32_t data;          // 0x04
    volatile uint32_t baud_div;      // 0x08
    volatile uint32_t framing_err;   // 0x0C
} uart_regs_t;

#define UART ((uart_regs_t *)UART_BASE)

#define UART_CTRL_SEND      (1u << 0)   // write
#define UART_STATUS_TX_BUSY (1u << 0)   // read
#define UART_STATUS_RX_READY (1u << 1)  // read

void     uart_init(uint32_t baud_div);
void     uart_send(uint8_t byte);
int      uart_rx_ready(void);
uint8_t  uart_recv_blocking(void);
int      uart_framing_error(void);
void     uart_clear_framing_error(void);

#endif
