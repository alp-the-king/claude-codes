# Makefile for UART with programmable baud rate (VHDL)
# Requires: GHDL  https://github.com/ghdl/ghdl
# Optional: GTKWave for waveform viewing

RTL_DIR  := rtl
SIM_DIR  := sim

RTL_SRCS := $(RTL_DIR)/uart_baud_gen.vhd \
            $(RTL_DIR)/uart_tx.vhd        \
            $(RTL_DIR)/uart_rx.vhd        \
            $(RTL_DIR)/uart.vhd

TB_SRC   := $(SIM_DIR)/uart_tb.vhd

WORK_DIR := $(SIM_DIR)/work
VCD_FILE := $(SIM_DIR)/uart_tb.vcd
GHDL     := ghdl
STD      := --std=08

.PHONY: all sim wave clean

all: sim

## Analyse, elaborate, and run the simulation
sim: $(RTL_SRCS) $(TB_SRC)
	@mkdir -p $(WORK_DIR)
	$(GHDL) -a $(STD) --workdir=$(WORK_DIR) $(RTL_SRCS) $(TB_SRC)
	$(GHDL) -e $(STD) --workdir=$(WORK_DIR) -o $(WORK_DIR)/uart_tb uart_tb
	$(GHDL) -r $(STD) --workdir=$(WORK_DIR) uart_tb \
	    --vcd=$(VCD_FILE) --stop-time=200ms

## Open waveform in GTKWave (run 'make sim' first)
wave: $(VCD_FILE)
	gtkwave $(VCD_FILE) &

## Remove generated files
clean:
	rm -rf $(WORK_DIR) $(VCD_FILE)
