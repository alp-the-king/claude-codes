library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity asd_filter is
  generic (
    G_INPUT_BW : integer range 8 to 25 := 12;
    G_COEFF_BW : integer range 8 to 25 := 18
  );
  port (
    clk    : in  std_logic;
    -- reset  : in  std_logic;
    enable : in  std_logic;
    data_i : in  std_logic_vector(G_INPUT_BW - 1 downto 0);
    data_o : out std_logic_vector(G_COEFF_BW + G_INPUT_BW - 1 downto 0)
  );
end entity asd_filter;

architecture behavioral of asd_filter is

  -- attribute use_dsp : string;
  -- attribute use_dsp of behavioral : architecture is "yes";

  constant C_FILTER_TAPS : integer := 32; -- add +1 if the number of coeefficients is an odd number
  constant C_HALF_TAPS   : integer := C_FILTER_TAPS / 2;
  constant C_PADD_WIDTH  : integer := G_INPUT_BW + 1;          -- extra bit guards pre-add overflow
  constant C_MAC_WIDTH   : integer := G_COEFF_BW + C_PADD_WIDTH;

  type t_input_array is array(0 to C_FILTER_TAPS - 1) of signed(G_INPUT_BW - 1 downto 0);
  type t_padd_array  is array(0 to C_HALF_TAPS - 1)   of signed(C_PADD_WIDTH - 1 downto 0);
  type t_mult_array  is array(0 to C_HALF_TAPS - 1)   of signed(C_MAC_WIDTH - 1 downto 0);
  type t_accum_array is array(0 to C_HALF_TAPS - 1)   of signed(C_MAC_WIDTH - 1 downto 0);

  signal areg_s : t_input_array;
  signal padd_s : t_padd_array;
  signal mreg_s : t_mult_array;
  signal preg_s : t_accum_array;

  -- Unique half of the symmetric RRC (roll-off 0.25) coefficients.
  -- Index 0-15 each represent a symmetric pair; index 16 is the center tap.
  -- Output should be scaled right by 15 bits (filter gain ~30000 LSB).
  type t_coefficients is array(0 to C_HALF_TAPS - 1) of integer;

  -- divide the middle coeeficient by two if the number of coefficients is an odd number
  constant C_BREG_S : t_coefficients :=
  (   -479,         0,       391,         0,
      -560,         0,       797,         0,
     -1151,         0,      1753,         0,
     -3087,         0,      9517, 15000 / 2
  );

begin

  -- Drop the pre-adder guard MSB; meaningful bits are [C_MAC_WIDTH-2 : 0]
  data_o <= std_logic_vector(preg_s(C_HALF_TAPS - 1)(G_COEFF_BW + G_INPUT_BW - 1 downto 0));

  pr_main : process (clk)

    variable coe_v : signed(G_COEFF_BW - 1 downto 0);

  begin

    if rising_edge(clk) then
      -- if reset = '1' then

        -- areg_s <= (others => (others => '0'));
        -- padd_s <= (others => (others => '0'));
        -- mreg_s <= (others => (others => '0'));
        -- preg_s <= (others => (others => '0'));

      -- els
      if enable = '1' then

        -- Stage 1: shift register (delay line)
        areg_s(0) <= signed(data_i);
        for i in 1 to C_FILTER_TAPS - 1 loop
          areg_s(i) <= areg_s(i - 1);
        end loop;

        -- Stage 2: pre-adder exploiting coefficient symmetry.
        -- Each pair (i, N-1-i) shares the same coefficient, so their inputs
        -- are summed here and multiplied once instead of twice.
        for i in 0 to C_HALF_TAPS - 1 loop
          padd_s(i) <= resize(areg_s(i*2+1), C_PADD_WIDTH)
                     + resize(areg_s(C_FILTER_TAPS - 1), C_PADD_WIDTH);
        end loop;
        -- -- Center tap has no symmetric partner; pass through with sign extension.
        -- padd_s(C_HALF_TAPS) <= resize(areg_s(C_HALF_TAPS*2), C_PADD_WIDTH);

        -- Stage 3: multiply. Zero-coefficient taps skip the multiplier and
        -- forward zero directly, allowing the synthesiser to remove the DSP.
        for i in 0 to C_HALF_TAPS - 1 loop
          coe_v := to_signed(C_BREG_S(i), G_COEFF_BW);
          if C_BREG_S(i) = 0 then
            mreg_s(i) <= (others => '0');
          else
            mreg_s(i) <= padd_s(i) * coe_v;
          end if;
        end loop;

        -- Stage 4: systolic accumulation from last unique tap toward tap 0.
        -- Each cycle the partial sum propagates one step; preg_s(0) is valid
        -- after C_HALF_TAPS-1 = 16 additional cycles.
        preg_s(0) <= mreg_s(0);
        for i in 1 to C_HALF_TAPS - 1 loop
          preg_s(i) <= mreg_s(i) + preg_s(i - 1);
        end loop;

      end if;
    end if;

  end process;

end architecture behavioral;
