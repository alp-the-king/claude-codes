// uart_tx.v
// UART transmitter
//
// Frame format: 1 start bit, 8 data bits (LSB first), 1 stop bit
// Baud rate is set externally via baud_div; the baud_tick input is provided
// by uart_baud_gen.
//
// Usage:
//   1. Assert tx_valid along with tx_data.
//   2. Wait for tx_ready to go high before sending the next byte.
//   3. tx goes HIGH (idle) when no transmission is in progress.

`timescale 1ns/1ps

module uart_tx (
    input  wire       clk,
    input  wire       rst_n,
    // Baud timing
    input  wire       baud_tick,   // One pulse per baud period from uart_baud_gen
    // Data interface
    input  wire [7:0] tx_data,     // Byte to transmit
    input  wire       tx_valid,    // Pulse to start transmission
    output reg        tx_ready,    // High when idle and ready for new byte
    // Serial output
    output reg        tx            // UART TX line (idle = 1)
);

    // FSM states
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0] state;
    reg [7:0] shift_reg;   // Data shift register
    reg [2:0] bit_cnt;     // Counts bits 0..7

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            shift_reg <= 8'h00;
            bit_cnt   <= 3'd0;
            tx        <= 1'b1;
            tx_ready  <= 1'b1;
        end else begin
            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    tx       <= 1'b1;
                    tx_ready <= 1'b1;
                    if (tx_valid) begin
                        shift_reg <= tx_data;
                        tx_ready  <= 1'b0;
                        state     <= S_START;
                    end
                end

                // ---------------------------------------------------------
                // Send start bit (logic 0) for one full baud period.
                // We enter this state one cycle before the next baud_tick so
                // that the start bit is driven immediately and held for exactly
                // one baud period.
                S_START: begin
                    tx <= 1'b0;
                    if (baud_tick) begin
                        bit_cnt <= 3'd0;
                        state   <= S_DATA;
                    end
                end

                // ---------------------------------------------------------
                // Shift out 8 data bits, LSB first.
                S_DATA: begin
                    tx <= shift_reg[0];
                    if (baud_tick) begin
                        shift_reg <= {1'b0, shift_reg[7:1]};
                        if (bit_cnt == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // Stop bit (logic 1) for one full baud period.
                S_STOP: begin
                    tx <= 1'b1;
                    if (baud_tick) begin
                        state    <= S_IDLE;
                        tx_ready <= 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
