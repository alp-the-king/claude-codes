# Channel Estimation Block — Requirements Specification

## 1. Purpose and Scope

This document specifies the requirements for a hardware channel estimation block
targeting a point-to-point single-antenna OFDM data link. The design draws the
pilot pattern and numerology from 5G NR (3GPP TS 38.211) but is not required to
be a standards-compliant NR receiver; the pilot sequence will be confirmed
separately by the system designer.

The block receives frequency-domain OFDM symbols from an upstream FFT, extracts
pilot subcarriers, computes per-subcarrier complex channel coefficients using a
Minimum Mean-Square Error (MMSE) estimator, and forwards those coefficients to a
downstream equaliser.

---

## 2. Definitions and Acronyms

| Term | Meaning |
|------|---------|
| SCS  | Subcarrier spacing |
| FFT  | Fast Fourier Transform |
| OFDM | Orthogonal Frequency Division Multiplexing |
| DMRS | Demodulation Reference Signal |
| LS   | Least-Squares (channel estimate) |
| MMSE | Minimum Mean-Square Error |
| RB   | Resource Block (12 subcarriers) |
| SC   | Subcarrier |
| BW   | Bandwidth |
| CP   | Cyclic Prefix |
| SNR  | Signal-to-Noise Ratio |

---

## 3. System Context

```
        ┌─────────┐   AXI4-S    ┌──────────────────┐   AXI4-S    ┌───────────────┐
 RF ──► │  FFT    │ ──────────► │  Channel Est.    │ ──────────► │  Equaliser    │
        │  Block  │  freq-domain│  Block (this doc)│  H[k] est. │               │
        └─────────┘  symbols    └──────────────────┘             └───────────────┘
```

The channel estimation block is a pure frequency-domain, per-slot processing
pipeline. It does not perform time-domain operations.

---

## 4. Radio and Numerology Parameters

### 4.1 Numerology

| Parameter               | Value           | Source             |
|-------------------------|-----------------|--------------------|
| Subcarrier spacing (μ=1)| 30 kHz          | 3GPP TS 38.211     |
| Useful symbol duration  | 33.33 μs        | 1 / 30 kHz         |
| Nominal sample rate     | 122.88 MHz      | NR FR1 standard    |
| FFT size                | 4096            | Fs / Δf            |
| Active subcarriers      | 3276            | 273 RBs × 12 SC/RB |
| Guard subcarriers       | 820 (total)     | FFT − active       |
| Symbols per slot        | 14 (normal CP)  | 3GPP TS 38.211     |
| Slot duration           | 0.5 ms          | 14 / 30 kHz / 14   |
| Slot rate               | 2000 slots / s  |                    |

### 4.2 CP lengths (at 122.88 MHz sample rate)

| Symbol within slot | CP samples |
|--------------------|------------|
| 0 (first)          | 352        |
| 1 – 13             | 288        |

---

## 5. Pilot Pattern Specification

Until the system-level pilot sequence is confirmed, the block shall implement the
following pattern, which is compatible with 5G NR DMRS Type 1 single-port (port
1000) for a single-layer allocation.

### 5.1 Time-domain pilot placement

- **One DMRS symbol per slot**, located at OFDM symbol index **2** (0-indexed
  within the slot). This index is configurable via a VHDL generic (see §10).

### 5.2 Frequency-domain pilot placement

Within the DMRS OFDM symbol, pilots occupy **every second active subcarrier
(comb-2)**:

```
Active subcarrier index k (0 … 3275):
  Pilot at k if k is even  →  k = 0, 2, 4, … , 3274
  Data  at k if k is odd   →  k = 1, 3, 5, … , 3275
```

Number of pilot subcarriers per DMRS symbol: **1638**

### 5.3 Pilot sequence

Pilot complex values are BPSK (real ±1, zero imaginary), generated from a
length-2047 Gold sequence (same generator polynomial as NR, 3GPP TS 38.211
§7.4.1.1.1). The Gold sequence seed is a VHDL generic (see §10).

Pilot values are **pre-computed offline and stored in a dual-port ROM** inside the
block; no run-time pilot generation is required.

---

## 6. Algorithm Specification

### 6.1 Step 1 — LS Estimation at pilot positions

For each pilot subcarrier index p (p = 0, 1, … , 1637, mapped to active SC 2p):

```
  Y[2p]  = received complex sample (input from FFT)
  X[2p]  = known pilot value ∈ {+1, −1}  (from ROM)

  Ĥ_LS[p] = Y[2p] × conj(X[2p])
           = Y[2p] × X[2p]          (since X is real BPSK)
           = ±Y[2p]
```

Because X is real ±1, the LS step is a **conditional sign flip** — no multiplier
required.

### 6.2 Step 2 — MMSE Smoothing Filter

A **pre-computed complex FIR filter** of length L (configurable generic, default
L = 33) is applied to the vector of LS estimates Ĥ_LS[0…1637].

