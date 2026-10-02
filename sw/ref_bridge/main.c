/*
 * ARC referee bridge (Zynq PS, bare metal).
 *
 * Moves bytes between the Zybo USB-UART (PS UART1, MIO 48/49) and the referee
 * logic in the fabric. It does not parse anything; all framing, CRCs and game
 * rules live in the FPGA.
 *
 *   Chrome (Web Serial) -> UART1 RX -> REF RX_DATA  -> fabric parser
 *   fabric frames       -> REF TX_DATA -> UART1 TX  -> Chrome
 *
 * Only xil_io.h is used, and the UART is programmed directly, so this builds
 * against any standalone BSP version.
 */
#include <stdint.h>
#include "xil_io.h"

/* arc_ref_axi, address fixed in hw/scripts/build.tcl */
#define REF_BASE        0x43C00000u
#define REF_ID          (REF_BASE + 0x00)
#define REF_RX_DATA     (REF_BASE + 0x08)
#define REF_TX_DATA     (REF_BASE + 0x0C)
#define REF_CTRL        (REF_BASE + 0x14)
#define REF_ID_VALUE    0x41524346u     /* "ARCF" */
#define REF_TX_VALID    0x100u

/* Zynq PS UART1 (Zynq TRM, appendix B.33) */
#define UART_BASE       0xE0001000u
#define UART_CR         (UART_BASE + 0x00)
#define UART_MR         (UART_BASE + 0x04)
#define UART_IDR        (UART_BASE + 0x0C)
#define UART_BAUDGEN    (UART_BASE + 0x18)
#define UART_RXTOUT     (UART_BASE + 0x1C)
#define UART_SR         (UART_BASE + 0x2C)
#define UART_FIFO       (UART_BASE + 0x30)
#define UART_BAUDDIV    (UART_BASE + 0x34)

#define CR_RXRST        0x01u
#define CR_TXRST        0x02u
#define CR_RX_EN        0x04u
#define CR_RX_DIS       0x08u
#define CR_TX_EN        0x10u
#define CR_TX_DIS       0x20u
#define CR_STOPBRK      0x100u
#define SR_RXEMPTY      0x02u
#define SR_TXFULL       0x10u

/* 100 MHz UART reference clock / (62 * (13 + 1)) = 115207 baud (+0.006 %) */
#define BAUD_CD         62u
#define BAUD_BDIV       13u

static void uart_init(void)
{
    Xil_Out32(UART_CR, CR_RX_DIS | CR_TX_DIS);
    Xil_Out32(UART_IDR, 0x1FFFu);           /* polled, no interrupts */
    Xil_Out32(UART_MR, 0x20u);              /* 8 data bits, no parity, 1 stop */
    Xil_Out32(UART_BAUDGEN, BAUD_CD);
    Xil_Out32(UART_BAUDDIV, BAUD_BDIV);
    Xil_Out32(UART_RXTOUT, 0u);
    Xil_Out32(UART_CR, CR_RXRST | CR_TXRST);
    while (Xil_In32(UART_CR) & (CR_RXRST | CR_TXRST))
        ;
    Xil_Out32(UART_CR, CR_RX_EN | CR_TX_EN | CR_STOPBRK);
}

static void uart_puts(const char *s)
{
    while (*s) {
        while (Xil_In32(UART_SR) & SR_TXFULL)
            ;
        Xil_Out32(UART_FIFO, (uint8_t)*s++);
    }
}

int main(void)
{
    uart_init();

    /* Plain text never contains 0xA5, so the browser's frame decoder skips it. */
    if (Xil_In32(REF_ID) != REF_ID_VALUE) {
        uart_puts("\r\nARC ref bridge: referee core not found at 0x43C00000\r\n");
        for (;;)
            ;
    }

    /* Pulse the core's soft reset so a re-run starts from a clean match. */
    Xil_Out32(REF_CTRL, 1u);
    Xil_Out32(REF_CTRL, 0u);
    uart_puts("\r\nARC ref bridge ready\r\n");

    for (;;) {
        /* Browser -> fabric: drain everything the UART has. */
        while (!(Xil_In32(UART_SR) & SR_RXEMPTY))
            Xil_Out32(REF_RX_DATA, Xil_In32(UART_FIFO) & 0xFFu);

        /* Fabric -> browser: one byte per pass so RX is never starved. */
        if (!(Xil_In32(UART_SR) & SR_TXFULL)) {
            uint32_t t = Xil_In32(REF_TX_DATA);
            if (t & REF_TX_VALID)
                Xil_Out32(UART_FIFO, t & 0xFFu);
        }
    }
}
