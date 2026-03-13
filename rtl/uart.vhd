-- uart.vhd
-- Top-level UART module with programmable baud rate
--
-- Baud rate is set at run-time via baud_div:
--   baud_div = (CLK_FREQ / BAUD_RATE) - 1
--
-- Common values (50 MHz clock):
--   9600   baud  ->  baud_div = 5207
--   19200  baud  ->  baud_div = 2603
--   38400  baud  ->  baud_div = 1301
--   57600  baud  ->  baud_div = 867
--   115200 baud  ->  baud_div = 433
--
-- Ports
-- -----
--   clk      : system clock
--   rst_n    : active-low asynchronous reset
--   baud_div : 16-bit runtime-programmable divisor (stable during operation)
--   tx_data  : byte to transmit
--   tx_valid : pulse for one cycle to start transmission
--   tx_ready : high when transmitter is idle
--   tx       : UART TX serial output (idle = '1')
--   rx       : UART RX serial input  (idle = '1')
--   rx_data  : received byte
--   rx_valid : one-cycle pulse when rx_data is valid
--   rx_error : one-cycle pulse on framing error

library ieee;
use ieee.std_logic_1164.all;

entity uart is
    generic (
        CLK_FREQ  : integer := 50_000_000;
        BAUD_RATE : integer := 115_200;
        CNT_W     : integer := 16
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;
        baud_div : in  std_logic_vector(CNT_W-1 downto 0);
        -- Transmitter
        tx_data  : in  std_logic_vector(7 downto 0);
        tx_valid : in  std_logic;
        tx_ready : out std_logic;
        tx       : out std_logic;
        -- Receiver
        rx       : in  std_logic;
        rx_data  : out std_logic_vector(7 downto 0);
        rx_valid : out std_logic;
        rx_error : out std_logic
    );
end entity uart;

architecture rtl of uart is

    signal baud_tick : std_logic;
    signal mid_tick  : std_logic;

begin

    -- -----------------------------------------------------------------------
    -- Baud rate generator — shared between TX and RX
    -- -----------------------------------------------------------------------
    u_baud_gen : entity work.uart_baud_gen
        generic map (CNT_W => CNT_W)
        port map (
            clk       => clk,
            rst_n     => rst_n,
            baud_div  => baud_div,
            baud_tick => baud_tick,
            mid_tick  => mid_tick
        );

    -- -----------------------------------------------------------------------
    -- Transmitter
    -- -----------------------------------------------------------------------
    u_tx : entity work.uart_tx
        port map (
            clk       => clk,
            rst_n     => rst_n,
            baud_tick => baud_tick,
            tx_data   => tx_data,
            tx_valid  => tx_valid,
            tx_ready  => tx_ready,
            tx        => tx
        );

    -- -----------------------------------------------------------------------
    -- Receiver
    -- -----------------------------------------------------------------------
    u_rx : entity work.uart_rx
        port map (
            clk       => clk,
            rst_n     => rst_n,
            baud_tick => baud_tick,
            mid_tick  => mid_tick,
            rx        => rx,
            rx_data   => rx_data,
            rx_valid  => rx_valid,
            rx_error  => rx_error
        );

end architecture rtl;
