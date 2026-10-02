"""Python reference for the ARC referee link protocol (see docs/protocol.md).

Used by the simulation checker and the command-line tool. Mirrors
web/js/protocol.js.
"""
import struct


def crc8(data, crc=0xFF):
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8C if crc & 1 else crc >> 1
    return crc


def crc16(data, crc=0xFFFF):
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc


def encode(cmd_id, payload=b"", seq=0):
    head = bytes([0xA5]) + struct.pack("<HB", len(payload), seq & 0xFF)
    head += bytes([crc8(head)])
    body = head + struct.pack("<H", cmd_id) + bytes(payload)
    return body + struct.pack("<H", crc16(body))


class Decoder:
    """Streaming decoder. feed() returns complete frames as (cmd_id, seq, payload)."""

    def __init__(self):
        self.buf = bytearray()
        self.bad = 0

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(0xA5)
            if i < 0:
                self.buf.clear()
                return out
            del self.buf[:i]
            if len(self.buf) < 5:
                return out
            if crc8(self.buf[:4]) != self.buf[4]:
                self.bad += 1
                del self.buf[:1]
                continue
            n = self.buf[1] | self.buf[2] << 8
            total = 9 + n
            if len(self.buf) < total:
                return out
            frame = bytes(self.buf[:total])
            if crc16(frame[:-2]) != struct.unpack_from("<H", frame, total - 2)[0]:
                self.bad += 1
                del self.buf[:1]
                continue
            del self.buf[:total]
            out.append((struct.unpack_from("<H", frame, 5)[0], frame[3], frame[7:7 + n]))


STAGES = ["not started", "setup", "init (15 s)", "countdown", "battle", "settlement"]
SLOTS = ["red hero", "red infantry", "red sentry", "blue hero", "blue infantry", "blue sentry"]
ROBOT_IDS = [1, 3, 7, 101, 103, 107]
EVENTS = {1: "hit", 2: "shot", 3: "locked", 4: "chassis_cut", 5: "yellow", 6: "red",
          7: "forfeit", 8: "kill", 9: "revive", 10: "disconnect", 11: "reconnect",
          12: "offline_hp", 13: "unlocked", 14: "yellow_both", 15: "exchange", 16: "immune",
          17: "respawn", 18: "capture", 19: "yellow_team"}
LOCKS = {1: "heat", 2: "heat_round", 3: "speed_15s", 4: "speed_20s", 5: "speed_round", 6: "ammo"}
WIN_REASONS = {0: "none", 1: "defeat", 2: "more_hp", 3: "first_damage", 4: "more_shots",
               5: "first_shot", 6: "tie", 7: "forfeit", 8: "vp_zero", 9: "more_vp",
               10: "more_damage", 11: "more_total_hp"}

ROBOT_FIELDS = ("hp", "max_hp", "heat10", "heat_limit", "buffer10", "power", "power_limit",
                "allowance", "shots", "cooling", "speed_limit", "yellow", "flags", "flags2",
                "chassis_ticks", "speed_lock_ticks", "timer_ticks")
FLAG_BITS = ("alive", "red_card", "shooter_on", "chassis_on", "gimbal_on", "disconnected",
             "heat_locked", "speed_locked")
FLAG2_BITS = ("fielded", "cal42", "invincible", "weakened", "respawning")
SRV_LEN = 212


