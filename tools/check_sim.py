#!/usr/bin/env python3
"""Decode hw/sim/out/tx_bytes.hex and check it against the four rounds in
hw/sim/tb_arc_ref.v (two 1v1, two 3v3; ARCC 2026 rules). Exits non-zero on
any failure."""
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

SIZES = {0x0001: 11, 0x0002: 1, 0x0003: 16, 0x0101: 4, 0x0104: 3, 0x0201: 13, 0x0202: 14,
         0x0204: 8, 0x0208: 8, 0x0209: 5, 0x0206: 1, 0x0207: 7, 0xF101: arcref.SRV_LEN, 0xF102: 5}
check(dec.bad == 0, "every frame passes CRC8 and CRC16")
check(len(dec.buf) < 230, "no trailing garbage")
seqs = [s for _, s, _ in frames]
check(all((b - a) % 256 == 1 for a, b in zip(seqs, seqs[1:])), "seq increments by one")
check(all(len(p) == SIZES.get(c, len(p)) for c, _, p in frames), "payload sizes match the 2026 protocol")

d = [(c, arcref.decode_payload(c, p)) for c, _, p in frames]

# Rounds end at each 0x0002; a round's final state is the next settlement 0xF101.
ends = [i for i, (c, _) in enumerate(d) if c == 0x0002]
check(len(ends) == 4, f"four rounds played ({len(ends)})")
starts = [0] + [next(i for i, (c, x) in enumerate(d) if i > e and c == 0x0001 and x["progress"] != 5)
                for e in ends[:-1]]
rounds = [d[s:e] for s, e in zip(starts, starts[1:] + [len(d)])]
finals = [next(x for c, x in d[e:] if c == 0xF101 and x["stage"] == 5) for e in ends]


def of(seq, cmd):
    return [x for c, x in seq if c == cmd]


def events(seq, kind=None):
    return [e for e in of(seq, 0xF102) if kind is None or e["kind"] == kind]


RED_INF, BLUE_INF = 1, 4

# ------------------------------------------------------------- 1v1 round 1
print("1v1 round 1")
r1 = rounds[0]
progress = []
for s in of(r1, 0x0001):
    if not progress or progress[-1] != s["progress"]:
        progress.append(s["progress"])
check(progress == [0, 1, 2, 3, 4, 5],
      f"idle, setup, init, countdown, battle, then settlement ({progress})")
check(any(x["paused"] and x["stage"] == 1 for x in of(r1, 0xF101)), "setup period can be paused (timeout)")
ts = [s["timestamp"] for s in of(r1, 0x0001) if s["timestamp"]]
check(ts and ts[0] >= 1700000000, "SyncTimeStamp follows the TIME command")
check(max(s["remain"] for s in of(r1, 0x0001) if s["progress"] == 2) == 15, "init period is 15 s")
check(all(not x["mode3"] for x in of(r1, 0xF101)), "1v1 mode")
hits = events(r1, "hit")
check([(e["robot"], e["detail"], e["hp"]) for e in hits]
      == [(RED_INF, 1, 180), (RED_INF, 0x82, 160), (BLUE_INF, 0x40, 198)],
      "17 mm hits -20 (UI armor 1, button BTN2), collision -2")
check([(h["armor"], h["reason"]) for h in of(r1, 0x0206)] == [(1, 0), (2, 0)],
      "0x0206 only for the link robot's armor hits")
shots = events(r1, "shot")
check(sum(e["robot"] == RED_INF for e in shots) == 9 and sum(e["robot"] == BLUE_INF for e in shots) == 1,
      "red fires 9 and is refused while heat-locked; blue fires 1 and is then refused")
locks = [(e["robot"], arcref.LOCKS.get(e["detail"])) for e in events(r1, "locked")]
check((RED_INF, "heat") in locks, "red launcher locks at heat 90 > 80")
check((BLUE_INF, "speed_20s") in locks, "blue 31 m/s (limit 25, +6) locks the launcher for 20 s")
unlocks = [e["robot"] for e in events(r1, "unlocked")]
check(RED_INF in unlocks and BLUE_INF in unlocks, "heat lock clears at 0, speed lock after 20 s")
check(len(of(r1, 0x0207)) == 9 and abs(of(r1, 0x0207)[0]["speed"] - 25.0) < 1e-6
      and of(r1, 0x0207)[0]["bullet_type"] == 1, "0x0207 for each link-robot 17 mm shot")
yel = [(e["robot"], e["detail"], e["hp"]) for e in events(r1, "yellow")]
check(yel == [(RED_INF, 1, 130), (RED_INF, 2, 70)], "yellow -15 % max HP, repeat within 30 s -30 %")
warn1 = [w for w in of(r1, 0x0104) if w["level"]]
check(warn1 and warn1[-1] == {"level": 2, "offender": 3, "count": 2} and len(warn1) > 10,
      "0x0104 reports red_3's 2nd yellow, repeated at 1 Hz")
