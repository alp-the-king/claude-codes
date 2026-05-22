-- qam_modulator_nr_tb.vhd
-- Testbench for the 5G NR QAM Modulator (TS 38.212 §5.1)
--
-- Test plan
--   1. BPSK   – both input values
--   2. QPSK   – all 4 symbols
--   3. 16-QAM – all 16 symbols
--   4. 64-QAM – all 64 symbols (loop using reference model)
--   5. Backpressure – verifies tready de-assertion when downstream stalls

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qam_modulator_nr_tb is
end entity qam_modulator_nr_tb;

architecture sim of qam_modulator_nr_tb is

    -- -----------------------------------------------------------------------
    -- Constants
    -- -----------------------------------------------------------------------
    constant CLK_PERIOD  : time    := 10 ns;    -- 100 MHz
    constant OUTPUT_WIDTH : natural := 8;

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

    -- -----------------------------------------------------------------------
    -- 64-QAM reference LUT (mirrors rtl implementation)
    -- idx(2)=b₄/b₅  idx(1)=b₂/b₃  idx(0)=b₀/b₁
    -- -----------------------------------------------------------------------
    function ref_lut_64qam (idx : std_logic_vector(2 downto 0)) return integer is
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
    end function ref_lut_64qam;

    -- 16-QAM reference LUT
    function ref_lut_16qam (idx : std_logic_vector(1 downto 0)) return integer is
    begin
        case idx is
            when "00"   => return  1;
            when "01"   => return -1;
            when "10"   => return  3;
            when "11"   => return -3;
            when others => return  0;
        end case;
    end function ref_lut_16qam;

