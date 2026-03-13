-- uart_tb.vhd
-- Testbench for the UART module with programmable baud rate
--
-- Tests:
--   1. TX->RX loopback at 115200 baud (5 bytes)
--   2. Runtime baud-rate switch to 57600 (3 bytes)
--   3. Return to 115200 (4 bytes)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tb is
end entity uart_tb;

architecture sim of uart_tb is

    -- -----------------------------------------------------------------------
    -- Constants
    -- -----------------------------------------------------------------------
    constant CLK_PERIOD  : time    := 20 ns;   -- 50 MHz
    constant CLK_FREQ    : integer := 50_000_000;

    -- baud_div = CLK_FREQ/BAUD - 1
    constant BAUD_115200 : std_logic_vector(15 downto 0) :=
        std_logic_vector(to_unsigned(433, 16));
    constant BAUD_57600  : std_logic_vector(15 downto 0) :=
        std_logic_vector(to_unsigned(867, 16));

    -- -----------------------------------------------------------------------
    -- DUT signals
    -- -----------------------------------------------------------------------
    signal clk      : std_logic := '0';
    signal rst_n    : std_logic := '0';
    signal baud_div : std_logic_vector(15 downto 0);
    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;
    signal tx       : std_logic;
    signal rx_data  : std_logic_vector(7 downto 0);
    signal rx_valid : std_logic;
    signal rx_error : std_logic;

begin

    -- -----------------------------------------------------------------------
    -- Clock
    -- -----------------------------------------------------------------------
    clk <= not clk after CLK_PERIOD / 2;

    -- -----------------------------------------------------------------------
    -- DUT — TX looped back to RX
    -- -----------------------------------------------------------------------
    dut : entity work.uart
        generic map (
            CLK_FREQ  => CLK_FREQ,
            BAUD_RATE => 115_200,
            CNT_W     => 16
        )
        port map (
            clk      => clk,
            rst_n    => rst_n,
            baud_div => baud_div,
            tx_data  => tx_data,
            tx_valid => tx_valid,
            tx_ready => tx_ready,
            tx       => tx,
            rx       => tx,        -- loopback
            rx_data  => rx_data,
            rx_valid => rx_valid,
            rx_error => rx_error
        );

    -- -----------------------------------------------------------------------
    -- Stimulus
    -- -----------------------------------------------------------------------
    stim : process

        variable pass_count : integer := 0;
        variable fail_count : integer := 0;

        -- Send one byte and check the looped-back received value.
        procedure send_and_check(byte_val : std_logic_vector(7 downto 0)) is
            variable timeout : integer;
        begin
            -- Wait for transmitter idle
            while tx_ready = '0' loop
                wait until rising_edge(clk);
            end loop;

            -- Issue byte
            tx_data  <= byte_val;
            tx_valid <= '1';
            wait until rising_edge(clk);
            tx_valid <= '0';

            -- Wait for reception with timeout
            timeout := 0;
            while rx_valid = '0' and timeout < 2_000_000 loop
                wait until rising_edge(clk);
                timeout := timeout + 1;
            end loop;

            if rx_valid = '1' then
                if rx_data = byte_val then
                    report "PASS: sent=0x" & to_hstring(byte_val) &
                           "  recv=0x" & to_hstring(rx_data);
                    pass_count := pass_count + 1;
                else
                    report "FAIL: sent=0x" & to_hstring(byte_val) &
                           "  recv=0x" & to_hstring(rx_data)
                        severity error;
                    fail_count := fail_count + 1;
                end if;
            else
                report "FAIL: timeout waiting for 0x" & to_hstring(byte_val)
                    severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure;

    begin
        baud_div <= BAUD_115200;

        -- Release reset
        for i in 0 to 4 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        for i in 0 to 4 loop
            wait until rising_edge(clk);
        end loop;

        -- -------------------------------------------------------------------
        report "=== Test 1: TX loopback at 115200 baud ===";
        -- -------------------------------------------------------------------
        send_and_check(x"A5");
        send_and_check(x"55");
        send_and_check(x"FF");
        send_and_check(x"00");
        send_and_check(x"42");

        -- -------------------------------------------------------------------
        report "=== Test 2: Baud rate change to 57600 ===";
        -- -------------------------------------------------------------------
        while tx_ready = '0' loop
            wait until rising_edge(clk);
        end loop;
        baud_div <= BAUD_57600;
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;

        send_and_check(x"7E");
        send_and_check(x"C3");
        send_and_check(x"81");

        -- -------------------------------------------------------------------
        report "=== Test 3: Back to 115200 baud ===";
        -- -------------------------------------------------------------------
        while tx_ready = '0' loop
            wait until rising_edge(clk);
        end loop;
        baud_div <= BAUD_115200;
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;

        send_and_check(x"DE");
        send_and_check(x"AD");
        send_and_check(x"BE");
        send_and_check(x"EF");

        -- -------------------------------------------------------------------
        report "=== Summary: PASSED=" & integer'image(pass_count) &
               "  FAILED=" & integer'image(fail_count);

        if fail_count = 0 then
            report "ALL TESTS PASSED";
            std.env.stop(0);
        else
            report "SOME TESTS FAILED" severity failure;
            std.env.stop(1);
        end if;
        -- -------------------------------------------------------------------

        wait;
    end process;

    -- -----------------------------------------------------------------------
    -- Watchdog
    -- -----------------------------------------------------------------------
    watchdog : process
    begin
        wait for 200 ms;
        report "WATCHDOG: simulation timeout" severity failure;
        std.env.stop(2);
        wait;
    end process;

end architecture sim;