The filter coefficients W[0…L−1] are derived offline from:

```
  W = R_hh × (R_hh + (σ_n² / σ_h²) × I)^{−1} × interpolation_matrix
```

where R_hh is the expected channel frequency-correlation matrix (modelled as
an exponential decay corresponding to a target maximum excess delay), σ_n² is
the design-point noise power, and σ_h² is the average channel power.

Coefficients are stored in a **dual-port ROM** and are loaded at elaboration
time; the block does not recompute them at run time.

The same set of coefficients addresses two polyphase branches:
- **Branch 0** — output estimate at pilot positions (even SCs)
- **Branch 1** — output estimate at data positions (odd SCs)

The output of the MMSE filter therefore has the same length as the full active
subcarrier vector (3276 samples).

### 6.3 Noise variance input

The block accepts a run-time estimate of σ_n² via an AXI4-Lite register
(see §7.3). When this register is not updated by the host, the block uses the
default value baked into the ROM coefficients.

> **Note:** Full run-time MMSE recomputation (i.e., updating coefficients based
> on live SNR) is **out of scope** for this implementation. The noise variance
> register scales the LS estimates before filtering to provide a first-order
> SNR-tracking correction only.

### 6.4 Channel estimate output

The block outputs one complex channel coefficient Ĥ[k] per active subcarrier
k ∈ [0, 3275], produced once per slot, timed to be available before the first
data OFDM symbol in that slot (symbol index 4 for the default DMRS position).

---

## 7. Interface Specification

### 7.1 AXI4-Stream Input — Frequency-Domain Samples

Carries the output of the upstream FFT, one active subcarrier per beat,
transmitted in order k = 0, 1, … , 3275 within each OFDM symbol.

| Signal      | Width | Direction | Description |
|-------------|-------|-----------|-------------|
| `s_axis_tdata`  | 32 b | Input  | {Q[15:0], I[15:0]} — signed 16-bit I and Q |
| `s_axis_tvalid` | 1    | Input  | Data beat valid |
| `s_axis_tready` | 1    | Output | Block can accept data |
| `s_axis_tlast`  | 1    | Input  | Last active subcarrier of symbol (k=3275) |
| `s_axis_tuser`  | 4    | Input  | OFDM symbol index within slot (0–13) |

### 7.2 AXI4-Stream Output — Channel Estimates

Carries one complex channel coefficient per active subcarrier per slot,
transmitted in order k = 0, 1, … , 3275.

| Signal      | Width | Direction | Description |
|-------------|-------|-----------|-------------|
| `m_axis_tdata`  | 32 b | Output | {H_Q[15:0], H_I[15:0]} — signed 16-bit |
| `m_axis_tvalid` | 1    | Output | Estimate beat valid |
| `m_axis_tready` | 1    | Input  | Downstream ready |
| `m_axis_tlast`  | 1    | Output | Last subcarrier (k=3275) |
| `m_axis_tuser`  | 1    | Output | 0 = interpolated (data SC), 1 = LS+MMSE (pilot SC) |

### 7.3 AXI4-Lite Control Interface

Base address offset 0x0000. All registers 32-bit wide.

| Offset | Name        | Access | Reset     | Description |
|--------|-------------|--------|-----------|-------------|
| 0x00   | CTRL        | RW     | 0x0000_0001 | Bit 0: global enable. Bit 1: flush pipeline. |
| 0x04   | NOISE_VAR   | RW     | 0x0000_0100 | Noise variance σ_n² in UQ8.8 unsigned fixed-point format. Default = 1.0 (0x0100). |
| 0x08   | STATUS      | RO     | —         | Bit 0: block ready. Bit 1: output FIFO overflow. |
| 0x0C   | SLOT_COUNT  | RO     | —         | Running count of processed slots (wraps at 2^32). |

### 7.4 Clock and Reset

| Signal  | Description |
|---------|-------------|
| `clk`   | Single synchronous clock. Positive edge. Target 122.88 MHz; must meet timing at 150 MHz. |
| `rst_n` | Active-low synchronous reset. |

---

## 8. Timing and Latency Requirements

| Requirement | Value | Rationale |
|-------------|-------|-----------|
| Input throughput | One 32-bit beat per clock cycle (back-to-back) | Matches FFT output rate |
| Processing latency | ≤ 2 OFDM symbols = ≤ 8768 clk cycles at 122.88 MHz | DMRS is symbol 2; data starts symbol 4 |
| Output valid time | Before symbol 4 of the same slot | Equaliser requires H[k] before data arrives |
| Clock frequency | ≥ 122.88 MHz (target 150 MHz for margin) | Nominal NR sample rate |
| Pipeline stall | `s_axis_tready` may be de-asserted for ≤ 4 cycles during coefficient ROM access | |

---

## 9. Fixed-Point Numerical Specification

