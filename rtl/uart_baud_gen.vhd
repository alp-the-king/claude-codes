-- uart_baud_gen.vhd
-- Programmable baud rate generator
--
-- Generates two tick signals:
--   baud_tick  : one-cycle pulse at the start of each baud period
--   mid_tick   : one-cycle pulse at the mid-point of each baud period (RX sampling)
--
-- Baud rate = CLK_FREQ / (baud_div + 1)
-- Example: 50 MHz clock, 115200 baud -> baud_div = 50_000_000/115200 - 1 = 433

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_baud_gen is
    generic (
        CNT_W : integer := 16
    );
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        baud_div  : in  std_logic_vector(CNT_W-1 downto 0);
        baud_tick : out std_logic;
        mid_tick  : out std_logic
    );
end entity uart_baud_gen;

architecture rtl of uart_baud_gen is
    signal cnt      : unsigned(CNT_W-1 downto 0);
    signal half_div : unsigned(CNT_W-1 downto 0);
begin

    half_div <= unsigned(baud_div) srl 1;

    process(clk, rst_n)
    begin
        if rst_n = '0' then
            cnt       <= (others => '0');
            baud_tick <= '0';
            mid_tick  <= '0';
        elsif rising_edge(clk) then
            baud_tick <= '0';
            mid_tick  <= '0';

            if cnt = unsigned(baud_div) then
                cnt       <= (others => '0');
                baud_tick <= '1';
            else
                cnt <= cnt + 1;
            end if;

            if cnt = half_div then
                mid_tick <= '1';
            end if;
        end if;
    end process;

end architecture rtl;
