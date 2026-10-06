# ARC FPGA Referee

An FPGA stand-in for the ARC robotics competition referee system (ARC is the
former RoboMaster North America and uses the RoboMaster referee system),
controlled from a web page in Chrome.

```
 Chrome (Mac / Windows / Linux)                   Zybo Z7-10 (standalone build)
┌──────────────────────────────┐  USB-serial ┌──────────────────────────────────────┐   UART    ┌──────────────┐
│ web/arc-ref-console.html     │◀── Pmod JE ─▶│ parser ▶ referee core ▶ frame gen    │── JD1 ──▶ │ your robot's │
│  scoreboard, match control,  │   115200     │ (1v1 / 3v3 rules, HP, heat, VP, CRCs)│  115200   │ control board│
│  hits / penalties, link view │              │ BTN0-3 armor hits · SW · LEDs        │           │ (referee RX) │
└──────────────────────────────┘              └──────────────────────────────────────┘           └──────────────┘
          loaded once per power-up over the Zybo's own USB cable with openFPGALoader
```

All referee logic runs in the FPGA fabric and follows the **ARCC 2026 rules**
(Events Manual V1.6), in either **1v1** (one Infantry per side) or **3v3** (Hero,
Infantry and Sentry per side, with Victory Points, capture point, respawn and gold).
The board sends **real referee frames** in the RoboMaster 2026 protocol V1.3.0
layouts to the browser and, over a UART pin, **to a robot**, exactly as the real
referee's power-management module does, so a robot's referee parser works
against it unchanged.

It runs on two boards with the same referee logic:

