-- qam_modulator_nr_tb.vhd
-- Testbench for the 5G NR QAM Modulator (TS 38.212 §5.1)
--
-- Expected values are computed at elaboration time via ieee.math_real using
-- the same ref_fp formula as the DUT's to_fp, so they automatically track
-- any change to the OUTPUT_WIDTH generic.
--
-- Test plan
--   1. BPSK   -- both input values
--   2. QPSK   -- all 4 symbols
--   3. 16-QAM -- all 16 symbols
--   4. 64-QAM -- all 64 symbols (loop + reference model)
--   5. Backpressure -- verifies tready de-assertion when downstream stalls

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity qam_modulator_nr_tb is
end entity qam_modulator_nr_tb;

architecture sim of qam_modulator_nr_tb is

    constant CLK_PERIOD  : time    := 10 ns;
    constant OUTPUT_WIDTH : natural := 8;

    -- -----------------------------------------------------------------------
    -- Normalization factors (must match RTL)
    -- -----------------------------------------------------------------------
    constant NORM_BPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_QPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_16QAM : real := 1.0 / sqrt(10.0);
    constant NORM_64QAM : real := 1.0 / sqrt(42.0);

    -- -----------------------------------------------------------------------
    -- Reference fixed-point helper (mirrors DUT to_fp)
    -- Returns round(raw * norm * 2^(OUTPUT_WIDTH-2)) as an integer
    -- -----------------------------------------------------------------------
    function ref_fp (raw : integer; norm : real) return integer is
        constant SCALE : real := 2.0 ** (OUTPUT_WIDTH - 2);
    begin
        return integer(round(real(raw) * norm * SCALE));
    end function ref_fp;

    -- -----------------------------------------------------------------------
    -- Raw (unscaled) LUT values -- used by the 64-QAM and 16-QAM loops
    -- -----------------------------------------------------------------------
    function ref_raw_64qam (idx : std_logic_vector(2 downto 0)) return integer is
    begin
        case idx is
            when "000"  => return  3;
            when "001"  => return -3;
            when "010"  => return  5;
            when "011"  => return -5;
            when "100"  => return  1;
            when "101"  => return -1;
            when "110"  => return  7;
            when "111"  => return -7;
            when others => return  0;
        end case;
    end function ref_raw_64qam;

    function ref_raw_16qam (idx : std_logic_vector(1 downto 0)) return integer is
    begin
        case idx is
            when "00"   => return  1;
            when "01"   => return -1;
            when "10"   => return  3;
            when "11"   => return -3;
            when others => return  0;
        end case;
    end function ref_raw_16qam;

    -- -----------------------------------------------------------------------
    -- DUT signals
    -- -----------------------------------------------------------------------
    signal aclk          : std_logic := '0';
    signal aresetn       : std_logic := '0';
    signal mod_order     : std_logic_vector(1 downto 0) := "00";
    signal s_axis_tdata  : std_logic_vector(5 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal s_axis_tlast  : std_logic := '0';
    signal m_axis_tdata  : std_logic_vector(2*OUTPUT_WIDTH-1 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '1';
    signal m_axis_tlast  : std_logic;

begin

    aclk <= not aclk after CLK_PERIOD / 2;

    dut : entity work.qam_modulator_nr
        generic map (OUTPUT_WIDTH => OUTPUT_WIDTH)
        port map (
            aclk => aclk, aresetn => aresetn,
            mod_order => mod_order,
            s_axis_tdata => s_axis_tdata, s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready, s_axis_tlast => s_axis_tlast,
            m_axis_tdata => m_axis_tdata, m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready, m_axis_tlast => m_axis_tlast
        );

    p_test : process
        variable pass_count : natural := 0;
        variable fail_count : natural := 0;
        variable got_i, got_q : integer;
        variable test_bits : std_logic_vector(5 downto 0);

        -- Send one symbol and verify the IQ output one cycle later.
        procedure send_check (
            ord : std_logic_vector(1 downto 0);
            bits : std_logic_vector(5 downto 0);
            exp_i, exp_q : integer;
            lbl : string
        ) is
        begin
            mod_order     <= ord;
            s_axis_tdata  <= bits;
            s_axis_tvalid <= '1';
            m_axis_tready <= '1';
            loop
                wait until rising_edge(aclk);
                exit when s_axis_tready = '1';
            end loop;
            s_axis_tvalid <= '0';
            wait until rising_edge(aclk);
            got_i := to_integer(signed(m_axis_tdata(OUTPUT_WIDTH-1 downto 0)));
            got_q := to_integer(signed(m_axis_tdata(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH)));
            if m_axis_tvalid /= '1' then
                report "FAIL [" & lbl & "]: m_axis_tvalid not asserted" severity error;
                fail_count := fail_count + 1;
            elsif got_i = exp_i and got_q = exp_q then
                report "PASS [" & lbl & "] I=" & integer'image(got_i) & " Q=" & integer'image(got_q) severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL [" & lbl & "] got I=" & integer'image(got_i) & " Q=" & integer'image(got_q)
                    & " exp I=" & integer'image(exp_i) & " Q=" & integer'image(exp_q) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure send_check;

    begin
        aresetn <= '0'; s_axis_tvalid <= '0'; m_axis_tready <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(aclk); aresetn <= '1';
        wait until rising_edge(aclk);

        -- -------------------------------------------------------------------
        -- 1. BPSK  (mod_order = "00")
        --    d = (1/sqrt(2))(1-2*b0)(1+j)  ->  I = Q = +/-1/sqrt(2)
        -- -------------------------------------------------------------------
        report "--- BPSK ---" severity note;
        send_check("00", "000000", ref_fp( 1, NORM_BPSK), ref_fp( 1, NORM_BPSK), "BPSK b0=0");
        send_check("00", "000001", ref_fp(-1, NORM_BPSK), ref_fp(-1, NORM_BPSK), "BPSK b0=1");

        -- -------------------------------------------------------------------
        -- 2. QPSK  (mod_order = "01")
        --    I = (1-2*b0)/sqrt(2),  Q = (1-2*b1)/sqrt(2)
        -- -------------------------------------------------------------------
        report "--- QPSK ---" severity note;
        send_check("01", "000000", ref_fp( 1, NORM_QPSK), ref_fp( 1, NORM_QPSK), "QPSK b1b0=00");
        send_check("01", "000001", ref_fp(-1, NORM_QPSK), ref_fp( 1, NORM_QPSK), "QPSK b1b0=01");
        send_check("01", "000010", ref_fp( 1, NORM_QPSK), ref_fp(-1, NORM_QPSK), "QPSK b1b0=10");
        send_check("01", "000011", ref_fp(-1, NORM_QPSK), ref_fp(-1, NORM_QPSK), "QPSK b1b0=11");

        -- -------------------------------------------------------------------
        -- 3. 16-QAM  (mod_order = "10")  -- all 16 symbols
        --    I from {b2,b0},  Q from {b3,b1}
        -- -------------------------------------------------------------------
        report "--- 16-QAM ---" severity note;
        for n in 0 to 15 loop
            test_bits := std_logic_vector(to_unsigned(n, 6));
            send_check(
                "10",
                test_bits,
                ref_fp(ref_raw_16qam(test_bits(2) & test_bits(0)), NORM_16QAM),
                ref_fp(ref_raw_16qam(test_bits(3) & test_bits(1)), NORM_16QAM),
                "16QAM n=" & integer'image(n)
            );
        end loop;

        -- -------------------------------------------------------------------
        -- 4. 64-QAM  (mod_order = "11")  -- all 64 symbols
        --    I from {b4,b2,b0},  Q from {b5,b3,b1}
        -- -------------------------------------------------------------------
        report "--- 64-QAM ---" severity note;
        for n in 0 to 63 loop
            test_bits := std_logic_vector(to_unsigned(n, 6));
            send_check(
                "11",
                test_bits,
                ref_fp(ref_raw_64qam(test_bits(4) & test_bits(2) & test_bits(0)), NORM_64QAM),
                ref_fp(ref_raw_64qam(test_bits(5) & test_bits(3) & test_bits(1)), NORM_64QAM),
                "64QAM n=" & integer'image(n)
            );
        end loop;

        -- -------------------------------------------------------------------
        -- 5. Backpressure test
        -- -------------------------------------------------------------------
        report "--- Backpressure ---" severity note;

        m_axis_tready <= '0';
        mod_order     <= "11";
        -- "110000": b5=1,b4=1,b3..0=0  ->  I-idx={b4,b2,b0}="100"->raw=+1
        --                                   Q-idx={b5,b3,b1}="100"->raw=+1
        s_axis_tdata  <= "110000";
        s_axis_tvalid <= '1';
        wait until rising_edge(aclk);
        s_axis_tvalid <= '0';

        wait until rising_edge(aclk);
        if s_axis_tready /= '0' then
            report "FAIL [backpressure]: tready should be '0' when output stalls"
                severity error;
            fail_count := fail_count + 1;
        else
            report "PASS [backpressure]: tready correctly de-asserted" severity note;
            pass_count := pass_count + 1;
        end if;

        m_axis_tready <= '1';
        wait until rising_edge(aclk);
        got_i := to_integer(signed(m_axis_tdata(OUTPUT_WIDTH-1 downto 0)));
        got_q := to_integer(signed(m_axis_tdata(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH)));
        if m_axis_tvalid = '1' and got_i = ref_fp(1, NORM_64QAM) and got_q = ref_fp(1, NORM_64QAM) then
            report "PASS [backpressure]: I=" & integer'image(got_i)
                & " Q=" & integer'image(got_q)
                severity note;
            pass_count := pass_count + 1;
        else
            report "FAIL [backpressure]: got I=" & integer'image(got_i)
                & " Q=" & integer'image(got_q)
                & " exp I=Q=" & integer'image(ref_fp(1, NORM_64QAM))
                severity error;
            fail_count := fail_count + 1;
        end if;

        -- -------------------------------------------------------------------
        -- Final report
        -- -------------------------------------------------------------------
        report "========================================"  severity note;
        report "Tests passed : " & integer'image(pass_count) severity note;
        report "Tests failed : " & integer'image(fail_count) severity note;
        report "========================================"  severity note;

        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SIMULATION FAILED" severity failure;
        end if;
        wait;
    end process p_test;

end architecture sim;
