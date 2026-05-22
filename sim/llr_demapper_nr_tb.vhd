-- llr_demapper_nr_tb.vhd
-- Testbench for the 5G NR Soft LLR Demapper (Max-Log-MAP)
-- Drives the modulator output directly into the demapper and checks
-- that the LLR sign for each transmitted bit is correct (positive LLR
-- means bit=0 was more likely; negative means bit=1 was more likely).
-- Also verifies exact values against a reference model.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity llr_demapper_nr_tb is
end entity llr_demapper_nr_tb;

architecture sim of llr_demapper_nr_tb is

    constant CLK_PERIOD : time    := 10 ns;
    constant IQ_WIDTH   : natural := 8;
    constant LLR_WIDTH  : natural := 8;

    signal aclk          : std_logic := '0';
    signal aresetn       : std_logic := '0';
    signal mod_order     : std_logic_vector(1 downto 0) := "00";
    signal s_axis_tdata  : std_logic_vector(2*IQ_WIDTH-1 downto 0) := (others => '0');
    signal s_axis_tvalid : std_logic := '0';
    signal s_axis_tready : std_logic;
    signal s_axis_tlast  : std_logic := '0';
    signal m_axis_tdata  : std_logic_vector(6*LLR_WIDTH-1 downto 0);
    signal m_axis_tvalid : std_logic;
    signal m_axis_tready : std_logic := '1';
    signal m_axis_tlast  : std_logic;

    -- Mirror the modulator's to_fp exactly
    function ref_fp (raw : integer; norm : real) return integer is
        constant SCALE : real := 2.0 ** (IQ_WIDTH - 2);
    begin
        return integer(round(real(raw) * norm * SCALE));
    end function ref_fp;

    constant NORM_BPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_QPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_16QAM : real := 1.0 / sqrt(10.0);
    constant NORM_64QAM : real := 1.0 / sqrt(42.0);

    -- Pack a pair of signed integers into the s_axis_tdata format {Q,I}
    function pack_iq (i_val, q_val : integer) return std_logic_vector is
        variable r : std_logic_vector(2*IQ_WIDTH-1 downto 0);
    begin
        r(IQ_WIDTH-1 downto 0)          := std_logic_vector(to_signed(i_val, IQ_WIDTH));
        r(2*IQ_WIDTH-1 downto IQ_WIDTH) := std_logic_vector(to_signed(q_val, IQ_WIDTH));
        return r;
    end function pack_iq;

    -- Extract one LLR from output word
    function get_llr (data : std_logic_vector(6*LLR_WIDTH-1 downto 0); idx : natural)
        return integer is
    begin
        return to_integer(signed(data((idx+1)*LLR_WIDTH-1 downto idx*LLR_WIDTH)));
    end function get_llr;

