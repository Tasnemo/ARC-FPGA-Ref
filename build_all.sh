#!/bin/sh
# Linux: full build (bitstream, bridge app, SD card image).
# Source Vivado/Vitis settings64.sh first. Vivado does not run on macOS;
# Mac users can use a BOOT.BIN built on a PC (see README).
set -e
cd "$(dirname "$0")"
vivado -mode batch -nojournal -nolog -source hw/scripts/build.tcl
xsct sw/scripts/build_sw.tcl
echo "Done. SD card image: build/sd/BOOT.BIN"
