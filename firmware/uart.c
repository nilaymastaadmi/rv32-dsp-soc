// UART driver.
//
// Polling, not interrupt-driven: this core has no interrupt controller and no CSRs, so
// polling is the only option available rather than a design preference. It is also what
// a bring-up test wants -- the sequencing is explicit and there is no handler to get
// wrong while you are still establishing whether the peripheral works at all.

#include "uart.h"

void uart_init(uint32_t baud_div)
{
    UART->baud_div = baud_div;
    uart_clear_framing_error();
}

// Writing DATA loads the transmit holding register; writing SEND to CTRL pulses the
// transmitter. The order matters: pulsing send before the byte is staged would transmit
// whatever the previous contents were.
void uart_send(uint8_t byte)
{
    while (UART->ctrl_status & UART_STATUS_TX_BUSY) {
        // wait for any previous frame to finish shifting out
    }
    UART->data        = byte;
    UART->ctrl_status = UART_CTRL_SEND;
}

int uart_rx_ready(void)
{
    return (UART->ctrl_status & UART_STATUS_RX_READY) != 0;
}

// rx_ready is a sticky level in hardware, not a pulse, specifically so a poll loop
// cannot sample between pulses and miss a byte that genuinely arrived. Reading DATA is
// what clears it, so this function must read exactly once per byte.
uint8_t uart_recv_blocking(void)
{
    while (!uart_rx_ready()) {
        // spin
    }
    return (uint8_t)(UART->data & 0xFFu);
}

int uart_framing_error(void)
{
    return (int)(UART->framing_err & 1u);
}

void uart_clear_framing_error(void)
{
    UART->framing_err = 0;   // any write clears the sticky bit
}
