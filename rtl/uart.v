// uart.v
// Top-level UART module with programmable baud rate
//
// Combines the baud rate generator, transmitter, and receiver into a single
// module.  The baud rate is set at run-time by writing to the baud_div port:
//
//   baud_div = (CLK_FREQ / BAUD_RATE) - 1
//
// Common examples (50 MHz system clock):
//   9600   baud -> baud_div = 5207
//   19200  baud -> baud_div = 2603
//   38400  baud -> baud_div = 1301
//   57600  baud -> baud_div = 867
//   115200 baud -> baud_div = 433
//
// Ports
// -----
//   clk       : System clock
//   rst_n     : Active-low synchronous reset
//   baud_div  : 16-bit programmable baud divisor (must be stable during operation)
//
//   tx_data   : 8-bit byte to transmit
//   tx_valid  : Assert for one cycle to start a transmission
//   tx_ready  : High when the transmitter is idle and ready for new data
//   tx        : UART TX serial output (idle = 1)
//
//   rx        : UART RX serial input  (idle = 1)
//   rx_data   : 8-bit received byte
//   rx_valid  : One-cycle pulse when rx_data holds a new valid byte
//   rx_error  : One-cycle pulse on framing error

`timescale 1ns/1ps

module uart #(
    parameter CLK_FREQ   = 50_000_000,  // Hz — used only as a reference; actual
    parameter BAUD_RATE  = 115_200,     //   baud rate is determined by baud_div
    parameter CNT_W      = 16           // Width of the baud divisor
) (
    input  wire             clk,
    input  wire             rst_n,
    // Runtime-programmable baud rate divisor
    input  wire [CNT_W-1:0] baud_div,
    // Transmitter
    input  wire [7:0]       tx_data,
    input  wire             tx_valid,
    output wire             tx_ready,
    output wire             tx,
    // Receiver
    input  wire             rx,
    output wire [7:0]       rx_data,
    output wire             rx_valid,
    output wire             rx_error
);

    wire baud_tick;
    wire mid_tick;

    // -----------------------------------------------------------------------
    // Baud rate generator — shared between TX and RX
    // -----------------------------------------------------------------------
    uart_baud_gen #(
        .CNT_W (CNT_W)
    ) u_baud_gen (
        .clk       (clk),
        .rst_n     (rst_n),
        .baud_div  (baud_div),
        .baud_tick (baud_tick),
        .mid_tick  (mid_tick)
    );

    // -----------------------------------------------------------------------
    // Transmitter
    // -----------------------------------------------------------------------
    uart_tx u_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .baud_tick (baud_tick),
        .tx_data   (tx_data),
        .tx_valid  (tx_valid),
        .tx_ready  (tx_ready),
        .tx        (tx)
    );

    // -----------------------------------------------------------------------
    // Receiver
    // -----------------------------------------------------------------------
    uart_rx u_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .baud_tick (baud_tick),
        .mid_tick  (mid_tick),
        .rx        (rx),
        .rx_data   (rx_data),
        .rx_valid  (rx_valid),
        .rx_error  (rx_error)
    );

endmodule
