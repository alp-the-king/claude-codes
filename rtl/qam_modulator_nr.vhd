-- qam_modulator_nr.vhd
-- 5G NR QAM Modulator -- TS 38.212 §5.1 (Modulation mapper)
--
-- Supported modulation orders
--   mod_order = "00"  BPSK   (Qm = 1)
--   mod_order = "01"  QPSK   (Qm = 2)
--   mod_order = "10"  16-QAM (Qm = 4)
--   mod_order = "11"  64-QAM (Qm = 6)
--
-- Input (AXI4-Stream slave, 6-bit data)
--   s_axis_tdata(5:0) -- raw codeword bits.  Bit 0 = b0 per TS 38.212.
--   Only the lower Qm bits are consumed; unused upper bits are ignored.
--     BPSK  : bit 0        QPSK  : bits 1:0
--     16-QAM: bits 3:0     64-QAM: bits 5:0
--
-- Output (AXI4-Stream master, 2*OUTPUT_WIDTH-bit data)
--   m_axis_tdata(OUTPUT_WIDTH-1          downto 0)            = I (signed)
--   m_axis_tdata(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH)        = Q (signed)
--
-- Fixed-point format: Q2.(OUTPUT_WIDTH-2)
--   1 sign bit + 1 integer bit + (OUTPUT_WIDTH-2) fractional bits
--   Real range [-2.0, 2.0) -- accommodates all modulation orders:
--     BPSK/QPSK  max amplitude 1/sqrt(2)  ~= 0.71
--     16-QAM     max amplitude 3/sqrt(10) ~= 0.95
--     64-QAM     max amplitude 7/sqrt(42) ~= 1.08
-- Normalization factors (TS 38.212 §5.1.3) are baked into the LUT entries
-- at elaboration time via ieee.math_real; no downstream scaling required.
--
-- Latency  : 1 clock cycle (registered output)
-- Throughput: 1 symbol/cycle when m_axis_tready is held high

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity qam_modulator_nr is
    generic (
        -- Bit width of each signed IQ component in m_axis_tdata.
        -- Output is in Q2.(OUTPUT_WIDTH-2) fixed-point; minimum useful value is 4.
        OUTPUT_WIDTH : positive := 16
    );
    port (
        aclk    : in  std_logic;
        aresetn : in  std_logic;        -- active-low synchronous reset

        -- Modulation order (may change every symbol)
        mod_order : in std_logic_vector(1 downto 0);

        -- AXI4-Stream slave -- input codeword bits
        s_axis_tdata  : in  std_logic_vector(5 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        -- AXI4-Stream master -- output IQ symbol {Q[OW-1:0], I[OW-1:0]}
        m_axis_tdata  : out std_logic_vector(2*OUTPUT_WIDTH-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity qam_modulator_nr;

architecture rtl of qam_modulator_nr is

    constant C_BPSK  : std_logic_vector(1 downto 0) := "00";
    constant C_QPSK  : std_logic_vector(1 downto 0) := "01";
    constant C_16QAM : std_logic_vector(1 downto 0) := "10";
    constant C_64QAM : std_logic_vector(1 downto 0) := "11";

    --------------------------------------------------------------------------
    -- TS 38.212 normalization factors (Section 5.1.3)
    --------------------------------------------------------------------------
    constant NORM_BPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_QPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_16QAM : real := 1.0 / sqrt(10.0);
    constant NORM_64QAM : real := 1.0 / sqrt(42.0);

    --------------------------------------------------------------------------
    -- Fixed-point conversion helper (elaboration-time only)
    --
    -- Converts a raw constellation integer and a TS 38.212 normalization
    -- factor to a Q2.(OUTPUT_WIDTH-2) signed value of OUTPUT_WIDTH bits:
    --   scale  = 2^(OUTPUT_WIDTH-2)
    --   result = round(raw * norm * scale)
    --------------------------------------------------------------------------
    function to_fp (raw : integer; norm : real) return signed is
        constant SCALE : real := 2.0 ** (OUTPUT_WIDTH - 2);
    begin
        return to_signed(integer(round(real(raw) * norm * SCALE)), OUTPUT_WIDTH);
    end function to_fp;

    --------------------------------------------------------------------------
    -- 64-QAM LUT (TS 38.212 Table 5.1.3.3-1)
    -- idx(2)=b4/b5  idx(1)=b2/b3  idx(0)=b0/b1
    -- Raw: (1-2*b0)[4-(1-2*b2)(2-(1-2*b4))] -> +/-{1,3,5,7}
    --------------------------------------------------------------------------
    function lut_64qam (idx : std_logic_vector(2 downto 0)) return signed is
    begin
        case idx is
            when "000"  => return to_fp( 3, NORM_64QAM);
            when "001"  => return to_fp(-3, NORM_64QAM);
            when "010"  => return to_fp( 5, NORM_64QAM);
            when "011"  => return to_fp(-5, NORM_64QAM);
            when "100"  => return to_fp( 1, NORM_64QAM);
            when "101"  => return to_fp(-1, NORM_64QAM);
            when "110"  => return to_fp( 7, NORM_64QAM);
            when "111"  => return to_fp(-7, NORM_64QAM);
            when others => return to_fp( 0, NORM_64QAM);
        end case;
    end function lut_64qam;

    --------------------------------------------------------------------------
    -- 16-QAM LUT (TS 38.212 Table 5.1.3.2-1)
    -- idx(1)=b2/b3  idx(0)=b0/b1
    -- Raw: (1-2*b0)[2-(1-2*b2)] -> +/-{1,3}
    --------------------------------------------------------------------------
    function lut_16qam (idx : std_logic_vector(1 downto 0)) return signed is
    begin
        case idx is
            when "00"   => return to_fp( 1, NORM_16QAM);
            when "01"   => return to_fp(-1, NORM_16QAM);
            when "10"   => return to_fp( 3, NORM_16QAM);
            when "11"   => return to_fp(-3, NORM_16QAM);
            when others => return to_fp( 0, NORM_16QAM);
        end case;
    end function lut_16qam;

    --------------------------------------------------------------------------
    -- Internal signals
    --------------------------------------------------------------------------
    signal i_map       : signed(OUTPUT_WIDTH-1 downto 0);
    signal q_map       : signed(OUTPUT_WIDTH-1 downto 0);
    signal out_data_r  : std_logic_vector(2*OUTPUT_WIDTH-1 downto 0);
    signal out_valid_r : std_logic;
    signal out_last_r  : std_logic;
    signal s_ready_i   : std_logic;

begin

    assert OUTPUT_WIDTH >= 4
        report "qam_modulator_nr: OUTPUT_WIDTH must be >= 4 for meaningful fixed-point precision"
        severity failure;

    --------------------------------------------------------------------------
    -- Combinational symbol mapper
    --------------------------------------------------------------------------
    p_map : process (mod_order, s_axis_tdata)
    begin
        i_map <= to_fp(0, NORM_64QAM);
        q_map <= to_fp(0, NORM_64QAM);

        case mod_order is

            when C_BPSK =>
                -- d(i) = (1/sqrt(2))(1-2*b0)(1+j)  ->  I = Q = +/-1/sqrt(2)
                if s_axis_tdata(0) = '1' then
                    i_map <= to_fp(-1, NORM_BPSK);
                    q_map <= to_fp(-1, NORM_BPSK);
                else
                    i_map <= to_fp( 1, NORM_BPSK);
                    q_map <= to_fp( 1, NORM_BPSK);
                end if;

            when C_QPSK =>
                -- I = (1-2*b0)/sqrt(2),  Q = (1-2*b1)/sqrt(2)
                if s_axis_tdata(0) = '1' then
                    i_map <= to_fp(-1, NORM_QPSK);
                else
                    i_map <= to_fp( 1, NORM_QPSK);
                end if;
                if s_axis_tdata(1) = '1' then
                    q_map <= to_fp(-1, NORM_QPSK);
                else
                    q_map <= to_fp( 1, NORM_QPSK);
                end if;

            when C_16QAM =>
                i_map <= lut_16qam(s_axis_tdata(2) & s_axis_tdata(0));
                q_map <= lut_16qam(s_axis_tdata(3) & s_axis_tdata(1));

            when C_64QAM =>
                i_map <= lut_64qam(s_axis_tdata(4) & s_axis_tdata(2) & s_axis_tdata(0));
                q_map <= lut_64qam(s_axis_tdata(5) & s_axis_tdata(3) & s_axis_tdata(1));

            when others =>
                null;

        end case;
    end process p_map;

    --------------------------------------------------------------------------
    -- Registered output stage -- AXI4-S skid buffer (1 deep)
    --
    -- Accept new input when:
    --   (a) output slot is empty  (!out_valid_r), or
    --   (b) downstream consumes the output this cycle (m_axis_tready)
    --------------------------------------------------------------------------
    s_ready_i     <= (not out_valid_r) or m_axis_tready;
    s_axis_tready <= s_ready_i;

    p_reg : process (aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                out_valid_r <= '0';
                out_data_r  <= (others => '0');
                out_last_r  <= '0';
            else
                if s_axis_tvalid = '1' and s_ready_i = '1' then
                    -- New symbol: register the pre-normalized fixed-point IQ values
                    out_valid_r <= '1';
                    out_last_r  <= s_axis_tlast;
                    out_data_r(OUTPUT_WIDTH-1 downto 0)              <= std_logic_vector(i_map);
                    out_data_r(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH) <= std_logic_vector(q_map);
                elsif m_axis_tready = '1' then
                    -- Output consumed, no new input arriving
                    out_valid_r <= '0';
                end if;
            end if;
        end if;
    end process p_reg;

    m_axis_tdata  <= out_data_r;
    m_axis_tvalid <= out_valid_r;
    m_axis_tlast  <= out_last_r;

end architecture rtl;
