# Makefile for UART with programmable baud rate
# Requires: Icarus Verilog (iverilog / vvp) and optionally GTKWave

RTL_DIR  := rtl
SIM_DIR  := sim

RTL_SRCS := $(RTL_DIR)/uart_baud_gen.v \
            $(RTL_DIR)/uart_tx.v       \
            $(RTL_DIR)/uart_rx.v       \
            $(RTL_DIR)/uart.v

TB_SRC   := $(SIM_DIR)/uart_tb.v

SIM_OUT  := $(SIM_DIR)/uart_tb.out
VCD_FILE := $(SIM_DIR)/uart_tb.vcd

.PHONY: all sim wave clean

all: sim

## Compile and run the simulation
sim: $(RTL_SRCS) $(TB_SRC)
	@mkdir -p $(SIM_DIR)
	iverilog -g2005 -Wall -o $(SIM_OUT) $(RTL_SRCS) $(TB_SRC)
	vvp $(SIM_OUT)

## Open waveform in GTKWave (run 'make sim' first)
wave: $(VCD_FILE)
	gtkwave $(VCD_FILE) &

## Remove generated files
clean:
	rm -f $(SIM_OUT) $(VCD_FILE)