begin

    -- -----------------------------------------------------------------------
    -- Clock
    -- -----------------------------------------------------------------------
    aclk <= not aclk after CLK_PERIOD / 2;

    -- -----------------------------------------------------------------------
    -- DUT
    -- -----------------------------------------------------------------------
    dut : entity work.qam_modulator_nr
        generic map (OUTPUT_WIDTH => OUTPUT_WIDTH)
        port map (
            aclk          => aclk,
            aresetn       => aresetn,
            mod_order     => mod_order,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            s_axis_tlast  => s_axis_tlast,
            m_axis_tdata  => m_axis_tdata,
            m_axis_tvalid => m_axis_tvalid,
            m_axis_tready => m_axis_tready,
            m_axis_tlast  => m_axis_tlast
        );

    -- -----------------------------------------------------------------------
    -- Stimulus / checker
    -- -----------------------------------------------------------------------
    p_test : process

        variable pass_count : natural := 0;
        variable fail_count : natural := 0;
        variable got_i      : integer;
        variable got_q      : integer;
        variable test_bits  : std_logic_vector(5 downto 0);

        -- Send one symbol and verify the IQ output one cycle later.
        -- m_axis_tready is kept asserted throughout.
        procedure send_check (
            ord   : std_logic_vector(1 downto 0);
            bits  : std_logic_vector(5 downto 0);
            exp_i : integer;
            exp_q : integer;
            lbl   : string
        ) is
        begin
            mod_order     <= ord;
            s_axis_tdata  <= bits;
            s_axis_tvalid <= '1';
            m_axis_tready <= '1';

            -- Wait for the DUT to accept the input (tready='1')
            loop
                wait until rising_edge(aclk);
                exit when s_axis_tready = '1';
            end loop;

            -- Deassert valid; output appears on the very next rising edge
            s_axis_tvalid <= '0';
            wait until rising_edge(aclk);

            got_i := to_integer(signed(m_axis_tdata(OUTPUT_WIDTH-1 downto 0)));
            got_q := to_integer(signed(m_axis_tdata(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH)));

            if m_axis_tvalid /= '1' then
                report "FAIL [" & lbl & "]: m_axis_tvalid not asserted"
                    severity error;
                fail_count := fail_count + 1;
            elsif got_i = exp_i and got_q = exp_q then
                report "PASS [" & lbl & "]  I=" & integer'image(got_i)
                                              & " Q=" & integer'image(got_q)
                    severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL [" & lbl & "]"
                    & "  got I=" & integer'image(got_i)
                    & " Q="     & integer'image(got_q)
                    & "  exp I=" & integer'image(exp_i)
                    & " Q="     & integer'image(exp_q)
                    severity error;
                fail_count := fail_count + 1;
            end if;
        end procedure send_check;

    begin

        -- -------------------------------------------------------------------
        -- Reset
        -- -------------------------------------------------------------------
        aresetn       <= '0';
        s_axis_tvalid <= '0';
        m_axis_tready <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(aclk);
        aresetn <= '1';
        wait until rising_edge(aclk);

        -- -------------------------------------------------------------------
        -- 1. BPSK  (mod_order = "00")
        -- -------------------------------------------------------------------
        report "--- BPSK ---" severity note;
        send_check("00", "000000",  1,  1, "BPSK b0=0");
        send_check("00", "000001", -1, -1, "BPSK b0=1");

        -- -------------------------------------------------------------------
        -- 2. QPSK  (mod_order = "01")
        --    I = ±1 from bit 0,  Q = ±1 from bit 1
        -- -------------------------------------------------------------------
        report "--- QPSK ---" severity note;
        send_check("01", "000000",  1,  1, "QPSK b1b0=00");
        send_check("01", "000001", -1,  1, "QPSK b1b0=01");
        send_check("01", "000010",  1, -1, "QPSK b1b0=10");
        send_check("01", "000011", -1, -1, "QPSK b1b0=11");

        -- -------------------------------------------------------------------
        -- 3. 16-QAM  (mod_order = "10")  – all 16 symbols
        --    I from {b2,b0},  Q from {b3,b1}
        -- -------------------------------------------------------------------
        report "--- 16-QAM ---" severity note;
        send_check("10", "000000",  1,  1, "16QAM b3b2b1b0=0000");
        send_check("10", "000001", -1,  1, "16QAM b3b2b1b0=0001");
        send_check("10", "000010",  1, -1, "16QAM b3b2b1b0=0010");
        send_check("10", "000011", -1, -1, "16QAM b3b2b1b0=0011");
        send_check("10", "000100",  3,  1, "16QAM b3b2b1b0=0100");
        send_check("10", "000101", -3,  1, "16QAM b3b2b1b0=0101");
        send_check("10", "000110",  3, -1, "16QAM b3b2b1b0=0110");
        send_check("10", "000111", -3, -1, "16QAM b3b2b1b0=0111");
        send_check("10", "001000",  1,  3, "16QAM b3b2b1b0=1000");
        send_check("10", "001001", -1,  3, "16QAM b3b2b1b0=1001");
        send_check("10", "001010",  1, -3, "16QAM b3b2b1b0=1010");
        send_check("10", "001011", -1, -3, "16QAM b3b2b1b0=1011");
        send_check("10", "001100",  3,  3, "16QAM b3b2b1b0=1100");
        send_check("10", "001101", -3,  3, "16QAM b3b2b1b0=1101");
        send_check("10", "001110",  3, -3, "16QAM b3b2b1b0=1110");
        send_check("10", "001111", -3, -3, "16QAM b3b2b1b0=1111");

        -- -------------------------------------------------------------------
        -- 4. 64-QAM  (mod_order = "11")  – all 64 symbols via reference model
        --    I from {b4,b2,b0},  Q from {b5,b3,b1}
        -- -------------------------------------------------------------------
        report "--- 64-QAM ---" severity note;
        for n in 0 to 63 loop
            test_bits := std_logic_vector(to_unsigned(n, 6));
            send_check(
                "11",
                test_bits,
                ref_lut_64qam(test_bits(4) & test_bits(2) & test_bits(0)),
                ref_lut_64qam(test_bits(5) & test_bits(3) & test_bits(1)),
                "64QAM n=" & integer'image(n)
            );
        end loop;

        -- -------------------------------------------------------------------
        -- 5. Backpressure test
        --    Load one symbol with m_axis_tready='0', check that tready de-
        --    asserts, then release and verify the output appears.
        -- -------------------------------------------------------------------
        report "--- Backpressure ---" severity note;

        m_axis_tready <= '0';                       -- stall downstream
        mod_order     <= "11";                      -- 64-QAM
        -- "110000": b5=1,b4=1 → I-idx={b4,b2,b0}="100"→+1; Q-idx={b5,b3,b1}="100"→+1
        s_axis_tdata  <= "110000";                  -- expect I=+1, Q=+1

        s_axis_tvalid <= '1';
        wait until rising_edge(aclk);               -- symbol accepted (slot was empty)
        s_axis_tvalid <= '0';

        wait until rising_edge(aclk);               -- one idle cycle
        if s_axis_tready /= '0' then
            report "FAIL [backpressure]: tready should be '0' when output stalls"
                severity error;
            fail_count := fail_count + 1;
        else
            report "PASS [backpressure]: tready correctly de-asserted" severity note;
            pass_count := pass_count + 1;
        end if;

        -- Release downstream
        m_axis_tready <= '1';
        wait until rising_edge(aclk);

        if m_axis_tvalid /= '1' then
            report "FAIL [backpressure]: expected m_axis_tvalid='1' after release"
                severity error;
            fail_count := fail_count + 1;
        else
            got_i := to_integer(signed(m_axis_tdata(OUTPUT_WIDTH-1 downto 0)));
            got_q := to_integer(signed(m_axis_tdata(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH)));
            if got_i = 1 and got_q = 1 then
                report "PASS [backpressure]: correct I=" & integer'image(got_i)
                    & " Q=" & integer'image(got_q)
                    severity note;
                pass_count := pass_count + 1;
            else
                report "FAIL [backpressure]: got I=" & integer'image(got_i)
                    & " Q=" & integer'image(got_q) & " exp I=1 Q=1"
                    severity error;
                fail_count := fail_count + 1;
            end if;
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
