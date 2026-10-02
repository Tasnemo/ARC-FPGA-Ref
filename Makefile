# Host-side checks (no Xilinx tools needed). Vivado/Vitis steps are in README.

IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := $(wildcard hw/rtl/*.v)

.PHONY: all sim test bundle serve bitstream firmware program clean

all: test

hw/sim/out/tb.vvp: hw/sim/tb_arc_ref.v $(RTL) hw/rtl/arc_crc.vh
	mkdir -p hw/sim/out
	$(IVERILOG) -g2005 -Wall -I hw/rtl -o $@ hw/sim/tb_arc_ref.v $(RTL)

# RTL simulation + decode/check of every byte the board would send.
sim: hw/sim/out/tb.vvp
	cd hw/sim && $(VVP) -n out/tb.vvp
	python3 tools/check_sim.py

# Simulation, then the browser protocol code and emulator against its output.
test: sim
	node web/test/protocol.test.mjs
	python3 tools/bundle_web.py --check

# Single-file console (double-click on Windows/macOS, no web server needed).
bundle:
	python3 tools/bundle_web.py

# Web Serial needs a secure context; localhost counts.
serve:
	python3 -m http.server 8000 --directory web

bitstream:
	vivado -mode batch -nojournal -nolog -source hw/scripts/build.tcl

firmware:
	xsct sw/scripts/build_sw.tcl

program:
	xsct sw/scripts/run_jtag.tcl

clean:
	rm -rf hw/sim/out build