check(any(e["kind"] == "chassis_cut" and e["robot"] == BLUE_INF for e in events(r1)),
      "blue chassis cut after the buffer drains")
check(any(not x["robots"][BLUE_INF]["chassis_on"] for x in of(r1, 0xF101)), "chassis output off during the cut")
f1 = finals[0]
red, blue = f1["robots"][RED_INF], f1["robots"][BLUE_INF]
check((red["hp"], blue["hp"]) == (70, 198), f"final HP red 70 / blue 198 ({red['hp']} / {blue['hp']})")
check(red["allowance"] == 1 and blue["allowance"] == 9, "projectile allowance counts down")
check(f1["winner"] == 2 and f1["win_reason"] == "more_hp", "time-out: blue wins on remaining HP")
check(85 <= max(p["heat_17"] for p in of(r1, 0x0202)) <= 90, "0x0202 17 mm heat peaks near 90")
rs = of(r1, 0x0201)
check(rs[-1]["robot_id"] == 3 and rs[-1]["max_hp"] == 200 and rs[-1]["heat_limit"] == 80,
      "0x0201 is red_3 with the configured limits")
check(any(x["outputs"] & 4 == 0 for x in rs if x["hp"] > 0), "0x0201 shooter output off while locked")
check(of(r1, 0x0003)[-1]["ally_3"] == 70, "0x0003 ally_3 = link robot HP")
check(all(not f1["robots"][k]["fielded"] for k in (0, 2, 3, 5)), "only the Infantry slots are fielded")

al1 = of(r1, 0x0208)
check(al1 and al1[-1]["allow_17"] == 1 and al1[-1]["gold"] == 0, "0x0208 reports the link robot's 17 mm allowance (1v1: no gold)")
check(all(x["raw"] == 0 for x in of(r1, 0x0209)), "0x0209 has no RFID cards in 1v1")

# ------------------------------------------------------------- 1v1 round 2
print("1v1 round 2")
r2 = rounds[1]
yel2 = [(e["robot"], e["detail"], e["hp"]) for e in events(r2, "yellow")]
check(yel2 == [(BLUE_INF, 1, 170), (BLUE_INF, 2, 110), (BLUE_INF, 3, 0)], "blue: -30, -60, third is a red card")
check(any(e["kind"] == "red" and e["detail"] == 1 for e in events(r2)), "red card marked as from three yellows")
check(finals[1]["winner"] == 1 and finals[1]["win_reason"] == "defeat", "defeat in battle: red wins at once")
check(not any(w["offender"] == 103 for w in of(d, 0x0104)), "no 0x0104 for the non-link team")

# ------------------------------------------------------------- 3v3 round 1
print("3v3 round 1")
r3 = rounds[2]
srv3 = [x for x in of(r3, 0xF101) if x["mode3"]]
check(srv3 and all(rb["fielded"] for rb in srv3[-1]["robots"]), "3v3 mode, six robots fielded")
battle = [x for x in srv3 if x["stage"] == 4]
check(battle[0]["teams"][0]["coins"] == 200 and battle[0]["teams"][1]["coins"] == 200, "200 gold each at the start")
ex = [(e["robot"], e["detail"], e["hp"]) for e in events(r3, "exchange")]
check(ex == [(1, 0, 100), (0, 1, 0), (0, 0, 5)],
      "exchange: 100 x 17 mm ok, Hero refused outside the zone, then 5 x 42 mm ok")
ev3 = events(r3)
kinds3 = [(e["robot"], e["kind"]) for e in ev3]
i_imm = kinds3.index((BLUE_INF, "immune"))
i_shot = kinds3.index((0, "shot"))
check(i_imm < i_shot, "42 mm hit before the Hero has fired does nothing")
h42 = [e for e in events(r3, "hit") if e["detail"] & 0x20]
check(len(h42) == 1 and h42[0]["robot"] == BLUE_INF and h42[0]["hp"] == 150, "42 mm hit after the Hero fires: -200")
check(any(e["kind"] == "capture" and e["detail"] == 2 for e in ev3), "blue Sentry takes the capture point")
check(of(r3, 0x0101) and of(r3, 0x0101)[-1]["center"] == 2, "0x0101 shows the capture point held by the enemy")
vps = [x["teams"][0]["vp"] for x in battle]
check(any(b == a - 20 for a, b in zip(vps, vps[1:])), "defeat costs 20 VP")
check(any(b == a - 1 for a, b in zip(vps, vps[1:])), "enemy holding the point drains 1 VP/s")
resp = events(r3, "respawn")
check(len(resp) == 1 and resp[0]["robot"] == RED_INF and resp[0]["hp"] == 70, "respawn at 20 % (70 of 350)")
i_resp_d = next(i for i, (c, x) in enumerate(r3) if c == 0xF102 and x["kind"] == "respawn")
after = [x for c, x in r3[i_resp_d:] if c == 0xF101]
check(after and after[0]["robots"][RED_INF]["weakened"] and after[0]["robots"][RED_INF]["invincible"],
      "respawned robot is weakened and invincible")
