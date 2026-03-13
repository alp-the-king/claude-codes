// uart_rx.v
// UART receiver
//
// Frame format: 1 start bit, 8 data bits (LSB first), 1 stop bit
// Samples each bit at the mid-point of the baud period using mid_tick from
// uart_baud_gen.  A separate baud_tick advances the bit counter.
//
// Outputs:
//   rx_data  - captured byte (valid when rx_valid pulses)
//   rx_valid - one-cycle pulse when a complete, valid byte has been received
//   rx_error - one-cycle pulse when a framing error is detected (stop bit != 1)

`timescale 1ns/1ps

module uart_rx (
    input  wire       clk,
    input  wire       rst_n,
    // Baud timing (from uart_baud_gen instantiated in the top level)
    input  wire       baud_tick,   // One pulse per baud period
    input  wire       mid_tick,    // Pulse at mid-point of baud period
    // Serial input
    input  wire       rx,           // UART RX line (idle = 1)
    // Data interface
    output reg  [7:0] rx_data,     // Received byte
    output reg        rx_valid,    // Pulse when rx_data is valid
    output reg        rx_error     // Pulse on framing error
);

    // Two-stage synchroniser to avoid metastability on the async RX pin
    reg rx_sync0, rx_sync1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync0 <= 1'b1;
            rx_sync1 <= 1'b1;
        end else begin
            rx_sync0 <= rx;
            rx_sync1 <= rx_sync0;
        end
    end
    wire rx_s = rx_sync1;

    // FSM states
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0] state;
    reg [7:0] shift_reg;
    reg [2:0] bit_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            shift_reg <= 8'h00;
            bit_cnt   <= 3'd0;
            rx_data   <= 8'h00;
            rx_valid  <= 1'b0;
            rx_error  <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            rx_error <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                // Wait for the falling edge of the start bit
                S_IDLE: begin
                    if (rx_s == 1'b0) begin
                        // Start bit detected — the baud generator will now
                        // issue mid_tick at the centre of this bit period
                        state <= S_START;
                    end
                end

                // ---------------------------------------------------------
                // Verify the start bit at its mid-point.
                // If RX is still low the start bit is genuine; otherwise
                // it was a glitch and we return to idle.
                S_START: begin
                    if (mid_tick) begin
                        if (rx_s == 1'b0) begin
                            bit_cnt <= 3'd0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE;   // Glitch — discard
                        end
                    end
                end

                // ---------------------------------------------------------
                // Sample 8 data bits at their mid-points (mid_tick).
                S_DATA: begin
                    if (mid_tick) begin
                        shift_reg <= {rx_s, shift_reg[7:1]};   // LSB first
                        if (bit_cnt == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1'b1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // Sample the stop bit.  It must be logic 1.
                S_STOP: begin
                    if (mid_tick) begin
                        rx_data <= shift_reg;
                        if (rx_s == 1'b1) begin
                            rx_valid <= 1'b1;
                        end else begin
                            rx_error <= 1'b1;   // Framing error
                        end
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
