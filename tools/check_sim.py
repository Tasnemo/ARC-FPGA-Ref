#!/usr/bin/env python3
"""Decode hw/sim/out/tx_bytes.hex and check it against the scenario in
hw/sim/tb_arc_ref.v (ARCC 2026 1v1 rules). Exits non-zero on any failure."""
import collections
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import arcref  # noqa: E402

path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                    pathlib.Path(__file__).parent.parent / "hw/sim/out/tx_bytes.hex")
data = bytes(int(line, 16) for line in path.read_text().split())
dec = arcref.Decoder()
frames = dec.feed(data)

fails = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


counts = collections.Counter(c for c, _, _ in frames)
print(f"{len(data)} bytes, {len(frames)} frames, {dec.bad} bad")
for cmd, n in sorted(counts.items()):
    print(f"  0x{cmd:04X}: {n}")

SIZES = {0x0001: 11, 0x0002: 1, 0x0003: 16, 0x0104: 3, 0x0201: 13, 0x0202: 14,
         0x0206: 1, 0x0207: 7, 0xF101: 66, 0xF102: 5}
check(dec.bad == 0, "every frame passes CRC8 and CRC16")
check(len(dec.buf) < 80, "no trailing garbage")
seqs = [s for _, s, _ in frames]
check(all((b - a) % 256 == 1 for a, b in zip(seqs, seqs[1:])), "seq increments by one")
check(all(len(p) == SIZES.get(c, len(p)) for c, _, p in frames),
      "payload sizes match the 2026 protocol")

# Split the stream at the reset between the two rounds.
d = [(c, arcref.decode_payload(c, p)) for c, _, p in frames]
first_result = next(i for i, (c, _) in enumerate(d) if c == 0x0002)
round2_start = next(i for i, (c, x) in enumerate(d)
                    if i > first_result and c == 0x0001 and x["progress"] != 5)
r1, r2 = d[:round2_start], d[round2_start:]


def of(seq, cmd):
    return [x for c, x in seq if c == cmd]


# ---------------------------------------------------------------- round 1
print("round 1")
stats = of(r1, 0x0001)
progress = []
for s in stats:
    if not progress or progress[-1] != s["progress"]:
        progress.append(s["progress"])
check(progress == [0, 1, 2, 3, 4, 5], f"stages idle, setup, init, countdown, battle, settlement ({progress})")
check(any(x["paused"] and x["stage"] == 1 for x in of(r1, 0xF101)), "setup period can be paused (timeout)")
ts = [s["timestamp"] for s in stats if s["timestamp"]]
check(ts and ts[0] >= 1700000000, "SyncTimeStamp follows the TIME command")
check(max(s["remain"] for s in stats if s["progress"] == 2) == 15, "init period is 15 s")

ev = of(r1, 0xF102)
hits = [e for e in ev if e["kind"] == "hit"]
check([(e["robot"], e["detail"], e["hp"]) for e in hits] == [(0, 1, 180), (0, 0x82, 160), (1, 0x40, 198)],
      "17 mm hits -20 (UI armor 1, button BTN2), collision -2")
hurts = of(r1, 0x0206)
check([(h["armor"], h["reason"]) for h in hurts] == [(1, 0), (2, 0)],
      "0x0206 only for the link robot's armor hits")
shots = [e for e in ev if e["kind"] == "shot"]
check(sum(e["robot"] == 0 for e in shots) == 9 and sum(e["robot"] == 1 for e in shots) == 1,
      "red fires 9, its 10th is refused while heat-locked; blue fires 1, then refused")
locks = [(e["robot"], arcref.LOCKS.get(e["detail"])) for e in ev if e["kind"] == "locked"]
check((0, "heat") in locks, "red launcher locks at heat 90 > 80")
check((1, "speed_20s") in locks, "blue 31 m/s (limit 25, +6) locks the launcher for 20 s")
unlocks = [(e["robot"], e["detail"]) for e in ev if e["kind"] == "unlocked"]
check((0, 1) in unlocks, "red heat lock clears once heat reaches 0")
check(any(r == 1 for r, _ in unlocks), "blue speed lock clears after 20 s")
check(len(of(r1, 0x0207)) == 9 and abs(of(r1, 0x0207)[0]["speed"] - 25.0) < 1e-6,
      "0x0207 for each link-robot shot")
yel = [(e["robot"], e["detail"], e["hp"]) for e in ev if e["kind"] == "yellow"]
check(yel == [(0, 1, 130), (0, 2, 70)], "yellow -15 % max HP, repeat within 30 s doubles to -30 %")
warn1 = [w for w in of(r1, 0x0104) if w["level"]]
check(warn1 and warn1[-1] == {"level": 2, "offender": 3, "count": 2} and len(warn1) > 10,
      "0x0104 reports red_3's 2nd yellow, repeated at 1 Hz")
check(not any(w["offender"] == 103 for w in of(d, 0x0104)), "no 0x0104 for the blue (non-link) team")
check(any(e["kind"] == "chassis_cut" and e["robot"] == 1 for e in ev), "blue chassis cut after buffer drains")
srv1 = of(r1, 0xF101)
check(any(not x["robots"][1]["chassis_on"] for x in srv1), "chassis output reported off during the cut")
last = srv1[-1]
red, blue = last["robots"]
check((red["hp"], blue["hp"]) == (70, 198), f"final HP red 70 / blue 198 (got {red['hp']} / {blue['hp']})")
check(red["allowance"] == 1 and blue["allowance"] == 9, "projectile allowance counts down")
check(last["winner"] == 2 and last["win_reason"] == "more_hp", "time-out: blue wins on remaining HP")
check(of(r1, 0x0002) == [{"winner": 2}], "0x0002 winner blue")
ph = of(r1, 0x0202)
check(85 <= max(p["heat_17"] for p in ph) <= 90, "0x0202 barrel heat peaks near 90 (sampled at 10 Hz)")
rs = of(r1, 0x0201)
check(rs[-1]["robot_id"] == 3 and rs[-1]["max_hp"] == 200 and rs[-1]["heat_limit"] == 80,
      "0x0201 is red_3 with the configured limits")
check(any(x["outputs"] & 4 == 0 for x in rs if x["hp"] > 0), "0x0201 shooter output off while locked")
check(of(r1, 0x0003)[-1]["ally_3"] == 70, "0x0003 ally_3 = link robot HP")

# ---------------------------------------------------------------- round 2
print("round 2")
ev2 = of(r2, 0xF102)
yel2 = [(e["robot"], e["detail"], e["hp"]) for e in ev2 if e["kind"] == "yellow"]
check(yel2 == [(1, 1, 170), (1, 2, 110), (1, 3, 0)], "blue yellows: -30, -60, third is a red card")
check(any(e["kind"] == "red" and e["robot"] == 1 and e["detail"] == 1 for e in ev2),
      "red card event marks it as from three yellows")
last2 = of(r2, 0xF101)[-1]
check(last2["winner"] == 1 and last2["win_reason"] == "defeat", "blue defeated in battle: red wins at once")
check(of(r2, 0x0002) == [{"winner": 1}], "0x0002 winner red")
check(last2["rx_ok"] == 27 and last2["rx_err"] == 1, f"rx counters 27 ok / 1 bad ({last2['rx_ok']}/{last2['rx_err']})")

print("PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
