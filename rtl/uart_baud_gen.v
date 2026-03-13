// uart_baud_gen.v
// Programmable baud rate generator
//
// Generates two tick signals:
//   baud_tick  - one-cycle pulse at the start of each baud period
//   mid_tick   - one-cycle pulse at the middle of each baud period (used by RX for sampling)
//
// Baud rate = CLK_FREQ / (baud_div + 1)
// Example: 50 MHz clock, 115200 baud -> baud_div = 50_000_000/115200 - 1 = 433

`timescale 1ns/1ps

module uart_baud_gen #(
    parameter CNT_W = 16   // Width of the baud divisor counter
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [CNT_W-1:0] baud_div,   // Divisor: CLK_FREQ/BAUD_RATE - 1
    output reg              baud_tick,  // Pulse once per baud period
    output reg              mid_tick    // Pulse at mid-point of baud period
);

    reg [CNT_W-1:0] cnt;
    wire [CNT_W-1:0] half_div = baud_div >> 1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt       <= {CNT_W{1'b0}};
            baud_tick <= 1'b0;
            mid_tick  <= 1'b0;
        end else begin
            baud_tick <= 1'b0;
            mid_tick  <= 1'b0;

            if (cnt == baud_div) begin
                cnt       <= {CNT_W{1'b0}};
                baud_tick <= 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end

            if (cnt == half_div) begin
                mid_tick <= 1'b1;
            end
        end
    end

endmodule
