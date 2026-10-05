# Host-side checks (no Xilinx tools needed). Vivado/Vitis steps are in README.

IVERILOG ?= iverilog
VVP      ?= vvp
RTL      := $(wildcard hw/rtl/*.v)

.PHONY: all sim sim-standalone test bundle serve bitstream bitstream-standalone firmware program load clean

all: test

hw/sim/out/tb.vvp: hw/sim/tb_arc_ref.v $(RTL) hw/rtl/arc_crc.vh
	mkdir -p hw/sim/out
	$(IVERILOG) -g2005 -Wall -I hw/rtl -s tb_arc_ref -o $@ hw/sim/tb_arc_ref.v $(RTL)

hw/sim/out/sa.vvp: hw/sim/tb_standalone.v $(RTL) hw/rtl/arc_crc.vh
	mkdir -p hw/sim/out
	$(IVERILOG) -g2005 -Wall -I hw/rtl -s tb_standalone -o $@ hw/sim/tb_standalone.v $(RTL)

# RTL simulation + decode/check of every byte the board would send.
sim: hw/sim/out/tb.vvp
	cd hw/sim && $(VVP) -n out/tb.vvp
	python3 tools/check_sim.py

# Standalone (fabric-only) build over its UART pins.
sim-standalone: hw/sim/out/sa.vvp
	cd hw/sim && $(VVP) -n out/sa.vvp
	python3 tools/check_standalone.py

# Simulation, then the browser protocol code and emulator against its output.
test: sim sim-standalone
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

bitstream-standalone:
	vivado -mode batch -nojournal -nolog -source hw/scripts/build_standalone.tcl

load:
	./load_board.sh

firmware:
	xsct sw/scripts/build_sw.tcl

program:
	xsct sw/scripts/run_jtag.tcl

clean:
	rm -rf hw/sim/out build
