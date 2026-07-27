// UART loopback self-test firmware.
//
// The host controller (scripts/uart_testbench.py) places a vector count and a block of
// test bytes in memory before the run, then reads the results back afterwards and scores
// them independently. This firmware transmits each byte, waits for it to arrive back over
// the loopback, records what actually came back, and keeps its own pass/fail tally.
//
// The device's tally is deliberately not the source of truth. The host re-scores every
// received byte against what it sent, and the two verdicts are compared -- a firmware
// that miscounts is exactly as much of a bug as a UART that mis-transmits, and only
// cross-checking two independent tallies catches the first kind.
//
// This is a C rewrite of tests/uart_test.s and is verified against it by trace: both
// builds are run on the same core and must produce identical host-visible results.

#include <stdint.h>
#include "uart.h"

// Shared region with the host controller. Addresses are fixed by the host's protocol,
// so they are declared as absolute pointers rather than linked symbols -- the linker
// script keeps every section it places strictly below 0x5000 so nothing can collide.
#define VEC_COUNT   (*(volatile uint32_t *)0x00005000u)
#define VEC_DATA     ((volatile uint32_t *)0x00005004u)
#define RESULT_PASS (*(volatile uint32_t *)0x00006000u)
#define RESULT_FAIL (*(volatile uint32_t *)0x00006004u)
#define RESULT_RX    ((volatile uint32_t *)0x00007000u)

// Simulation-speed divisor. A real deployment would derive this from the system clock
// and the target baud rate; here the testbench and the host agree on this value.
#define BAUD_DIV 4u

int main(void)
{
    uint32_t count = VEC_COUNT;
    uint32_t pass  = 0;
    uint32_t fail  = 0;

    uart_init(BAUD_DIV);

    for (uint32_t i = 0; i < count; i++) {
        uint8_t sent = (uint8_t)(VEC_DATA[i] & 0xFFu);

        uart_send(sent);
        uint8_t got = uart_recv_blocking();

        // Log every received byte, matched or not. A test that only reports a count
        // tells you something broke; one that logs what came back tells you what.
        RESULT_RX[i] = got;

        if (got == sent) {
            pass++;
        } else {
            fail++;
        }
    }

    RESULT_PASS = pass;
    RESULT_FAIL = fail;

    return (fail == 0) ? 0 : 1;
}
