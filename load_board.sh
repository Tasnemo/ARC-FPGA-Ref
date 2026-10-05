#!/bin/sh
# Loads the referee onto a Zybo Z7 over its USB cable (macOS / Linux).
# Needs openFPGALoader:  brew install openfpgaloader   (macOS)
#                        sudo apt install openfpgaloader (Debian/Ubuntu)
# Set jumper JP5 to JTAG. The design is lost at power-off; run this again.
#   ./load_board.sh          Zybo Z7-10
#   ./load_board.sh 20       Zybo Z7-20
set -e
cd "$(dirname "$0")"
size="${1:-10}"
bit="prebuilt/arc_ref_zybo_z7_${size}.bit"
if ! command -v openFPGALoader >/dev/null 2>&1; then
    echo "openFPGALoader not found. macOS: brew install openfpgaloader"
    exit 1
fi
if [ ! -f "$bit" ]; then
    echo "$bit is missing. Build it once on a PC with Vivado (hw/scripts/build_standalone.tcl) and commit it."
    exit 1
fi
openFPGALoader -b "zybo_z7_${size}" "$bit"
echo "Loaded. Open web/arc-ref-console.html in Chrome and click Connect board."
