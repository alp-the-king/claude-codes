-- uart_rx.vhd
-- UART receiver
--
-- Frame format: 1 start bit, 8 data bits (LSB first), 1 stop bit
-- Each bit is sampled at the mid-point of the baud period (mid_tick).
-- A two-stage synchroniser protects against metastability on the rx pin.
--
-- Outputs:
--   rx_data  : captured byte (valid while rx_valid is asserted)
--   rx_valid : one-cycle pulse when a valid byte has been received
--   rx_error : one-cycle pulse on framing error (stop bit sampled as 0)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        baud_tick : in  std_logic;
        mid_tick  : in  std_logic;
        rx        : in  std_logic;
        rx_data   : out std_logic_vector(7 downto 0);
        rx_valid  : out std_logic;
        rx_error  : out std_logic
    );
end entity uart_rx;

architecture rtl of uart_rx is

    -- Two-stage synchroniser
    signal rx_sync0 : std_logic;
    signal rx_sync1 : std_logic;

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal state     : state_t;
    signal shift_reg : std_logic_vector(7 downto 0);
    signal bit_cnt   : unsigned(2 downto 0);

begin

    -- -----------------------------------------------------------------------
    -- Input synchroniser
    -- -----------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            rx_sync0 <= '1';
            rx_sync1 <= '1';
        elsif rising_edge(clk) then
            rx_sync0 <= rx;
            rx_sync1 <= rx_sync0;
        end if;
    end process;

    -- -----------------------------------------------------------------------
    -- Receive FSM
    -- -----------------------------------------------------------------------
    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state     <= S_IDLE;
            shift_reg <= (others => '0');
            bit_cnt   <= (others => '0');
            rx_data   <= (others => '0');
            rx_valid  <= '0';
            rx_error  <= '0';

        elsif rising_edge(clk) then
            rx_valid <= '0';
            rx_error <= '0';

            case state is

                -- ---------------------------------------------------------
                -- Wait for falling edge (start bit).
                when S_IDLE =>
                    if rx_sync1 = '0' then
                        state <= S_START;
                    end if;

                -- ---------------------------------------------------------
                -- Verify start bit at mid-point; discard on glitch.
                when S_START =>
                    if mid_tick = '1' then
                        if rx_sync1 = '0' then
                            bit_cnt <= (others => '0');
                            state   <= S_DATA;
                        else
                            state <= S_IDLE;
                        end if;
                    end if;

                -- ---------------------------------------------------------
                -- Sample 8 data bits at their mid-points.
                when S_DATA =>
                    if mid_tick = '1' then
                        shift_reg <= rx_sync1 & shift_reg(7 downto 1);  -- LSB first
                        if bit_cnt = "111" then
                            state <= S_STOP;
                        else
                            bit_cnt <= bit_cnt + 1;
                        end if;
                    end if;

                -- ---------------------------------------------------------
                -- Sample stop bit; flag framing error if not '1'.
                when S_STOP =>
                    if mid_tick = '1' then
                        rx_data <= shift_reg;
                        if rx_sync1 = '1' then
                            rx_valid <= '1';
                        else
                            rx_error <= '1';
                        end if;
                        state <= S_IDLE;
                    end if;

            end case;
        end if;
    end process;

end architecture rtl;
