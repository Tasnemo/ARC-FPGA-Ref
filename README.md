# ARC FPGA Referee

An FPGA stand-in for the ARC robotics competition referee system (ARC is the
former RoboMaster North America and uses the RoboMaster referee system),
controlled from a web page in Chrome.

```
 Chrome / Edge (Windows or macOS)            Zybo Z7-10
┌──────────────────────────────┐  USB  ┌─────────────────────────────────────────────┐
│ web/  referee console        │◀─────▶│ PS UART1 ─ ARM bridge ─ AXI ─┐               │
│  scoreboard, match control,  │ 115200│                              ▼   fabric      │
│  hits / shots / penalties,   │  8N1  │   parser ▶ referee core ▶ frame generator    │
│  robot link view, raw frames │       │   (stages, timer, HP, heat, power, CRCs)     │
└──────────────────────────────┘       │   BTN0-3 armor hits · SW0 target · LD0-3     │
                                       └─────────────────────────────────────────────┘
```

All referee logic runs in the FPGA fabric and follows the **ARCC 2026 rules**
(Events Manual V1.6), in either **1v1** (one Infantry per side) or **3v3** (Hero,
Infantry and Sentry per side, with Victory Points, capture point, respawn and gold). The board sends **real referee frames** in the
2026 protocol layouts (`0x0001` game status, `0x0201` robot status, `0x0202`
buffer/heat, `0x0206` hurt, and others), so a robot's existing referee
parser should work against it. Later you could route the same byte stream out a Pmod UART to a
robot. The ARM core only copies bytes between USB and the fabric.

See [docs/protocol.md](docs/protocol.md) for the frame formats, control
commands, rules model and register map.

## Repo layout

| Path | Contents |
|---|---|
| `hw/rtl/` | Verilog: parser, referee core, frame generator, FIFO, inputs, AXI wrapper |
| `hw/sim/` | Icarus testbench (drives the AXI bus like the ARM does) |
| `hw/scripts/build.tcl`, `hw/constraints/` | Vivado project, block design and pins for the Zybo Z7-10 |
| `sw/ref_bridge/main.c` | bare-metal UART ⇄ fabric bridge |
| `sw/scripts/` | build the app and `BOOT.BIN` (xsct), program over JTAG |
| `web/` | the console. `arc-ref-console.html` is the single-file build |
| `tools/` | Python protocol library, sim checker, terminal client, bundler |

## Quick start: try the console with no board

Open **`web/arc-ref-console.html`** in **Chrome or Edge** (double-click it, on
Windows or macOS) and click **Demo mode**. Demo mode emulates the board in
JavaScript with the same rules and the same byte stream.

Safari and Firefox don't support Web Serial, so use Chrome or Edge, including on a Mac.

## Running it on the board

### 1. Get a `BOOT.BIN`

Vivado runs on Windows and Linux only. **On a Mac you can't build the
bitstream**: get `BOOT.BIN` from a teammate who built it on a PC, then go to
step 2.

On Windows or Linux, with Vivado + Vitis **2023.1 or 2023.2** installed:

