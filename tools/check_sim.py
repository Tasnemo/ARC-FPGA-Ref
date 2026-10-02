#!/usr/bin/env python3
"""Decode hw/sim/out/tx_bytes.hex and check it against the scenario in
hw/sim/tb_arc_ref.v. Exits non-zero on any failure."""
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

check(dec.bad == 0, "every frame passes CRC8 and CRC16")
check(len(dec.buf) < 64, "no trailing garbage")
seqs = [s for _, s, _ in frames]
check(all((b - a) % 256 == 1 for a, b in zip(seqs, seqs[1:])), "seq increments by one")

d = [(c, arcref.decode_payload(c, p)) for c, _, p in frames]
events = [x for c, x in d if c == 0xF102]
hurts = [x for c, x in d if c == 0x0206]
stats = [x for c, x in d if c == 0x0001]
srv = [x for c, x in d if c == 0xF101]
warns = [x for c, x in d if c == 0x0104]
shots = [x for c, x in d if c == 0x0207]
results = [x for c, x in d if c == 0x0002]

progress = []
for s in stats:
    if not progress or progress[-1] != s["progress"]:
        progress.append(s["progress"])
check(progress == [0, 2, 3, 4, 5], f"stage sequence 0,2,3,4,5 (got {progress})")
check(all(s["game_type"] == 5 for s in stats[1:]), "game_type = 5 after config")
ts = [s["timestamp"] for s in stats if s["timestamp"]]
check(ts and ts[0] >= 1700000000, "SyncTimeStamp follows the TIME command")
countdown = [s["remain"] for s in stats if s["progress"] == 2]
check(countdown and max(countdown) == 15, "self-check starts at 15 s")

ev_kinds = [(e["robot"], e["kind"]) for e in events]
first_hit = next((e for e in events if e["kind"] == "hit"), None)
check(first_hit and first_hit["robot"] == 0 and first_hit["hp"] == 90 and first_hit["detail"] == 1,
      "UI hit on red armor 1 -> HP 90")
btn_hit = next((e for e in events if e["kind"] == "hit" and e["detail"] & 0x80), None)
check(btn_hit and btn_hit["detail"] == 0x82 and btn_hit["hp"] == 80,
      "button BTN2 hit on red armor 2 -> HP 80")
check(sum(1 for r, k in ev_kinds if k == "shot" and r == 0) == 7, "7 shot events")
check(len(shots) == 7 and abs(shots[0]["speed"] - 25.0) < 1e-6 and shots[0]["freq"] == 5,
      "7 x 0x0207 at 25.0 m/s")
check(any(e["kind"] == "overheat" and e["robot"] == 0 for e in events),
      "red overheats after 7 shots (70 > 50)")
check(any(h["reason"] == 3 for h in hurts), "0x0206 reason 3 (heat) sent to link robot")
check([(h["armor"], h["reason"]) for h in hurts[:2]] == [(1, 0), (2, 0)],
      "0x0206 armor hits on plates 1 then 2")
check(any(e["kind"] == "yellow" and e["robot"] == 1 for e in events), "blue yellow card event")
check(warns == [{"level": 2, "offender": 3, "count": 1}],
      "exactly one 0x0104 (red yellow card; blue is not the link robot)")
check(any(e["kind"] == "overpower" and e["robot"] == 1 for e in events),
      "blue overpowers at 100 W > 60 W limit")
check(not any(h["reason"] == 4 for h in hurts), "no 0x0206 for blue (not link robot)")

last = srv[-1]
red, blue = last["robots"]
check(last["rx_ok"] == 14 and last["rx_err"] == 1, "rx counters 14 ok / 1 bad")
check(last["stage"] == 5, "match ended in settlement")
exp_winner = 1 if red["hp"] > blue["hp"] else 2 if blue["hp"] > red["hp"] else 0
check(results and results[-1]["winner"] == exp_winner,
      f"0x0002 winner {exp_winner} (red {red['hp']} vs blue {blue['hp']})")
check(red["yellow"] == 1 and blue["yellow"] == 1, "yellow counts in server state")

rs = [x for c, x in d if c == 0x0201]
check(rs and rs[-1]["robot_id"] == 3 and rs[-1]["max_hp"] == 100, "0x0201 is for red_3 with 100 max HP")
ph = [x for c, x in d if c == 0x0202]
check(ph and max(p["heat_17_1"] for p in ph) == 70, "0x0202 peak barrel heat 70")
hp3 = [x for c, x in d if c == 0x0003]
check(hp3 and hp3[-1]["red_3"] == red["hp"] and hp3[-1]["blue_3"] == blue["hp"],
      "0x0003 HP matches server state")

print(f"\nred HP {red['hp']}, blue HP {blue['hp']}")
print("PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
