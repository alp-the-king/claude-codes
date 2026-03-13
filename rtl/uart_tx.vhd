-- uart_tx.vhd
-- UART transmitter
--
-- Frame format: 1 start bit, 8 data bits (LSB first), 1 stop bit
--
-- Usage:
--   1. Place byte on tx_data and assert tx_valid for one clock cycle.
--   2. tx_ready goes low while transmitting; wait for it to return high.
--   3. tx idles high.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        baud_tick : in  std_logic;
        tx_data   : in  std_logic_vector(7 downto 0);
        tx_valid  : in  std_logic;
        tx_ready  : out std_logic;
        tx        : out std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal state     : state_t;
    signal shift_reg : std_logic_vector(7 downto 0);
    signal bit_cnt   : unsigned(2 downto 0);

begin

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            state     <= S_IDLE;
            shift_reg <= (others => '0');
            bit_cnt   <= (others => '0');
            tx        <= '1';
            tx_ready  <= '1';

        elsif rising_edge(clk) then
            case state is

                -- ---------------------------------------------------------
                when S_IDLE =>
                    tx       <= '1';
                    tx_ready <= '1';
                    if tx_valid = '1' then
                        shift_reg <= tx_data;
                        tx_ready  <= '0';
                        state     <= S_START;
                    end if;

                -- ---------------------------------------------------------
                -- Drive start bit (logic 0); advance on baud_tick.
                when S_START =>
                    tx <= '0';
                    if baud_tick = '1' then
                        bit_cnt <= (others => '0');
                        state   <= S_DATA;
                    end if;

                -- ---------------------------------------------------------
                -- Shift out 8 data bits, LSB first.
                when S_DATA =>
                    tx <= shift_reg(0);
                    if baud_tick = '1' then
                        shift_reg <= '0' & shift_reg(7 downto 1);
                        if bit_cnt = "111" then
                            state <= S_STOP;
                        else
                            bit_cnt <= bit_cnt + 1;
                        end if;
                    end if;

                -- ---------------------------------------------------------
                -- Drive stop bit (logic 1) for one baud period.
                when S_STOP =>
                    tx <= '1';
                    if baud_tick = '1' then
                        state    <= S_IDLE;
                        tx_ready <= '1';
                    end if;

            end case;
        end if;
    end process;

end architecture rtl;