i_resp = kinds3.index((RED_INF, "respawn"))
check(not any(k == (RED_INF, "shot") or k == (RED_INF, "hit") for k in kinds3[i_resp:i_resp + 3]),
      "weakened robot cannot fire; invincible robot takes no hit")
heal = [x["robots"][RED_INF]["hp"] for x in battle]
check(any(b - a == 88 for a, b in zip(heal, heal[1:])), "resupply zone heals 25 % (88) per second")
check(of(r3, 0x0204) and max(b["recovery"] for b in of(r3, 0x0204)) == 25, "0x0204 reports 25 % healing in the zone")
yt = [(e["robot"], e["hp"]) for e in events(r3, "yellow_team")]
check([e["hp"] for e in events(r3, "yellow") if e["robot"] == 2] == [180] and (0, 332) in yt and len(yt) == 2,
      "Sentry yellow: -60 to it, -5 % to both alive teammates")
check(any(not x["robots"][2]["chassis_on"] for x in battle if x["robots"][2]["hp"] == 180),
      "Sentry yellow cuts its chassis")
coins = [(x["remain"], x["teams"][0]["coins"], x["teams"][1]["coins"]) for x in battle]
check(any(c[1] - p[1] == 300 and c[2] - p[2] == 300 for p, c in zip(coins, coins[1:])), "+300 gold each at 0:59")
check(any(c[1] - p[1] == 200 and c[2] == p[2] for p, c in zip(coins, coins[1:])),
      "+200 gold to the trailing team when the VP gap reaches 70")
f3 = finals[2]
check(f3["winner"] == 2 and f3["win_reason"] == "more_vp", "time-out: blue wins on Victory Points")
check(f3["teams"][1]["damage"] == 606 and f3["teams"][0]["damage"] == 200, "attack damage dealt is tracked")
ally = of(r3, 0x0003)[-1]
check(ally["ally_1"] == f3["robots"][0]["hp"] and ally["ally_7"] == f3["robots"][2]["hp"], "0x0003 has red Hero and Sentry HP")

al3 = [x for x in of(r3, 0x0208)]
check(any(x["allow_17"] == 100 and x["gold"] == 50 for x in al3), "0x0208 shows 100 projectiles and the team gold (50 after both exchanges)")
check(any(x["resupply_card"] for x in of(r3, 0x0209)) and not any(x["center_card"] for x in of(r3, 0x0209)),
      "0x0209 shows the resupply zone card for the link robot")

# ------------------------------------------------------------- 3v3 round 2
print("3v3 round 2")
r4 = rounds[3]
f4 = finals[3]
check(any(e["kind"] == "red" and e["robot"] == 5 for e in events(r4)) and not events(r4, "respawn")
      and f4["robots"][5]["hp"] == 0 and not f4["robots"][5]["respawning"],
      "red-carded Sentry is ejected and does not respawn")
check([x["teams"][1]["vp"] for x in of(r4, 0xF101) if x["stage"] == 4][-1] == 180, "ejection costs 20 VP")
check(f4["winner"] == 2 and f4["win_reason"] == "forfeit" and f4["teams"][0]["vp"] == 0,
      "3v3 forfeit: red VP 0, blue wins")
check(f4["rx_ok"] == 82 and f4["rx_err"] == 1, f"rx counters 82 ok / 1 bad ({f4['rx_ok']}/{f4['rx_err']})")

# ------------------------------------------------------------- robot link
print("robot UART link")
rpath = path.parent / "robot_bytes.hex"
rdata = bytes(int(line, 16) for line in rpath.read_text().split()) if rpath.exists() else b""
rdec = arcref.Decoder()
rframes = rdec.feed(rdata)
real = [(c, s, p) for c, s, p in frames if c < 0xF000]
check(rframes and rdec.bad == 0, f"robot UART carries {len(rframes)} frames, all passing CRC")
check(not any(c >= 0xF000 for c, _, _ in rframes), "robot UART carries no console (0xF1xx) frames")
check(rframes == real[:len(rframes)] and len(rframes) >= len(real) - 5,
      "robot UART carries every real referee frame, in order and byte for byte")
check({0x0001, 0x0003, 0x0201, 0x0202, 0x0206, 0x0207, 0x0208} <= {c for c, _, _ in rframes},
      "robot sees game status, ally HP, robot status, heat, hurt, shoot and allowance frames")

print("PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
