-- Testbench: Continuous random noisy signal around a DC offset.
--
-- Noise is produced by ieee.math_real.uniform(), which returns a
-- uniformly-distributed real in [0.0, 1.0).  The value is scaled to
-- [-NOISE_AMP, +NOISE_AMP) and added to DC_OFFSET each clock cycle.
-- Output is saturated to the signed range of DATA_WIDTH bits.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity noisy_dc_tb is
    generic (
        DATA_WIDTH : positive := 16;    -- output word width (bits)
        DC_OFFSET  : integer  := 1000;  -- nominal DC level (signed integer)
        NOISE_AMP  : positive := 100;   -- peak noise amplitude (± LSBs)
        CLK_PERIOD : time     := 10 ns  -- simulation clock period
    );
end entity noisy_dc_tb;

architecture sim of noisy_dc_tb is

    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal data_out : std_logic_vector(DATA_WIDTH - 1 downto 0);

    constant MAX_VAL : integer :=  2**(DATA_WIDTH - 1) - 1;
    constant MIN_VAL : integer := -2**(DATA_WIDTH - 1);

    function sat(val, lo, hi : integer) return integer is
    begin
        if    val > hi then return hi;
        elsif val < lo then return lo;
        else                return val;
        end if;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2;
    rst <= '0' after CLK_PERIOD * 4;

    -- ------------------------------------------------------------------ --
    --  Data generation process
    --  uniform() is a simulation-only call; seed variables are held across
    --  iterations inside the process so the sequence is not repeated.
    -- ------------------------------------------------------------------ --
    process (clk)
        variable seed1   : positive := 42;
        variable seed2   : positive := 137;
        variable rand    : real;
        variable noise   : integer;
        variable sample  : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                data_out <= std_logic_vector(to_signed(DC_OFFSET, DATA_WIDTH));
            else
                -- uniform() returns rand in [0.0, 1.0)
                -- scale to [-NOISE_AMP, +NOISE_AMP)
                uniform(seed1, seed2, rand);
                noise  := integer((rand * 2.0 - 1.0) * real(NOISE_AMP));
                sample := sat(DC_OFFSET + noise, MIN_VAL, MAX_VAL);
                data_out <= std_logic_vector(to_signed(sample, DATA_WIDTH));
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------------ --
    --  Stimulus / logging process
    -- ------------------------------------------------------------------ --
    process
    begin
        wait until rst = '0';
        wait until rising_edge(clk);

        report "=== noisy_dc_tb started ===" severity note;
        report "    DATA_WIDTH = " & integer'image(DATA_WIDTH) severity note;
        report "    DC_OFFSET  = " & integer'image(DC_OFFSET)  severity note;
        report "    NOISE_AMP  = +/-" & integer'image(NOISE_AMP) & " LSBs" severity note;

        for i in 0 to 19 loop
            wait until rising_edge(clk);
            report "  sample[" & integer'image(i) & "] = " &
                   integer'image(to_integer(signed(data_out))) severity note;
        end loop;

        report "--- continuous generation running ---" severity note;

        wait for CLK_PERIOD * 10_000;
        report "=== noisy_dc_tb: simulation complete ===" severity note;
        std.env.stop;
    end process;

end architecture sim;