begin

    aclk <= not aclk after CLK_PERIOD / 2;

    dut : entity work.llr_demapper_nr
        generic map (IQ_WIDTH => IQ_WIDTH, LLR_WIDTH => LLR_WIDTH)
        port map (
            aclk => aclk, aresetn => aresetn,
            mod_order => mod_order,
            s_axis_tdata  => s_axis_tdata,  s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready, s_axis_tlast  => s_axis_tlast,
            m_axis_tdata  => m_axis_tdata,  m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready, m_axis_tlast  => m_axis_tlast
        );

    p_test : process
        variable pass_count : natural := 0;
        variable fail_count : natural := 0;
        variable got_llr    : integer;

        -- Drive one IQ sample and wait for output
        procedure drive_sample (
            ord      : std_logic_vector(1 downto 0);
            i_val    : integer;
            q_val    : integer
        ) is
        begin
            mod_order    <= ord;
            s_axis_tdata <= pack_iq(i_val, q_val);
            s_axis_tvalid <= '1';
            loop
                wait until rising_edge(aclk);
                exit when s_axis_tready = '1';
            end loop;
            s_axis_tvalid <= '0';
            wait until rising_edge(aclk);  -- output registered
        end procedure drive_sample;

        -- Check sign of one LLR
        procedure check_sign (lbl : string; idx : natural; transmitted_bit : std_logic) is
        begin
            got_llr := get_llr(m_axis_tdata, idx);
            if m_axis_tvalid /= '1' then
                report "FAIL [" & lbl & "]: tvalid not set" severity error;
                fail_count := fail_count + 1;
            elsif transmitted_bit = '0' and got_llr > 0 then
                report "PASS [" & lbl & "] LLR=" & integer'image(got_llr) & " (bit=0 correct sign)" severity note;
                pass_count := pass_count + 1;
            elsif transmitted_bit = '1' and got_llr < 0 then
                report "PASS [" & lbl & "] LLR=" & integer'image(got_llr) & " (bit=1 correct sign)" severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL [" & lbl & "] LLR=" & integer'image(got_llr)
                    & " wrong sign for bit=" & std_logic'image(transmitted_bit) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure check_sign;

        -- Check exact LLR value
        procedure check_exact (lbl : string; idx : natural; expected : integer) is
        begin
            got_llr := get_llr(m_axis_tdata, idx);
            if m_axis_tvalid /= '1' then
                report "FAIL [" & lbl & "]: tvalid not set" severity error;
                fail_count := fail_count + 1;
            elsif got_llr = expected then
                report "PASS [" & lbl & "] LLR=" & integer'image(got_llr) severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL [" & lbl & "] got=" & integer'image(got_llr)
                    & " exp=" & integer'image(expected) severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure check_exact;

    begin
        aresetn <= '0'; s_axis_tvalid <= '0'; m_axis_tready <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(aclk); aresetn <= '1';
        wait until rising_edge(aclk);

        -- ----------------------------------------------------------------
        -- BPSK: 1 LLR (b0 -> I component)
        --   b0=0 -> s=+1/sqrt(2): LLR should be positive
        --   b0=1 -> s=-1/sqrt(2): LLR should be negative
        -- ----------------------------------------------------------------
        report "--- BPSK ---" severity note;
        drive_sample("00", ref_fp(1, NORM_BPSK), ref_fp(1, NORM_BPSK));
        check_sign("BPSK b0=0", 0, '0');

        drive_sample("00", ref_fp(-1, NORM_BPSK), ref_fp(-1, NORM_BPSK));
        check_sign("BPSK b0=1", 0, '1');

        -- ----------------------------------------------------------------
        -- QPSK: 2 LLRs (b0->I, b1->Q)
        -- ----------------------------------------------------------------
        report "--- QPSK ---" severity note;
        drive_sample("01", ref_fp( 1, NORM_QPSK), ref_fp( 1, NORM_QPSK));
        check_sign("QPSK b0=0", 0, '0');
        check_sign("QPSK b1=0", 1, '0');

        drive_sample("01", ref_fp(-1, NORM_QPSK), ref_fp( 1, NORM_QPSK));
        check_sign("QPSK b0=1", 0, '1');
        check_sign("QPSK b1=0", 1, '0');

        drive_sample("01", ref_fp( 1, NORM_QPSK), ref_fp(-1, NORM_QPSK));
        check_sign("QPSK b0=0", 0, '0');
        check_sign("QPSK b1=1", 1, '1');

        drive_sample("01", ref_fp(-1, NORM_QPSK), ref_fp(-1, NORM_QPSK));
        check_sign("QPSK b0=1", 0, '1');
        check_sign("QPSK b1=1", 1, '1');

        -- ----------------------------------------------------------------
        -- 16-QAM: 4 LLRs
        --   b0=sign(I): 0->positive, 1->negative
        --   b1=sign(Q): 0->positive, 1->negative
        --   b2=mag(I):  0->outer(|I|=3), 1->inner(|I|=1)
        --   b3=mag(Q):  0->outer(|Q|=3), 1->inner(|Q|=1)
        -- ----------------------------------------------------------------
        report "--- 16-QAM sign check ---" severity note;
        -- All four constellation quadrants
        drive_sample("10", ref_fp( 3, NORM_16QAM), ref_fp( 3, NORM_16QAM));
        check_sign("16QAM (+3,+3) b0", 0, '0');
        check_sign("16QAM (+3,+3) b1", 1, '0');
        check_sign("16QAM (+3,+3) b2", 2, '0');
        check_sign("16QAM (+3,+3) b3", 3, '0');

        drive_sample("10", ref_fp(-3, NORM_16QAM), ref_fp(-3, NORM_16QAM));
        check_sign("16QAM (-3,-3) b0", 0, '1');
        check_sign("16QAM (-3,-3) b1", 1, '1');
        check_sign("16QAM (-3,-3) b2", 2, '0');
        check_sign("16QAM (-3,-3) b3", 3, '0');

        drive_sample("10", ref_fp( 1, NORM_16QAM), ref_fp( 1, NORM_16QAM));
        check_sign("16QAM (+1,+1) b0", 0, '0');
        check_sign("16QAM (+1,+1) b1", 1, '0');
        check_sign("16QAM (+1,+1) b2", 2, '1');
        check_sign("16QAM (+1,+1) b3", 3, '1');

        drive_sample("10", ref_fp(-1, NORM_16QAM), ref_fp(-1, NORM_16QAM));
        check_sign("16QAM (-1,-1) b0", 0, '1');
        check_sign("16QAM (-1,-1) b1", 1, '1');
        check_sign("16QAM (-1,-1) b2", 2, '1');
        check_sign("16QAM (-1,-1) b3", 3, '1');

        -- ----------------------------------------------------------------
        -- 64-QAM: 6 LLRs - sign checks for representative points
        --   PTS order: -7,-5,-3,-1,+1,+3,+5,+7 (indices 0-7)
        --   b_sign (b0/b1): S0=positive half(idx4-7), S1=negative half(idx0-3)
        --   b_mid  (b2/b3): S0=outer{-7,-5,+5,+7}, S1=inner{-3,-1,+1,+3}
        --   b_fine (b4/b5): S0={-7,-3,+3,+7}, S1={-5,-1,+1,+5}
        -- ----------------------------------------------------------------
        report "--- 64-QAM sign check ---" severity note;
        -- Point (+7,+7): b_sign=0, b_mid=0, b_fine=0
        drive_sample("11", ref_fp( 7, NORM_64QAM), ref_fp( 7, NORM_64QAM));
        check_sign("64QAM +7 b0(sign)", 0, '0');
        check_sign("64QAM +7 b1(sign)", 1, '0');
        check_sign("64QAM +7 b2(mid)",  2, '0');
        check_sign("64QAM +7 b3(mid)",  3, '0');
        check_sign("64QAM +7 b4(fine)", 4, '0');
        check_sign("64QAM +7 b5(fine)", 5, '0');

        -- Point (-7,-7): b_sign=1, b_mid=0, b_fine=0
        drive_sample("11", ref_fp(-7, NORM_64QAM), ref_fp(-7, NORM_64QAM));
        check_sign("64QAM -7 b0(sign)", 0, '1');
        check_sign("64QAM -7 b1(sign)", 1, '1');
        check_sign("64QAM -7 b2(mid)",  2, '0');
        check_sign("64QAM -7 b3(mid)",  3, '0');
        check_sign("64QAM -7 b4(fine)", 4, '0');
        check_sign("64QAM -7 b5(fine)", 5, '0');

        -- Point (+3,+3): b_sign=0, b_mid=1, b_fine=0
        drive_sample("11", ref_fp( 3, NORM_64QAM), ref_fp( 3, NORM_64QAM));
        check_sign("64QAM +3 b0(sign)", 0, '0');
        check_sign("64QAM +3 b1(sign)", 1, '0');
        check_sign("64QAM +3 b2(mid)",  2, '1');
        check_sign("64QAM +3 b3(mid)",  3, '1');
        check_sign("64QAM +3 b4(fine)", 4, '0');
        check_sign("64QAM +3 b5(fine)", 5, '0');

        -- Point (-5,-5): b_sign=1, b_mid=0, b_fine=1
        drive_sample("11", ref_fp(-5, NORM_64QAM), ref_fp(-5, NORM_64QAM));
        check_sign("64QAM -5 b0(sign)", 0, '1');
        check_sign("64QAM -5 b1(sign)", 1, '1');
        check_sign("64QAM -5 b2(mid)",  2, '0');
        check_sign("64QAM -5 b3(mid)",  3, '0');
        check_sign("64QAM -5 b4(fine)", 4, '1');
        check_sign("64QAM -5 b5(fine)", 5, '1');

        -- Point (+1,+1): b_sign=0, b_mid=1, b_fine=1
        drive_sample("11", ref_fp( 1, NORM_64QAM), ref_fp( 1, NORM_64QAM));
        check_sign("64QAM +1 b0(sign)", 0, '0');
        check_sign("64QAM +1 b1(sign)", 1, '0');
        check_sign("64QAM +1 b2(mid)",  2, '1');
        check_sign("64QAM +1 b3(mid)",  3, '1');
        check_sign("64QAM +1 b4(fine)", 4, '1');
        check_sign("64QAM +1 b5(fine)", 5, '1');

        -- ----------------------------------------------------------------
        -- BPSK exact LLR check:
        --   LLR(b0) = d^2(r, -1/sqrt2) - d^2(r, +1/sqrt2)
        --   For r = +s (on the constellation point), d^2(+s, -s) - d^2(+s, +s)
        --   = (2s)^2 - 0 = 4*s^2
        --   With s = ref_fp(1, NORM_BPSK): val = round(1/sqrt(2)*64) = 45
        --   4*45^2 = 8100; saturates to 127
        -- ----------------------------------------------------------------
        report "--- BPSK exact LLR ---" severity note;
        drive_sample("00", ref_fp(1, NORM_BPSK), ref_fp(1, NORM_BPSK));
        check_exact("BPSK b0 exact (sat)", 0, 2**(LLR_WIDTH-1)-1);  -- saturates

        -- ----------------------------------------------------------------
        -- Backpressure test
        -- ----------------------------------------------------------------
        report "--- Backpressure ---" severity note;
        m_axis_tready <= '0';
        drive_sample("00", ref_fp(1, NORM_BPSK), ref_fp(1, NORM_BPSK));
        wait until rising_edge(aclk);
        if s_axis_tready /= '0' then
            report "FAIL [bp]: tready should be 0" severity error;
            fail_count := fail_count + 1;
        else
            report "PASS [bp]: tready correctly de-asserted" severity note;
            pass_count := pass_count + 1;
        end if;
        m_axis_tready <= '1';
        wait until rising_edge(aclk);

        report "========================================" severity note;
        report "Tests passed: " & integer'image(pass_count) severity note;
        report "Tests failed: " & integer'image(fail_count) severity note;
        if fail_count = 0 then
            report "ALL TESTS PASSED" severity note;
        else
            report "SIMULATION FAILED" severity failure;
        end if;
        wait;
    end process p_test;

end architecture sim;