def decode_payload(cmd, p):
    """Turn a payload into a dict. Unknown commands return {'raw': hex}."""
    if cmd == 0x0001:
        b, remain, ts = struct.unpack("<BHQ", p)
        return {"game_type": b & 0xF, "progress": b >> 4, "remain": remain, "timestamp": ts}
    if cmd == 0x0002:
        return {"winner": p[0]}
    if cmd == 0x0003:
        hp = struct.unpack("<8H", p)
        return {"ally_1": hp[0], "ally_3": hp[2], "ally_7": hp[5], "all": hp}
    if cmd == 0x0101:
        v = struct.unpack("<I", p)[0]
        return {"resupply": v >> 2 & 1, "center": v >> 23 & 3, "raw": v}
    if cmd == 0x0104:
        return dict(zip(("level", "offender", "count"), p))
    if cmd == 0x0201:
        f = struct.unpack("<BBHHHHHB", p)
        return dict(zip(("robot_id", "level", "hp", "max_hp", "cooling", "heat_limit",
                         "power_limit", "outputs"), f))
    if cmd == 0x0202:
        f = struct.unpack("<HHIHHH", p)
        return {"buffer_j": f[3], "heat_17": f[4], "heat_42": f[5]}
    if cmd == 0x0204:
        f = struct.unpack("<BHBBHB", p)
        return dict(zip(("recovery", "cooling", "defence", "vulnerability", "attack", "energy"), f))
    if cmd == 0x0206:
        return {"armor": p[0] & 0xF, "reason": p[0] >> 4}
    if cmd == 0x0207:
        f = struct.unpack("<BBBf", p)
        return dict(zip(("bullet_type", "shooter", "freq", "speed"), f))
    if cmd == 0xF101:
        stage, flags, remain, winner, reason, link, gtype = struct.unpack_from("<BBHBBBB", p, 0)
        teams = []
        for t in range(2):
            vp, coins, dmg, tf = struct.unpack_from("<3HB", p, 8 + 8 * t)
            teams.append({"vp": vp, "coins": coins, "damage": dmg, "hero_live": bool(tf & 1)})
        robots = []
        for r in range(6):
            d = dict(zip(ROBOT_FIELDS, struct.unpack_from("<11H4B2H", p, 24 + 30 * r)))
            d.update({n: bool(d["flags"] >> i & 1) for i, n in enumerate(FLAG_BITS)})
            d.update({n: bool(d["flags2"] >> i & 1) for i, n in enumerate(FLAG2_BITS)})
            d["zone"] = d["flags2"] >> 5 & 3
            d["heat"] = d["heat10"] // 10
            d["buffer"] = d["buffer10"] // 10
            robots.append(d)
        rx_ok, rx_err, combat, setup = struct.unpack_from("<4H", p, 204)
        return {"stage": stage, "paused": bool(flags & 1), "first_dmg": flags >> 1 & 3,
                "first_shot": flags >> 3 & 3, "capture": flags >> 5 & 3, "mode3": bool(flags & 0x80),
                "remain": remain, "winner": winner, "win_reason": WIN_REASONS.get(reason, reason),
                "link": link, "game_type": gtype, "teams": teams, "robots": robots,
                "rx_ok": rx_ok, "rx_err": rx_err, "combat_time": combat, "setup_time": setup}
    if cmd == 0xF102:
        robot, kind, detail, value = struct.unpack("<BBBH", p)
        return {"robot": robot, "kind": EVENTS.get(kind, kind), "detail": detail, "hp": value}
    return {"raw": p.hex()}


# ---------------------------------------------------------------- commands
def cmd_game(action):
    """action: 1 setup, 2 skip to init, 3 pause, 4 resume, 5 end, 6 reset"""
    return encode(0xF001, bytes([action]))


def cmd_config(game_type=5, link=1, combat=120, setup=120):
    """game_type 5 = 1v1, 4 = 3v3; link is the slot (0-5) whose view the real frames give."""
    return encode(0xF002, struct.pack("<BBHH", game_type, link, combat, setup))


# ARCC 2026 robot presets: (fielded/caliber flags, max HP, heat limit, cooling, power, speed, ammo)
PRESETS = {
    "1v1_infantry": (1, 200, 80, 12, 120, 25, 200),
    "hero": (3, 350, 200, 24, 100, 15, 0),
    "infantry_hp_cooldown": (1, 350, 88, 24, 75, 25, 0),
    "infantry_power_burst": (1, 300, 230, 14, 90, 25, 0),
    "sentry": (1, 400, 260, 30, 100, 25, 750),
    "absent": (0, 200, 80, 12, 120, 25, 0),
}


def cmd_robot(slot, flags, max_hp, heat_limit, cooling, power_limit, speed_limit, allowance):
    """flags bit0 fielded, bit1 42 mm launcher."""
    return encode(0xF009, struct.pack("<BB6H", slot, flags, max_hp, heat_limit, cooling,
                                      power_limit, speed_limit, allowance))


def cmd_zone(slot, zone):
    """zone: 0 none, 1 resupply zone, 2 capture point"""
    return encode(0xF00A, bytes([slot, zone]))


def cmd_exchange(slot, projectiles):
    return encode(0xF00B, struct.pack("<BH", slot, projectiles))


def cmd_hit(robot, armor, kind=0):  # robot = slot 0-5
    """kind: 0 17 mm, 1 collision, 2 42 mm"""
    return encode(0xF003, bytes([robot, armor, kind]))


def cmd_shoot(robot, freq=5, speed=25.0):
    return encode(0xF004, struct.pack("<BBfH", robot, freq, speed, round(speed * 10)))


def cmd_penalty(robot, level):
    """level: 1 both teams yellow, 2 yellow, 3 red, 4 forfeit"""
    return encode(0xF005, bytes([robot, level]))


def cmd_life(robot, action):
    """action: 0 kill, 1 revive, 2 disconnect, 3 reconnect"""
    return encode(0xF006, bytes([robot, int(action)]))


def cmd_power(robot, watts):
    return encode(0xF007, struct.pack("<BH", robot, watts))


def cmd_time(unix):
    return encode(0xF008, struct.pack("<I", unix))