1. Install the Digilent board files. Copy `board_files` from
   [digilent/vivado-boards](https://github.com/Digilent/vivado-boards) into
   `<Xilinx>/Vivado/2023.x/data/boards/board_files/`. The build still runs
   without them, but the DDR settings won't be tuned for the board.
2. Clone this repo to a path **without spaces**, e.g. `C:\work\ARC-FPGA-Ref`.
3. Build:
   - **Windows:** open "Vitis 2023.x Command Prompt" (or run `settings64.bat`), `cd` to the repo, run `build_all.bat`
   - **Linux:** `source <Xilinx>/Vitis/2023.x/settings64.sh && ./build_all.sh`

   The outputs are `build/sd/BOOT.BIN` (SD card) plus `build/arc_ref.bit` and the
   app ELF (for JTAG). Vitis 2024.1+ dropped the classic `xsct` flow; there,
   make a platform from `build/arc_ref.xsa` and an empty C app with
   `sw/ref_bridge/main.c` in the GUI.

### 2. Boot the Zybo

**From an SD card (works for Mac and Windows users):** copy `BOOT.BIN` to a
FAT32 microSD card, set jumper **JP5 to SD**, insert the card and power the board.

**Over JTAG (needs a PC with Vitis):** set JP5 to JTAG, then run
`xsct sw/scripts/run_jtag.tcl`.

### 3. Connect from Chrome

1. Plug in the micro-USB port labelled PROG/UART.
2. Open `web/arc-ref-console.html` (or run `make serve` / `python3 -m http.server 8000 --directory web`
   and go to http://localhost:8000).
3. Click **Connect board** and pick the Zybo.

| | What the port picker shows | Notes |
|---|---|---|
| **Windows** | "USB Serial Port (COMn)" | Windows Update normally installs the FTDI driver. If nothing shows up, install the [FTDI VCP driver](https://ftdichip.com/drivers/vcp-drivers/) (Vivado's cable drivers also include it). |
| **macOS** | Two entries for the board (two FTDI interfaces) | The UART is usually the **second** one. If you pick the JTAG one, the console says "no referee data" after a couple of seconds: disconnect and pick the other. macOS has a built-in FTDI driver, so nothing to install. |

Only one program can hold the port at a time. Close PuTTY, `screen`, the
Vitis serial terminal and similar before connecting. The picker only shows
FTDI devices. **Other port…** shows everything, if you use a different USB-UART.

### 4. Run a match

1. Pick **1v1** or **3v3** in match control (only before a match). That loads the
   ARCC 2026 stats for every robot. **Rules config** lets you change times, the
   link robot and any robot's stats, then **Apply**.
2. **Start setup period** runs the setup countdown (pause it for timeouts), then
   the 15 s referee init, the 5 s countdown and the battle. **Skip to init** jumps
   straight to the init period.
3. During the battle, per robot (in 3v3, pick Hero / Infantry / Sentry at the top
   of each control panel):
   - Click armor plates, or press **BTN0–3** on the board, to register hits. SW0 picks the team and SW2:1 the robot. Choose 17 mm, 42 mm or collision.
   - **Fire** shots to add barrel heat. A speed over the limit locks the launcher.
   - Drag **Chassis draw** past the limit to drain buffer energy and trigger the 5 s chassis cut.
   - Give yellow or red cards, a both-teams yellow, a forfeit, or simulate an abnormal disconnection.
   - 3v3: mark where the robot is (field, resupply zone, capture point), and buy projectiles with gold in the resupply zone. Infantry chassis and launcher types can be chosen until the battle starts.
4. The scoreboard shows HP, heat, buffer, projectiles, cards and launcher/chassis
   status. In 3v3 it also shows VP, gold, damage dealt, respawn timers and the
   capture point. At the end it shows the winner and why.
5. **Robot link view** shows the real frames decoded the way the link robot
   would see them.

The terminal client works on both OSes too:
`pip install pyserial`, then `python3 tools/ref_cli.py --port COM5 monitor`
(on a Mac use `--port /dev/cu.usbserial-XXXXB`).

## Development

`make test` needs only `iverilog`, Python 3 and Node 18+, with no Xilinx tools.
It:

1. simulates the RTL end to end (`hw/sim/tb_arc_ref.v`: two 1v1 and two 3v3 rounds),
2. decodes and checks every byte the board would send (`tools/check_sim.py`, 58 checks),
3. checks `web/js/protocol.js` against that output, and replays all four rounds
   through the JS emulator, which must end exactly like the RTL,
4. checks that `web/arc-ref-console.html` is up to date.

After editing anything in `web/`, run `make bundle` (or `python3 tools/bundle_web.py`) and commit the regenerated file.

Install the tools on macOS with `brew install icarus-verilog node`. On Windows, use
the [Icarus installer](https://bleyer.org/icarus/) and Node from nodejs.org, then run
the commands from the Makefile directly if you don't have `make`.

## Not done yet / to verify

- **A few rules aren't modelled**, such as the pilot screen blackout after a
  yellow card and the 2 s RFID expiry on the capture point. `docs/protocol.md`
  lists everything covered and not covered.
- **Check that it fits the Z7-10 in Vivado.** A full open-source synthesis
  (yosys `synth_xilinx`) puts the fabric at about 12,500 LUTs (71 % of the
  Z7-10), 5,000 flip-flops (14 %) and 14 of 80 DSPs. Vivado usually maps
  tighter, but the PS block design adds some AXI glue; `build/utilization.txt`
  from `build_all` has the real numbers.
- **Protocol checked against V1.3.0.** Every real frame matches the official
  document field by field. The one open question is in the document itself:
  `0x0208` is listed as 6 bytes, but its struct is 8 bytes; we send 8.
- **Not yet built in Vivado here.** The RTL passes simulation and a yosys
  synthesis check, but the block-design script, PS settings and the SD/JTAG
  flows haven't been run on real hardware yet.
- **Pmods aren't used yet.** The natural next step is routing the frame stream
  to a Pmod UART for a real robot, and armor inputs from Pmod pins.