- **Zybo Z7-10:** wired. Chrome talks to it over USB serial, and the robot is on a wire.
- **Kria KR260:** wireless. The board runs its own WiFi hotspot, the console works in
  any browser, and each robot gets its referee frames through a small ESP32 receiver.
  See [Kria KR260: wireless](#kria-kr260-wireless).

See [docs/protocol.md](docs/protocol.md) for the frame formats, control
commands, rules model and register map.

## Repo layout

| Path | Contents |
|---|---|
| `hw/rtl/` | Verilog: parser, referee core, frame generator, FIFOs, UARTs, inputs, AXI wrapper, standalone top |
| `hw/sim/` | Icarus testbenches: the SD-card build over AXI, the standalone build over its UART pins |
| `hw/scripts/build_standalone.tcl` | Vivado build of the standalone bitstream into `prebuilt/` |
| `prebuilt/`, `load_board.sh`, `load_board.bat` | the bitstream anyone can load with openFPGALoader |
| `hw/scripts/build.tcl`, `hw/constraints/` | Vivado project, block design and pins for the Zybo Z7-10 |
| `sw/ref_bridge/main.c` | bare-metal UART ⇄ fabric bridge |
| `sw/scripts/` | build the app and `BOOT.BIN` (xsct), program over JTAG |
| `web/` | the console. `arc-ref-console.html` is the single-file build |
| `tools/` | Python protocol library, sim checker, terminal client, bundler |
| `hw/scripts/build_kr260.tcl`, `hw/constraints/kr260.xdc` | Vivado build of the KR260 design into `prebuilt/kr260/` |
| `kria/` | KR260 daemon `arc_refd.py`, its test, `install.sh`, device-tree overlay |
| `esp32/robot_link/` | ESP32 receiver that sits on each robot (WiFi to referee UART) |

## Quick start: try the console with no board

Open **`web/arc-ref-console.html`** in **Chrome or Edge** (double-click it, on
Windows or macOS) and click **Demo mode**. Demo mode emulates the board in
JavaScript with the same rules and the same byte stream.

Safari and Firefox don't support Web Serial, so use Chrome or Edge, including on a Mac.

## Run it on a real board (Mac, Windows or Linux, no SD card, no Vivado)

**You need:** a Zybo Z7-10 with its micro-USB cable, Chrome, and a **3.3 V USB-serial
adapter** for the browser link: Digilent's **PmodUSBUART** plugs straight into Pmod
**JE** (top row); any CP2102 / CH340 / FT232 adapter works with three jumper wires.
(The Zybo's own USB-serial port is wired to the ARM side, which this build doesn't use.)

1. **Install openFPGALoader once.**
   - macOS: `brew install openfpgaloader`
   - Windows: install [MSYS2](https://www.msys2.org), then in its UCRT64 shell
     `pacman -S mingw-w64-ucrt-x86_64-openFPGALoader`, and add `C:\msys64\ucrt64\bin` to PATH
   - Linux: `sudo apt install openfpgaloader` (or build it)
2. **Set jumper JP5 to JTAG**, plug the Zybo's micro-USB (PROG/UART) in and power on.
3. **Load the referee:** `./load_board.sh` (Mac/Linux) or `load_board.bat` (Windows).
   It takes a few seconds. The FPGA forgets it at power-off; just run it again.
4. **Plug in the USB-serial adapter** on JE:

   | Adapter pin | Zybo Pmod JE |
   |---|---|
   | RX (adapter receives) | JE2 (FPGA TX) |
   | TX (adapter sends) | JE3 (FPGA RX) |
   | GND | JE5 |
   | 3.3 V / 5 V | **leave unconnected** |

   A PmodUSBUART just plugs into JE's top row.
5. **Open `web/arc-ref-console.html` in Chrome** (not Safari), click **Connect board**
   and pick the adapter. If the page says "no referee data", flip **SW3**: it swaps
   JE2 and JE3, for adapters labelled the other way round.

**Windows driver note:** openFPGALoader talks to the Zybo's JTAG through libusb. If it
reports that no cable is found, run [Zadig](https://zadig.akeo.ie), choose the Zybo's
*Interface 0*, and install **WinUSB** for it. (Vivado won't see that cable until you
reinstall Digilent's driver.) This hasn't been tried on real hardware yet.

`prebuilt/arc_ref_zybo_z7_10.bit` is what `load_board` loads. **Someone with Vivado
builds it once** (`vivado -mode batch -source hw/scripts/build_standalone.tcl`) and
commits it; after that nobody else needs Vivado. Rebuild only after changes under
`hw/rtl/`; console changes never need a rebuild.

## Connecting a robot

On a real robot, the referee's power-management module streams the referee frames
to the robot's control board over its **User** serial port at **115200 8N1** (protocol
V1.3.0, table 1-1). The board does the same on Pmod **JD**:

| Zybo Pmod JD | Robot control board (referee UART) |
|---|---|
| JD1 (FPGA TX) | RX |
| JD2 (FPGA RX) | TX (reserved for robot → referee data) |
| JD5 (GND) | GND |

- The robot gets exactly what it would get from the real referee for the **link robot**
  (choose it in **Rules config**): game status, its HP and limits, buffer and heat,
  ally HP, hurt and shoot events, allowance and gold, buffs, RFID, warnings. Console-only
  frames are never sent to the robot.
- It's **3.3 V logic**. DJI's A and C boards use 3.3 V UARTs; if your board's referee port
  is 5 V, use a level shifter.
- Both builds (standalone and SD card) have this port. One robot at a time for now; in
  3v3 pick which robot is linked.

## Kria KR260: wireless

```
 any browser (laptop, tablet, phone)            Kria KR260                                   on each robot
┌───────────────────────────┐   WiFi   ┌────────────────────────────────────────┐   WiFi   ┌────────┐ UART  ┌────────────┐
│ http://10.42.0.1/         │◀────────▶│ Ubuntu: arc-refd ◀AXI▶ PL referee core │◀────────▶│ ESP32  │──────▶│ robot      │
│ console + wireless panel  │ "ARC-REF"│  (USB WiFi adapter = hotspot)          │  UDP     │ robot_ │115200 │ controller │
└───────────────────────────┘          └────────────────────────────────────────┘          │ link   │       │ (referee   │
                                         PMOD 1 also has a wired robot UART              └────────┘       │  port)     │
                                                                                                          └────────────┘
```

This mirrors the real referee system: the KR260 is the referee server at the side
of the field, the ESP32 bolted to the robot is the referee module, and the robot's
controller gets the same frames on the same 115200-baud serial line it would in a match.

**No board has WiFi built in**, the KR260 included, so you need:

| Part | Notes |
|---|---|
| Kria KR260 + its SD card with AMD's **Ubuntu 22.04** image | as shipped; follow AMD's KR260 getting-started guide once |
| **USB WiFi adapter that supports AP mode** on Linux | e.g. one with a MediaTek MT7612U or MT7610U chip (in-kernel `mt76` driver) |
| **One ESP32 per robot** | any ESP32 DevKit (about $5); ESP32-S3 and C3 also work with other pins |

### Set up the board (once)

On the KR260 (keyboard and screen, or SSH over Ethernet):

```bash
git clone https://github.com/Tasnemo/ARC-FPGA-Ref && cd ARC-FPGA-Ref
sudo ./kria/install.sh
```

That installs the PL design for `xmutil`, creates the **ARC-REF** hotspot (2.4 GHz,
password `arcref2026`, change it with `ARC_WIFI_PASSWORD=...`), and starts the
`arc-refd` service at every boot. It needs `prebuilt/kr260/arc-ref.bit.bin`, which
someone with Vivado builds once with `make bitstream-kr260` and commits.

### Run a match

1. Join the **ARC-REF** WiFi on the laptop (Mac, Windows, Linux, or even a phone) and
   open **http://10.42.0.1/**. The console connects by itself, in any browser, because it
   doesn't need Web Serial. The single-file `arc-ref-console.html` works too: click
   **Kria (WiFi)**.
2. For each robot, open `esp32/robot_link/robot_link.ino` in the Arduino IDE (with the
   esp32 boards package), set `ROBOT_NAME`, and upload it to an ESP32. Wire it up:

   | ESP32 | Robot referee port |
   |---|---|
   | GPIO17 (TX) | RX |
   | GPIO16 (RX) | TX |
   | GND | GND |

3. The robot appears in the **Wireless link** panel within a second, with its live
   round-trip time.

More than one browser can connect at once, for example a scoreboard on a second
screen. Every robot receives the link robot's view, as on the Zybo.

### Real time

The rules, the match clock and the frame timing all run in the FPGA fabric, exactly
as on the Zybo. Linux and WiFi only carry bytes, and every step is built to add as
little delay as possible and never build up a backlog:

| Step | Delay | How |
|---|---|---|
| PL referee core | ns | hardware; frames scheduled at the protocol's rates |
| PL → arc-refd | ≤ 1 ms | the pump thread polls the PL every 1 ms with `SCHED_FIFO` priority and locked memory |
| arc-refd → WiFi | < 1 ms | each batch is sent in the same pass, in the WiFi **voice** queue (WMM AC_VO); a full socket drops the datagram rather than queueing it |
| WiFi air time | typically 1–5 ms | power saving off on both ends, 2.4 GHz channel of your choice |
| ESP32 → robot UART | immediate | each datagram is written to the UART the moment it arrives |

Measured in the test (`make kria-test`, on a PC, no real-time priority): the daemon adds
**0.6 ms median, 1.5 ms p99** between a byte leaving the PL FIFO and the robot's datagram.
The WiFi figures are typical values, not measurements on this setup. The console
measures the real ones: the board pings every robot 10 times a second and shows
**RTT p50 / p99 / max and loss per robot**, coloured green under 10 ms. For scale, one 23-byte
0x0202 frame takes 2.0 ms just to cross the robot's 115200-baud wire, the same as with the official module.

Tips for a busy venue: pick the quietest 2.4 GHz channel (`ARC_WIFI_CHANNEL=1`, `6` or
`11`), keep the board's adapter in line of sight of the field, and watch the p99
column. If WiFi isn't good enough, PMOD 1 (pin 8 TX, pin 9 RX, pin 11 GND, 3.3 V)
carries the same robot stream on a wire.

### Try it without a board

```bash
make sim                                         # records the RTL's byte stream
python3 kria/arc_refd.py --backend fake --port 8080
```

Then open http://localhost:8080/. The fake backend replays the simulated board in
real time, and any ESP32 on the same network can point `BOARD_IP_OVERRIDE` at your
computer.

## Alternative: SD-card build (no extra adapter)

This uses the Zybo's own USB-serial port through the ARM processor, so it needs no
USB-serial adapter, but someone has to make `BOOT.BIN` with Vivado and Vitis and
each board needs an SD card.


### 1. Make `BOOT.BIN` (needs Vivado + Vitis)

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

## Running a match

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

1. simulates the SD-card build end to end over AXI (`hw/sim/tb_arc_ref.v`: two 1v1 and
   two 3v3 rounds) and checks every byte sent to the browser and to the robot
   (`tools/check_sim.py`, 66 checks),
2. simulates the standalone build through its UART pins only, including the SW3 swap
   and the robot link (`hw/sim/tb_standalone.v`, `tools/check_standalone.py`),
3. checks `web/js/protocol.js` against that output, and replays all four rounds
   through the JS emulator, which must end exactly like the RTL,
4. checks that `web/arc-ref-console.html` is up to date,
5. runs the KR260 daemon against the simulated stream (`kria/test_arc_refd.py`): the
   browser must get the board stream byte for byte, the robot must get exactly what the
   RTL's own robot UART sent, and the added latency must stay under 5 ms p99.

After editing anything in `web/`, run `make bundle` (or `python3 tools/bundle_web.py`) and commit the regenerated file.

Install the tools on macOS with `brew install icarus-verilog node`. On Windows, use
the [Icarus installer](https://bleyer.org/icarus/) and Node from nodejs.org, then run
the commands from the Makefile directly if you don't have `make`.

## Not done yet / to verify

- **Nothing has run on a real Zybo yet.** Everything that can be checked without one
  passes: both builds in simulation, the protocol against V1.3.0, the console in Chrome,
  and a full yosys synthesis (about 69–71 % of the Z7-10's LUTs). The first Vivado build
  and the first openFPGALoader load are the next steps; send the log if either fails.
- **The PmodUSBUART pin direction is from Digilent's docs.** If it's the other way
  round, SW3 fixes it without a rebuild.
- **Nothing has run on a real KR260 yet either.** The KR260 pins come from AMD's own
  KR260 designs, the overlay compiles, the daemon and the console are tested against the
  simulated board, and the ESP32 sketch compiles (arduino-esp32 3.0.7). The parts only
  hardware can confirm are the overlay's reset and AXI port settings, which are copied
  from AMD's Kria examples, your WiFi adapter's AP mode, and the real WiFi latency.
- **One robot link.** The robot port carries the link robot's view. Six separate
  robot ports for a full 3v3 would be the next step.
- **A few rules aren't modelled**, such as the pilot screen blackout after a yellow
  card and the 2 s RFID expiry on the capture point. `docs/protocol.md` lists them.
- **`0x0208` length:** the V1.3.0 document lists it as 6 bytes but its struct is 8;
  we send 8.
