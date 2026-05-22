-- qam_modulator_nr.vhd
-- 5G NR QAM Modulator – TS 38.212 §5.1 (Modulation mapper)
--
-- Supported modulation orders
--   mod_order = "00"  BPSK   (Qm = 1)
--   mod_order = "01"  QPSK   (Qm = 2)
--   mod_order = "10"  16-QAM (Qm = 4)
--   mod_order = "11"  64-QAM (Qm = 6)
--
-- Input (AXI4-Stream slave, 6-bit data)
--   s_axis_tdata(5:0) – raw codeword bits.  Bit 0 = b₀ per TS 38.212.
--   Only the lower Qm bits are consumed; unused upper bits are ignored.
--     BPSK  : bit 0        QPSK  : bits 1:0
--     16-QAM: bits 3:0     64-QAM: bits 5:0
--
-- Output (AXI4-Stream master, 2·OUTPUT_WIDTH-bit data)
--   m_axis_tdata(OUTPUT_WIDTH-1          downto 0)            = I (signed)
--   m_axis_tdata(2·OUTPUT_WIDTH-1 downto OUTPUT_WIDTH)        = Q (signed)
--   Values are unscaled integers.  Apply the normalization factor downstream:
--     BPSK / QPSK  1/√2,  16-QAM  1/√10,  64-QAM  1/√42
--
-- Latency  : 1 clock cycle (registered output)
-- Throughput: 1 symbol/cycle when m_axis_tready is held high

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity qam_modulator_nr is
    generic (
        -- Bit width of each signed IQ component in m_axis_tdata.
        -- Minimum 4: 64-QAM needs ±7 which requires a 4-bit signed field.
        OUTPUT_WIDTH : positive := 8
    );
    port (
        aclk    : in  std_logic;
        aresetn : in  std_logic;        -- active-low synchronous reset

        -- Modulation order (may change every symbol)
        mod_order : in std_logic_vector(1 downto 0);

        -- AXI4-Stream slave – input codeword bits
        s_axis_tdata  : in  std_logic_vector(5 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        -- AXI4-Stream master – output IQ symbol  {Q, I}
        m_axis_tdata  : out std_logic_vector(2*OUTPUT_WIDTH-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity qam_modulator_nr;

architecture rtl of qam_modulator_nr is

    ----------------------------------------------------------------------------
    -- Modulation-order constants
    ----------------------------------------------------------------------------
    constant C_BPSK  : std_logic_vector(1 downto 0) := "00";
    constant C_QPSK  : std_logic_vector(1 downto 0) := "01";
    constant C_16QAM : std_logic_vector(1 downto 0) := "10";
    constant C_64QAM : std_logic_vector(1 downto 0) := "11";

    ----------------------------------------------------------------------------
    -- Constellation LUT functions
    ----------------------------------------------------------------------------

    -- 64-QAM (TS 38.212 Table 5.1.3.3-1)
    -- idx(2) = b₄/b₅,  idx(1) = b₂/b₃,  idx(0) = b₀/b₁
    -- Formula: (1-2·b₀) · [4 - (1-2·b₂)·(2-(1-2·b₄))]  → ±{1,3,5,7}
    -- Normalization: 1/√42  (applied externally)
    function lut_64qam (idx : std_logic_vector(2 downto 0)) return signed is
    begin
        case idx is
            when "000"  => return to_signed( 3, 4);
            when "001"  => return to_signed(-3, 4);
            when "010"  => return to_signed( 5, 4);
            when "011"  => return to_signed(-5, 4);
            when "100"  => return to_signed( 1, 4);
            when "101"  => return to_signed(-1, 4);
            when "110"  => return to_signed( 7, 4);
            when "111"  => return to_signed(-7, 4);
            when others => return to_signed( 0, 4);
        end case;
    end function lut_64qam;

    -- 16-QAM (TS 38.212 Table 5.1.3.2-1)
    -- idx(1) = b₂/b₃,  idx(0) = b₀/b₁
    -- Formula: (1-2·b₀) · [2 - (1-2·b₂)]  → ±{1,3}
    -- Normalization: 1/√10  (applied externally)
    function lut_16qam (idx : std_logic_vector(1 downto 0)) return signed is
    begin
        case idx is
            when "00"   => return to_signed( 1, 4);
            when "01"   => return to_signed(-1, 4);
            when "10"   => return to_signed( 3, 4);
            when "11"   => return to_signed(-3, 4);
            when others => return to_signed( 0, 4);
        end case;
    end function lut_16qam;

    ----------------------------------------------------------------------------
    -- Internal signals
    ----------------------------------------------------------------------------
    signal i_raw        : signed(3 downto 0);   -- combinational mapped I
    signal q_raw        : signed(3 downto 0);   -- combinational mapped Q

    signal out_data_r   : std_logic_vector(2*OUTPUT_WIDTH-1 downto 0);
    signal out_valid_r  : std_logic;
    signal out_last_r   : std_logic;
    signal s_ready_i    : std_logic;            -- combinational ready

begin

    -- Compile-time guard
    assert OUTPUT_WIDTH >= 4
        report "qam_modulator_nr: OUTPUT_WIDTH must be >= 4 (64-QAM needs ±7)"
        severity failure;

    ----------------------------------------------------------------------------
    -- Combinational symbol mapper
    ----------------------------------------------------------------------------
    p_map : process (mod_order, s_axis_tdata)
    begin
        i_raw <= to_signed(0, 4);
        q_raw <= to_signed(0, 4);

        case mod_order is

            when C_BPSK =>
                -- d(i) = (1/√2)(1−2b₀)(1+j)  →  I = Q = ±1
                if s_axis_tdata(0) = '1' then
                    i_raw <= to_signed(-1, 4);
                    q_raw <= to_signed(-1, 4);
                else
                    i_raw <= to_signed(1, 4);
                    q_raw <= to_signed(1, 4);
                end if;

            when C_QPSK =>
                -- I = (1−2b₀)/√2,  Q = (1−2b₁)/√2  →  ±1
                if s_axis_tdata(0) = '1' then
                    i_raw <= to_signed(-1, 4);
                else
                    i_raw <= to_signed(1, 4);
                end if;
                if s_axis_tdata(1) = '1' then
                    q_raw <= to_signed(-1, 4);
                else
                    q_raw <= to_signed(1, 4);
                end if;

            when C_16QAM =>
                i_raw <= lut_16qam(s_axis_tdata(2) & s_axis_tdata(0));
                q_raw <= lut_16qam(s_axis_tdata(3) & s_axis_tdata(1));

            when C_64QAM =>
                i_raw <= lut_64qam(s_axis_tdata(4) & s_axis_tdata(2) & s_axis_tdata(0));
                q_raw <= lut_64qam(s_axis_tdata(5) & s_axis_tdata(3) & s_axis_tdata(1));

            when others =>
                null;

        end case;
    end process p_map;

    ----------------------------------------------------------------------------
    -- Registered output stage – AXI4-S skid buffer (1 deep)
    --
    -- Accept new input when:
    --   (a) output slot is empty  (!out_valid_r), or
    --   (b) downstream consumes the output this cycle (m_axis_tready)
    ----------------------------------------------------------------------------
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
                    -- New symbol accepted: map and register
                    out_valid_r <= '1';
                    out_last_r  <= s_axis_tlast;
                    out_data_r(OUTPUT_WIDTH-1 downto 0) <=
                        std_logic_vector(resize(i_raw, OUTPUT_WIDTH));
                    out_data_r(2*OUTPUT_WIDTH-1 downto OUTPUT_WIDTH) <=
                        std_logic_vector(resize(q_raw, OUTPUT_WIDTH));
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