| Data path stage        | Format       | Notes |
|------------------------|--------------|-------|
| FFT input samples      | S1.15 (sc16) | 16-bit signed I/Q, max value ±1.0 |
| Pilot ROM values       | S1.0 (1-bit) | Stored as 1-bit sign; unpacked to ±1 at run time |
| LS estimates Ĥ_LS      | S1.15        | Sign flip of input; no magnitude change |
| MMSE coefficient ROM   | S1.15        | Pre-scaled so sum of magnitudes ≤ 1.0 |
| FIR accumulator        | S17.15       | 32-bit signed to accommodate L=33 taps |
| Output channel est.    | S1.15 (sc16) | Rounded (round-to-nearest), saturated |

Overflow in the accumulator shall result in saturation, not wrap-around.

---

## 10. VHDL Generics (Configuration Parameters)

| Generic               | Type    | Default | Description |
|-----------------------|---------|---------|-------------|
| `G_N_ACTIVE_SC`       | integer | 3276    | Number of active subcarriers |
| `G_FFT_SIZE`          | integer | 4096    | FFT transform size |
| `G_DMRS_SYMBOL_IDX`   | integer | 2       | OFDM symbol index of DMRS within slot |
| `G_SYMBOLS_PER_SLOT`  | integer | 14      | Total OFDM symbols per slot |
| `G_PILOT_SPACING`     | integer | 2       | Subcarrier spacing between pilots (comb factor) |
| `G_FIR_LENGTH`        | integer | 33      | MMSE FIR filter length (must be odd) |
| `G_COEFF_ROM_FILE`    | string  | `"mmse_coefs.mif"` | Path to coefficient ROM initialisation file |
| `G_PILOT_ROM_FILE`    | string  | `"pilot_seq.mif"`  | Path to pilot sequence ROM initialisation file |
| `G_GOLD_SEED`         | integer | 0       | Gold sequence seed (used offline to generate pilot ROM) |
| `G_DATA_WIDTH`        | integer | 16      | I/Q sample bit width |
| `G_COEFF_WIDTH`       | integer | 16      | FIR coefficient bit width |

---

## 11. Sub-block Decomposition

The following sub-blocks are anticipated (refined during RTL design):

```
channel_est_top
├── pilot_extractor      — symbol index check + mux of pilot/data subcarriers
├── ls_estimator         — sign-flip division by pilot ROM values
├── mmse_fir             — complex polyphase FIR (2 phases: pilot SC, data SC)
│   ├── coeff_rom        — pre-computed MMSE coefficients (Xilinx BRAM)
│   └── complex_mac      — N parallel DSP48E2 multiply-accumulate cells
├── output_fifo          — small FWFT FIFO to decouple FIR output from downstream
└── axil_regs            — AXI4-Lite register bank
```

---

## 12. Implementation Constraints (Xilinx/AMD FPGA)

- Coefficient ROM and pilot ROM shall be implemented using **RAMB36E2** primitives
  (inferred via `read_memfile` / `$readmemb` attributes in VHDL-2008).
- MMSE FIR MAC units shall map to **DSP48E2** slices. A fully-pipelined
  implementation of L=33 taps at 122.88 MHz requires approximately 66 DSP48E2
  slices (2 per complex tap: real and imaginary parts).
- Target device family: **Xilinx UltraScale+** (specific part TBD).
- The block shall be synthesisable with **Vivado 2023.2** or later.
- Timing closure target: 150 MHz (6.67 ns period) with WNS ≥ 0.

---

## 13. Verification Requirements

| Test | Description |
|------|-------------|
| VR-01 | Static channel: H[k] = constant. Output shall match input within ±1 LSB. |
| VR-02 | AWGN noise floor: with 20 dB SNR and ETSI TDL-C 100 ns channel model, output MSE ≤ −15 dB. |
| VR-03 | Back-pressure: de-assert `m_axis_tready` mid-burst; verify no data is lost. |
| VR-04 | Reset: assert `rst_n` mid-slot; verify clean restart from next slot. |
| VR-05 | Overflow / saturation: inject maximum-magnitude input; verify no wrap-around on output. |
| VR-06 | NOISE_VAR register: vary σ_n² over range; verify output MSE degrades gracefully. |

---

## 14. Open Items

| ID | Item | Owner | Target |
|----|------|-------|--------|
| OI-01 | Confirm final pilot sequence (Gold seed or custom) | System designer | Before RTL start |
| OI-02 | Confirm target Xilinx part number | Hardware team | Before implementation |
| OI-03 | Provide target channel model for MMSE coefficient generation | DSP engineer | Before RTL start |
| OI-04 | Confirm whether NOISE_VAR must update per-slot or per-frame | System designer | Before RTL start |
| OI-05 | Confirm upstream FFT output format (SC order, guard handling) | FFT block owner | Before RTL start |

---

*Document version: 0.1 — Initial draft*
