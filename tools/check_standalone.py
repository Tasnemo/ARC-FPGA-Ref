#!/usr/bin/env python3
"""Check hw/sim/tb_standalone.v: the standalone build talks over its UART
pins (PC link and robot link) without any PS. Exits non-zero on failure."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import arcref  # noqa: E402

out = pathlib.Path(__file__).parent.parent / "hw/sim/out"
fails = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


def load(name):
    data = bytes(int(x, 16) for x in (out / name).read_text().split())
    dec = arcref.Decoder()
    return dec.feed(data), dec.bad


pc, pc_bad = load("sa_pc.hex")
rb, rb_bad = load("sa_robot.hex")
print(f"standalone: {len(pc)} PC frames, {len(rb)} robot frames")
d = [(c, arcref.decode_payload(c, p)) for c, _, p in pc]
srv = [x for c, x in d if c == 0xF101]
ev = [x for c, x in d if c == 0xF102]

check(pc and pc_bad <= 1, f"PC link frames pass CRC ({pc_bad} cut off by the SW3 swap mid-frame)")
check(len(srv) > 50, "board streams its state (0xF101) over the PC UART")
check(any(x["rx_ok"] >= 3 for x in srv), "board accepted the TIME / CONFIG / START frames sent over UART")
check(any(x["stage"] == 4 for x in srv), "match reaches battle")
check(any(e["kind"] == "hit" and e["robot"] == 1 and e["hp"] == 180 for e in ev), "hit on red: 200 -> 180")
check(any(e["kind"] == "hit" and e["robot"] == 4 and e["hp"] == 180 for e in ev),
      "after SW3 swaps JE2/JE3, the link works on the other pins (hit on blue)")
check(rb and rb_bad == 0 and not any(c >= 0xF000 for c, _, _ in rb), "robot link carries only real referee frames")
check(any(c == 0x0206 for c, _, _ in rb), "robot receives its 0x0206 hurt frame")

print("PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
