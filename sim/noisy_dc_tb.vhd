-- Testbench: Continuous pseudo-random noisy signal around a DC offset.
--
-- Noise is produced by a 16-bit Galois LFSR (taps at bits 16,15,13,4).
-- The upper N bits of the LFSR state are used as a signed noise sample,
-- so the amplitude scales with NOISE_BITS.  The DC offset and noise width
-- are both generics so they are easy to sweep from the simulator.
--
-- Output port:  data_out  – std_logic_vector, updated every CLK_PERIOD.
-- The value equals DC_OFFSET + signed_noise, saturated to the output range.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity noisy_dc_tb is
    generic (
        DATA_WIDTH  : positive := 16;   -- total output word width (bits)
        NOISE_BITS  : positive := 6;    -- MSBs of LFSR used as noise (≤ DATA_WIDTH)
        DC_OFFSET   : integer  := 1000; -- nominal DC value (signed, fits DATA_WIDTH)
        CLK_PERIOD  : time     := 10 ns -- simulation clock period
    );
end entity noisy_dc_tb;

architecture sim of noisy_dc_tb is

    -- ------------------------------------------------------------------ --
    --  Signals
    -- ------------------------------------------------------------------ --
    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal data_out : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');

    -- 16-bit LFSR state; seed must be non-zero
    signal lfsr : std_logic_vector(15 downto 0) := x"ACE1";

    -- Convenience aliases
    constant MAX_VAL : integer :=  2**(DATA_WIDTH - 1) - 1;
    constant MIN_VAL : integer := -2**(DATA_WIDTH - 1);

    -- ------------------------------------------------------------------ --
    --  Helper: saturating add
    -- ------------------------------------------------------------------ --
    function sat_add(a, b, lo, hi : integer) return integer is
        variable s : integer;
    begin
        s := a + b;
        if    s > hi then return hi;
        elsif s < lo then return lo;
        else              return s;
        end if;
    end function;

begin

    -- ------------------------------------------------------------------ --
    --  Clock generation – runs forever
    -- ------------------------------------------------------------------ --
    clk <= not clk after CLK_PERIOD / 2;

    -- ------------------------------------------------------------------ --
    --  Reset: release after 4 cycles
    -- ------------------------------------------------------------------ --
    rst <= '0' after CLK_PERIOD * 4;

    -- ------------------------------------------------------------------ --
    --  Galois LFSR + output driver
    --
    --  Feedback polynomial for 16-bit: x^16 + x^15 + x^13 + x^4 + 1
    --  (taps at positions 16, 15, 13, 4 → bits 15, 14, 12, 3 in 0-based)
    -- ------------------------------------------------------------------ --
    process(clk)
        variable feedback  : std_logic;
        variable next_lfsr : std_logic_vector(15 downto 0);
        variable noise_raw : signed(NOISE_BITS - 1 downto 0);
        variable sample    : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                lfsr     <= x"ACE1";
                data_out <= std_logic_vector(to_signed(DC_OFFSET, DATA_WIDTH));
            else
                -- Galois LFSR shift
                feedback  := lfsr(0);
                next_lfsr := '0' & lfsr(15 downto 1);
                if feedback = '1' then
                    -- XOR taps: bits 15, 14, 12, 3 (Galois form)
                    next_lfsr(15) := next_lfsr(15) xor '1';
                    next_lfsr(14) := next_lfsr(14) xor '1';
                    next_lfsr(12) := next_lfsr(12) xor '1';
                    next_lfsr(3)  := next_lfsr(3)  xor '1';
                end if;
                lfsr <= next_lfsr;

                -- Extract top NOISE_BITS as signed noise value
                noise_raw := signed(next_lfsr(15 downto 16 - NOISE_BITS));

                -- Add noise to DC offset with saturation
                sample   := sat_add(DC_OFFSET, to_integer(noise_raw),
                                    MIN_VAL, MAX_VAL);
                data_out <= std_logic_vector(to_signed(sample, DATA_WIDTH));
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------------ --
    --  Stimulus / self-checking process
    --  Prints header once, then logs 20 samples, then runs silently.
    --  Simulation must be stopped externally (or add a "wait for X" here).
    -- ------------------------------------------------------------------ --
    process
    begin
        -- Wait for reset to de-assert
        wait until rst = '0';
        wait until rising_edge(clk);

        report "=== noisy_dc_tb started ===" severity note;
        report "    DATA_WIDTH = " & integer'image(DATA_WIDTH)  severity note;
        report "    NOISE_BITS = " & integer'image(NOISE_BITS)  severity note;
        report "    DC_OFFSET  = " & integer'image(DC_OFFSET)   severity note;

        -- Log first 20 samples so the waveform viewer isn't the only way
        -- to verify the output
        for i in 0 to 19 loop
            wait until rising_edge(clk);
            report "  sample[" & integer'image(i) & "] = " &
                   integer'image(to_integer(signed(data_out))) severity note;
        end loop;

        report "--- continuous generation running (stop sim to end) ---"
               severity note;

        -- Run for a fixed duration then stop, or remove the wait statement
        -- to let the simulator's own end-time control the run.
        wait for CLK_PERIOD * 10_000;
        report "=== noisy_dc_tb: simulation complete ===" severity note;
        std.env.stop;
    end process;

end architecture sim;
