-- llr_demapper_nr.vhd
-- 5G NR Soft LLR Demapper - TS 38.212 Section 5.1
--
-- Computes bit-level LLRs using the Max-Log-MAP approximation:
--   LLR(b_k) = min_{s in S1_k} |r-s|^2 - min_{s in S0_k} |r-s|^2
-- where S0_k / S1_k are the constellation subsets with b_k=0 / b_k=1.
--
-- All Qm LLRs are computed in parallel in a single combinational stage,
-- then registered before output.
--
-- Input constellation points must use the same Q2.(IQ_WIDTH-2) fixed-point
-- format as qam_modulator_nr (i.e. produced by that block).
--
-- mod_order encoding  (same as qam_modulator_nr)
--   "00" = BPSK   -> 1 LLR   "01" = QPSK   -> 2 LLRs
--   "10" = 16-QAM -> 4 LLRs  "11" = 64-QAM -> 6 LLRs
--
-- Output: m_axis_tdata packed as {llr[Qm-1], ..., llr[0]}, each LLR_WIDTH bits
--   llr[0]  = b0 (I MSB in the TS 38.212 Gray mapping)
--   llr[1]  = b1 (Q MSB), llr[2] = b2 (I 2nd bit), ...
--
-- LLR sign convention: positive -> bit more likely 0, negative -> bit more likely 1
--
-- Latency: 1 cycle.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity llr_demapper_nr is
    generic (
        -- Bit width of each received I or Q sample (signed, same format as
        -- qam_modulator_nr output: Q2.(IQ_WIDTH-2)).
        IQ_WIDTH  : positive := 16;
        -- Bit width of each output LLR (signed, 8-bit per spec request).
        LLR_WIDTH : positive := 8
    );
    port (
        aclk    : in  std_logic;
        aresetn : in  std_logic;

        -- Modulation order (same encoding as qam_modulator_nr)
        mod_order : in std_logic_vector(1 downto 0);

        -- AXI4-Stream slave: received IQ sample {Q[IW-1:0], I[IW-1:0]}
        s_axis_tdata  : in  std_logic_vector(2*IQ_WIDTH-1 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;

        -- AXI4-Stream master: packed LLRs, 6*LLR_WIDTH bits wide
        -- Bits [LLR_WIDTH-1:0]           = LLR(b0)
        -- Bits [2*LLR_WIDTH-1:LLR_WIDTH] = LLR(b1)  ... up to LLR(b5)
        -- For modulation orders < 64-QAM the upper LLR fields are zero.
        m_axis_tdata  : out std_logic_vector(6*LLR_WIDTH-1 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity llr_demapper_nr;

architecture rtl of llr_demapper_nr is

    -- -----------------------------------------------------------------------
    -- Elaboration-time: build normalized constellation points
    -- These must match qam_modulator_nr's to_fp formula exactly.
    -- -----------------------------------------------------------------------
    constant NORM_BPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_QPSK  : real := 1.0 / sqrt(2.0);
    constant NORM_16QAM : real := 1.0 / sqrt(10.0);
    constant NORM_64QAM : real := 1.0 / sqrt(42.0);

    function to_fp (raw : integer; norm : real) return signed is
        constant SCALE : real := 2.0 ** (IQ_WIDTH - 2);
    begin
        return to_signed(integer(round(real(raw) * norm * SCALE)), IQ_WIDTH);
    end function to_fp;

    -- -----------------------------------------------------------------------
    -- Constellation point arrays (one component, evaluated at elaboration)
    -- BPSK/QPSK: {-1, +1} * norm
    -- 16-QAM:    {-3,-1,+1,+3} * norm   (all 4 I values = all 4 Q values)
    -- 64-QAM:    {-7,-5,-3,-1,+1,+3,+5,+7} * norm
    -- -----------------------------------------------------------------------
    type t_pts2  is array (0 to 1)  of signed(IQ_WIDTH-1 downto 0);
    type t_pts4  is array (0 to 3)  of signed(IQ_WIDTH-1 downto 0);
    type t_pts8  is array (0 to 7)  of signed(IQ_WIDTH-1 downto 0);

    constant PTS_BPSK : t_pts2 := (
        to_fp(-1, NORM_BPSK),
        to_fp( 1, NORM_BPSK)
    );

    constant PTS_QPSK : t_pts2 := (
        to_fp(-1, NORM_QPSK),
        to_fp( 1, NORM_QPSK)
    );

    -- 16-QAM I/Q values in ascending order: -3,-1,+1,+3
    constant PTS_16QAM : t_pts4 := (
        to_fp(-3, NORM_16QAM),
        to_fp(-1, NORM_16QAM),
        to_fp( 1, NORM_16QAM),
        to_fp( 3, NORM_16QAM)
    );

    -- 64-QAM I/Q values in ascending order: -7,-5,-3,-1,+1,+3,+5,+7
    constant PTS_64QAM : t_pts8 := (
        to_fp(-7, NORM_64QAM),
        to_fp(-5, NORM_64QAM),
        to_fp(-3, NORM_64QAM),
        to_fp(-1, NORM_64QAM),
        to_fp( 1, NORM_64QAM),
        to_fp( 3, NORM_64QAM),
        to_fp( 5, NORM_64QAM),
        to_fp( 7, NORM_64QAM)
    );

    -- -----------------------------------------------------------------------
    -- Helper: squared distance (truncated to avoid overflow in wide arithmetic)
    -- Uses a wider internal type; result is unsigned.
    -- -----------------------------------------------------------------------
    function sq_dist (r, s : signed(IQ_WIDTH-1 downto 0)) return unsigned is
        variable d  : signed(IQ_WIDTH downto 0);
        variable d2 : signed(2*(IQ_WIDTH+1)-1 downto 0);
    begin
        d  := resize(r, IQ_WIDTH+1) - resize(s, IQ_WIDTH+1);
        d2 := d * d;
        return unsigned(d2);
    end function sq_dist;

    -- -----------------------------------------------------------------------
    -- LLR computation helpers
    -- max-log approximation: LLR = min_d2_S1 - min_d2_S0
    -- (positive LLR = bit more likely 0)
    -- -----------------------------------------------------------------------

    -- Minimum of two unsigned values
    function umin (a, b : unsigned) return unsigned is
    begin
        if a < b then return a; else return b; end if;
    end function umin;

    -- Saturating signed conversion for LLR output
    function sat_llr (val : signed) return signed is
        constant MAX_P : signed(LLR_WIDTH-1 downto 0) := to_signed( 2**(LLR_WIDTH-1)-1, LLR_WIDTH);
        constant MAX_N : signed(LLR_WIDTH-1 downto 0) := to_signed(-2**(LLR_WIDTH-1),   LLR_WIDTH);
        variable v     : signed(LLR_WIDTH-1 downto 0);
    begin
        if val > MAX_P then
            v := MAX_P;
        elsif val < MAX_N then
            v := MAX_N;
        else
            v := val(LLR_WIDTH-1 downto 0);
        end if;
        return v;
    end function sat_llr;

    -- -----------------------------------------------------------------------
    -- Per-modulation LLR functions
    -- Each returns a signed value in a wide internal word; caller saturates.
    -- D2_W = 2*(IQ_WIDTH+1) bits for the squared-distance accumulation.
    -- -----------------------------------------------------------------------
    constant D2_W : natural := 2*(IQ_WIDTH+1);

    -- BPSK: 1 bit maps to I (=Q), so we use the I component.
    -- b0=0 -> s=+1/sqrt(2), b0=1 -> s=-1/sqrt(2)
    function llr_bpsk (ri : signed(IQ_WIDTH-1 downto 0)) return signed is
        variable d0, d1 : unsigned(D2_W-1 downto 0);
        variable diff   : signed(D2_W downto 0);
    begin
        d0 := sq_dist(ri, PTS_BPSK(1));   -- b0=0 -> +1
        d1 := sq_dist(ri, PTS_BPSK(0));   -- b0=1 -> -1
        diff := signed('0' & d1) - signed('0' & d0);
        return diff;
    end function llr_bpsk;

    -- QPSK: b0 -> I, b1 -> Q.  Each component has 2 points.
    -- b=0 -> +1/sqrt(2), b=1 -> -1/sqrt(2)
    function llr_qpsk (r : signed(IQ_WIDTH-1 downto 0)) return signed is
        variable d0, d1 : unsigned(D2_W-1 downto 0);
        variable diff   : signed(D2_W downto 0);
    begin
        d0 := sq_dist(r, PTS_QPSK(1));    -- b=0 -> +1
        d1 := sq_dist(r, PTS_QPSK(0));    -- b=1 -> -1
        diff := signed('0' & d1) - signed('0' & d0);
        return diff;
    end function llr_qpsk;

    -- 16-QAM one-component LLR for a given bit position within I or Q.
    --
    -- Gray mapping for I (same structure applies to Q):
    --   b_sign (b0 or b1): 0->positive half {+1,+3}, 1->negative half {-1,-3}
    --   b_mag  (b2 or b3): 0->outer  {+3,-3},         1->inner  {+1,-1}
    --
    -- LLR(b_sign): min_d2({-3,-1}) - min_d2({+1,+3})   [sign bit: 0->right half]
    -- LLR(b_mag):  min_d2({+3,-3}) - min_d2({+1,-1})   [mag  bit: 0->outer]
    --
    -- idx 0=b_sign, 1=b_mag
    function llr_16qam (r : signed(IQ_WIDTH-1 downto 0); bit_idx : natural) return signed is
        variable d0a, d0b, d1a, d1b : unsigned(D2_W-1 downto 0);
        variable min0, min1         : unsigned(D2_W-1 downto 0);
        variable diff               : signed(D2_W downto 0);
    begin
        if bit_idx = 0 then
            -- b_sign: S0={+1,+3}(idx 2,3), S1={-3,-1}(idx 0,1)
            d0a := sq_dist(r, PTS_16QAM(2)); d0b := sq_dist(r, PTS_16QAM(3));
            d1a := sq_dist(r, PTS_16QAM(0)); d1b := sq_dist(r, PTS_16QAM(1));
        else
            -- b_mag: S0={-3,+3}(idx 0,3), S1={-1,+1}(idx 1,2)
            d0a := sq_dist(r, PTS_16QAM(0)); d0b := sq_dist(r, PTS_16QAM(3));
            d1a := sq_dist(r, PTS_16QAM(1)); d1b := sq_dist(r, PTS_16QAM(2));
        end if;
        min0 := umin(d0a, d0b);
        min1 := umin(d1a, d1b);
        diff := signed('0' & min1) - signed('0' & min0);
        return diff;
    end function llr_16qam;

    -- 64-QAM one-component LLR for bit positions 0,1,2 within I or Q.
    --
    -- 8-point Gray mapping (ascending order: -7,-5,-3,-1,+1,+3,+5,+7)
    -- Mapping from TS 38.212 table 5.1.3.3-1 (I-component bits b0,b2,b4):
    --   idx in PTS_64QAM: 0=-7 1=-5 2=-3 3=-1 4=+1 5=+3 6=+5 7=+7
    --   b_sign (bit 0): 0->{+1,+3,+5,+7}(idx 4-7), 1->{-7,-5,-3,-1}(idx 0-3)
    --   b_mid  (bit 1): 0->{-7,-5,+5,+7}(idx 0,1,6,7), 1->{-3,-1,+1,+3}(idx 2-5)
    --   b_fine (bit 2): 0->{-7,-3,+3,+7}(idx 0,2,5,7), 1->{-5,-1,+1,+5}(idx 1,3,4,6)
    --
    function llr_64qam (r : signed(IQ_WIDTH-1 downto 0); bit_idx : natural) return signed is
        type t_d8 is array (0 to 7) of unsigned(D2_W-1 downto 0);
        variable d : t_d8;
        variable min0, min1 : unsigned(D2_W-1 downto 0);
        variable diff       : signed(D2_W downto 0);
    begin
        -- pre-compute all 8 distances (synthesis unrolls this)
        d(0) := sq_dist(r, PTS_64QAM(0));
        d(1) := sq_dist(r, PTS_64QAM(1));
        d(2) := sq_dist(r, PTS_64QAM(2));
        d(3) := sq_dist(r, PTS_64QAM(3));
        d(4) := sq_dist(r, PTS_64QAM(4));
        d(5) := sq_dist(r, PTS_64QAM(5));
        d(6) := sq_dist(r, PTS_64QAM(6));
        d(7) := sq_dist(r, PTS_64QAM(7));
        case bit_idx is
            when 0 =>  -- b_sign: S0=idx{4,5,6,7}, S1=idx{0,1,2,3}
                min0 := umin(umin(d(4),d(5)), umin(d(6),d(7)));
                min1 := umin(umin(d(0),d(1)), umin(d(2),d(3)));
            when 1 =>  -- b_mid: S0=idx{0,1,6,7}, S1=idx{2,3,4,5}
                min0 := umin(umin(d(0),d(1)), umin(d(6),d(7)));
                min1 := umin(umin(d(2),d(3)), umin(d(4),d(5)));
            when others =>  -- b_fine: S0=idx{0,2,5,7}, S1=idx{1,3,4,6}
                min0 := umin(umin(d(0),d(2)), umin(d(5),d(7)));
                min1 := umin(umin(d(1),d(3)), umin(d(4),d(6)));
        end case;
        diff := signed('0' & min1) - signed('0' & min0);
        return diff;
    end function llr_64qam;

    -- -----------------------------------------------------------------------
    -- Internal signals
    -- -----------------------------------------------------------------------
    signal ri          : signed(IQ_WIDTH-1 downto 0);
    signal rq          : signed(IQ_WIDTH-1 downto 0);

    -- 6 raw LLR words (wide, before saturation)
    constant LLR_RAW_W : natural := D2_W + 1;
    type t_llr_raw is array (0 to 5) of signed(LLR_RAW_W-1 downto 0);
    signal llr_raw     : t_llr_raw;

    signal out_data_r  : std_logic_vector(6*LLR_WIDTH-1 downto 0);
    signal out_valid_r : std_logic;
    signal out_last_r  : std_logic;
    signal s_ready_i   : std_logic;

begin

    assert IQ_WIDTH >= 4
        report "llr_demapper_nr: IQ_WIDTH must be >= 4"
        severity failure;

    ri <= signed(s_axis_tdata(IQ_WIDTH-1 downto 0));
    rq <= signed(s_axis_tdata(2*IQ_WIDTH-1 downto IQ_WIDTH));

    -- -----------------------------------------------------------------------
    -- Parallel combinational LLR computation
    -- -----------------------------------------------------------------------
    p_llr : process (mod_order, ri, rq)
        variable llr_b0, llr_b1, llr_b2, llr_b3, llr_b4, llr_b5 : signed(LLR_RAW_W-1 downto 0);
    begin
        llr_b0 := (others => '0'); llr_b1 := (others => '0');
        llr_b2 := (others => '0'); llr_b3 := (others => '0');
        llr_b4 := (others => '0'); llr_b5 := (others => '0');

        case mod_order is
            when "00" =>  -- BPSK: 1 LLR, I component carries the single bit
                llr_b0 := resize(llr_bpsk(ri), LLR_RAW_W);

            when "01" =>  -- QPSK: 2 LLRs, b0->I, b1->Q
                llr_b0 := resize(llr_qpsk(ri), LLR_RAW_W);
                llr_b1 := resize(llr_qpsk(rq), LLR_RAW_W);

            when "10" =>  -- 16-QAM: 4 LLRs
                -- b0=sign(I), b1=sign(Q), b2=mag(I), b3=mag(Q)
                llr_b0 := resize(llr_16qam(ri, 0), LLR_RAW_W);
                llr_b1 := resize(llr_16qam(rq, 0), LLR_RAW_W);
                llr_b2 := resize(llr_16qam(ri, 1), LLR_RAW_W);
                llr_b3 := resize(llr_16qam(rq, 1), LLR_RAW_W);

            when others =>  -- 64-QAM: 6 LLRs
                -- b0=sign(I), b1=sign(Q), b2=mid(I), b3=mid(Q), b4=fine(I), b5=fine(Q)
                llr_b0 := resize(llr_64qam(ri, 0), LLR_RAW_W);
                llr_b1 := resize(llr_64qam(rq, 0), LLR_RAW_W);
                llr_b2 := resize(llr_64qam(ri, 1), LLR_RAW_W);
                llr_b3 := resize(llr_64qam(rq, 1), LLR_RAW_W);
                llr_b4 := resize(llr_64qam(ri, 2), LLR_RAW_W);
                llr_b5 := resize(llr_64qam(rq, 2), LLR_RAW_W);
        end case;

        llr_raw(0) <= llr_b0; llr_raw(1) <= llr_b1;
        llr_raw(2) <= llr_b2; llr_raw(3) <= llr_b3;
        llr_raw(4) <= llr_b4; llr_raw(5) <= llr_b5;
    end process p_llr;

    -- -----------------------------------------------------------------------
    -- AXI4-S registered output with saturation to LLR_WIDTH bits
    -- -----------------------------------------------------------------------
    s_ready_i     <= (not out_valid_r) or m_axis_tready;
    s_axis_tready <= s_ready_i;

    p_reg : process (aclk)
        variable scaled : signed(LLR_RAW_W-1 downto 0);
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                out_valid_r <= '0';
                out_data_r  <= (others => '0');
                out_last_r  <= '0';
            else
                if s_axis_tvalid = '1' and s_ready_i = '1' then
                    out_valid_r <= '1';
                    out_last_r  <= s_axis_tlast;
                    for k in 0 to 5 loop
                        out_data_r((k+1)*LLR_WIDTH-1 downto k*LLR_WIDTH) <=
                            std_logic_vector(sat_llr(llr_raw(k)));
                    end loop;
                elsif m_axis_tready = '1' then
                    out_valid_r <= '0';
                end if;
            end if;
        end if;
    end process p_reg;

    m_axis_tdata  <= out_data_r;
    m_axis_tvalid <= out_valid_r;
    m_axis_tlast  <= out_last_r;

end architecture rtl;
