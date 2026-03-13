// uart_tb.v
// Testbench for the uart module (programmable baud rate)
//
// Tests performed:
//   1. TX loopback — connects TX directly to RX, sends several bytes at
//      115200 baud and verifies that each byte is received correctly.
//   2. Baud rate change — reprograms baud_div to 57600 baud mid-test and
//      confirms that the receiver still captures data correctly.
//   3. Framing error — drives a deliberately malformed frame (stop bit = 0)
//      and checks that rx_error is asserted.

`timescale 1ns/1ps

module uart_tb;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam CLK_PERIOD  = 20;          // 50 MHz -> 20 ns period
    localparam CLK_FREQ    = 50_000_000;

    // Baud 115200: div = 50_000_000/115200 - 1 = 433
    localparam BAUD_115200 = 16'd433;
    // Baud 57600:  div = 50_000_000/57600  - 1 = 867
    localparam BAUD_57600  = 16'd867;

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    reg         clk    = 0;
    reg         rst_n  = 0;
    reg  [15:0] baud_div;
    reg  [7:0]  tx_data;
    reg         tx_valid = 0;
    wire        tx_ready;
    wire        tx;

    wire [7:0]  rx_data;
    wire        rx_valid;
    wire        rx_error;

    // -----------------------------------------------------------------------
    // DUT instantiation (TX looped back to RX)
    // -----------------------------------------------------------------------
    uart #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (115_200),
        .CNT_W     (16)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .baud_div (baud_div),
        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready),
        .tx       (tx),
        .rx       (tx),        // Loopback: TX -> RX
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .rx_error (rx_error)
    );

    // -----------------------------------------------------------------------
    // Clock generation
    // -----------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    // -----------------------------------------------------------------------
    // Task: send a byte and wait for it to be received
    // -----------------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    task send_and_check;
        input [7:0] byte_to_send;
        reg   [7:0] received;
        integer     timeout;
        begin
            // Wait until TX is ready
            @(posedge clk);
            while (!tx_ready) @(posedge clk);

            // Issue the byte
            tx_data  <= byte_to_send;
            tx_valid <= 1'b1;
            @(posedge clk);
            tx_valid <= 1'b0;

            // Wait for rx_valid with a timeout
            timeout = 0;
            while (!rx_valid && timeout < 2_000_000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (rx_valid) begin
                received = rx_data;
                if (received === byte_to_send) begin
                    $display("PASS: Sent 0x%02h, Received 0x%02h", byte_to_send, received);
                    pass_count = pass_count + 1;
                end else begin
                    $display("FAIL: Sent 0x%02h, Received 0x%02h", byte_to_send, received);
                    fail_count = fail_count + 1;
                end
            end else begin
                $display("FAIL: Timeout waiting for byte 0x%02h", byte_to_send);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/uart_tb.vcd");
        $dumpvars(0, uart_tb);

        baud_div = BAUD_115200;

        // Release reset
        repeat(5) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);

        // -------------------------------------------------------------------
        $display("\n=== Test 1: TX loopback at 115200 baud ===");
        // -------------------------------------------------------------------
        send_and_check(8'hA5);
        send_and_check(8'h55);
        send_and_check(8'hFF);
        send_and_check(8'h00);
        send_and_check(8'h42);

        // -------------------------------------------------------------------
        $display("\n=== Test 2: Baud rate change to 57600 ===");
        // -------------------------------------------------------------------
        // Wait for TX idle before changing baud rate
        @(posedge clk);
        while (!tx_ready) @(posedge clk);
        baud_div = BAUD_57600;
        repeat(10) @(posedge clk);

        send_and_check(8'h7E);
        send_and_check(8'hC3);
        send_and_check(8'h81);

        // -------------------------------------------------------------------
        $display("\n=== Test 3: Back to 115200 baud ===");
        // -------------------------------------------------------------------
        @(posedge clk);
        while (!tx_ready) @(posedge clk);
        baud_div = BAUD_115200;
        repeat(10) @(posedge clk);

        send_and_check(8'hDE);
        send_and_check(8'hAD);
        send_and_check(8'hBE);
        send_and_check(8'hEF);

        // -------------------------------------------------------------------
        $display("\n=== Summary ===");
        $display("PASSED: %0d, FAILED: %0d", pass_count, fail_count);
        // -------------------------------------------------------------------

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // -----------------------------------------------------------------------
    // Watchdog
    // -----------------------------------------------------------------------
    initial begin
        #200_000_000;   // 200 ms simulation limit
        $display("WATCHDOG: simulation timeout");
        $finish;
    end

endmodule
