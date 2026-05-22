# Makefile for HDL modules (VHDL, GHDL)
# Requires: GHDL  https://github.com/ghdl/ghdl
# Optional: GTKWave for waveform viewing

RTL_DIR  := rtl
SIM_DIR  := sim
WORK_DIR := $(SIM_DIR)/work
GHDL     := ghdl
STD      := --std=08

# ---------------------------------------------------------------------------
# UART with programmable baud rate
# ---------------------------------------------------------------------------
UART_SRCS := $(RTL_DIR)/uart_baud_gen.vhd \
             $(RTL_DIR)/uart_tx.vhd        \
             $(RTL_DIR)/uart_rx.vhd        \
             $(RTL_DIR)/uart.vhd
UART_TB   := $(SIM_DIR)/uart_tb.vhd
UART_VCD  := $(SIM_DIR)/uart_tb.vcd

# ---------------------------------------------------------------------------
# 5G NR QAM Modulator (TS 38.212)
# ---------------------------------------------------------------------------
QAM_SRCS  := $(RTL_DIR)/qam_modulator_nr.vhd
QAM_TB    := $(SIM_DIR)/qam_modulator_nr_tb.vhd
QAM_VCD   := $(SIM_DIR)/qam_modulator_nr_tb.vcd

.PHONY: all sim sim-uart sim-qam vcd-qam vcd-uart wave wave-uart wave-qam clean

all: sim-uart sim-qam

sim: sim-uart sim-qam

## Simulate UART
sim-uart: $(UART_SRCS) $(UART_TB)
	@mkdir -p $(WORK_DIR)
	$(GHDL) -a $(STD) --workdir=$(WORK_DIR) $(UART_SRCS) $(UART_TB)
	$(GHDL) -e $(STD) --workdir=$(WORK_DIR) -o $(WORK_DIR)/uart_tb uart_tb
	$(GHDL) -r $(STD) --workdir=$(WORK_DIR) uart_tb --stop-time=200ms

## Simulate 5G NR QAM Modulator (no VCD; use 'make vcd-qam' for waveforms)
sim-qam: $(QAM_SRCS) $(QAM_TB)
	@mkdir -p $(WORK_DIR)
	$(GHDL) -a $(STD) --workdir=$(WORK_DIR) $(QAM_SRCS) $(QAM_TB)
	$(GHDL) -e $(STD) --workdir=$(WORK_DIR) -o $(WORK_DIR)/qam_modulator_nr_tb qam_modulator_nr_tb
	$(GHDL) -r $(STD) --workdir=$(WORK_DIR) qam_modulator_nr_tb

## Run with VCD capture (for GTKWave)
vcd-uart: $(UART_SRCS) $(UART_TB)
	@mkdir -p $(WORK_DIR)
	$(GHDL) -a $(STD) --workdir=$(WORK_DIR) $(UART_SRCS) $(UART_TB)
	$(GHDL) -e $(STD) --workdir=$(WORK_DIR) -o $(WORK_DIR)/uart_tb uart_tb
	$(GHDL) -r $(STD) --workdir=$(WORK_DIR) uart_tb \
	    --vcd=$(UART_VCD) --stop-time=200ms

vcd-qam: $(QAM_SRCS) $(QAM_TB)
	@mkdir -p $(WORK_DIR)
	$(GHDL) -a $(STD) --workdir=$(WORK_DIR) $(QAM_SRCS) $(QAM_TB)
	$(GHDL) -e $(STD) --workdir=$(WORK_DIR) -o $(WORK_DIR)/qam_modulator_nr_tb qam_modulator_nr_tb
	$(GHDL) -r $(STD) --workdir=$(WORK_DIR) qam_modulator_nr_tb \
	    --vcd=$(QAM_VCD)

## Open waveforms in GTKWave (run 'make vcd-*' first)
wave-uart: $(UART_VCD)
	gtkwave $(UART_VCD) &

wave-qam: $(QAM_VCD)
	gtkwave $(QAM_VCD) &

wave: wave-uart

## Remove generated files
clean:
	rm -rf $(WORK_DIR) $(UART_VCD) $(QAM_VCD)
