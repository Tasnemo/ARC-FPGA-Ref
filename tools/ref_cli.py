#!/usr/bin/env python3
"""Talk to the referee board from a terminal (bring-up and debugging).

    pip install pyserial
    python3 tools/ref_cli.py --port COM5 monitor           # print decoded frames
    python3 tools/ref_cli.py --port /dev/ttyUSB1 start     # send a command, then monitor
    python3 tools/ref_cli.py --port COM5 hit 0 2           # hit red armor 2

Commands: monitor, prep, start, pause, resume, end, reset,
          hit <robot> <armor>, shoot <robot> [speed], yellow <robot>,
          red <robot>, kill <robot>, revive <robot>, power <robot> <watts>
Robots: 0 = red, 1 = blue.
"""
import argparse
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import arcref  # noqa: E402

GAME = {"prep": 1, "start": 2, "pause": 3, "resume": 4, "end": 5, "reset": 6}


def build(cmd, args):
    a = [int(x) if x.isdigit() else x for x in args]
    if cmd in GAME:
        return arcref.cmd_game(GAME[cmd])
    if cmd == "hit":
        return arcref.cmd_hit(a[0], a[1])
    if cmd == "shoot":
        return arcref.cmd_shoot(a[0], 5, float(args[1]) if len(args) > 1 else 25.0)
    if cmd == "yellow":
        return arcref.cmd_penalty(a[0], 2)
    if cmd == "red":
        return arcref.cmd_penalty(a[0], 3)
    if cmd == "kill":
        return arcref.cmd_life(a[0], False)
    if cmd == "revive":
        return arcref.cmd_life(a[0], True)
    if cmd == "power":
        return arcref.cmd_power(a[0], a[1])
    raise SystemExit(f"unknown command {cmd!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True, help="serial port, e.g. COM5 or /dev/ttyUSB1")
    ap.add_argument("--all", action="store_true", help="also print 0x0202 (50 Hz)")
    ap.add_argument("cmd", nargs="?", default="monitor")
    ap.add_argument("args", nargs="*")
    opt = ap.parse_args()

    import serial  # pyserial

    port = serial.Serial(opt.port, 115200, timeout=0.05)
    port.write(arcref.cmd_time(int(time.time())))
    if opt.cmd != "monitor":
        port.write(build(opt.cmd, opt.args))

    dec = arcref.Decoder()
    try:
        while True:
            for cmd, seq, payload in dec.feed(port.read(4096)):
                if cmd == 0x0202 and not opt.all:
                    continue
                print(f"{seq:3d} 0x{cmd:04X} {arcref.decode_payload(cmd, payload)}")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
