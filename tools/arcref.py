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
EVENTS = {1: "hit", 2: "shot", 3: "locked", 4: "chassis_cut", 5: "yellow", 6: "red",
          7: "forfeit", 8: "kill", 9: "revive", 10: "disconnect", 11: "reconnect",
          12: "offline_hp", 13: "unlocked", 14: "yellow_both"}
LOCKS = {1: "heat", 2: "heat_round", 3: "speed_15s", 4: "speed_20s", 5: "speed_round", 6: "ammo"}
WIN_REASONS = {0: "none", 1: "defeat", 2: "more_hp", 3: "first_damage", 4: "more_shots",
               5: "first_shot", 6: "tie", 7: "forfeit"}

ROBOT_FIELDS = ("hp", "max_hp", "heat", "heat_limit", "buffer", "power", "power_limit",
                "allowance", "shots", "yellow", "flags", "lock_s", "chassis_ds")
FLAG_BITS = ("alive", "red_card", "shooter_on", "chassis_on", "gimbal_on", "disconnected",
             "heat_locked", "speed_locked")


def decode_payload(cmd, p):
    """Turn a payload into a dict. Unknown commands return {'raw': hex}."""
    if cmd == 0x0001:
        b, remain, ts = struct.unpack("<BHQ", p)
        return {"game_type": b & 0xF, "progress": b >> 4, "remain": remain, "timestamp": ts}
    if cmd == 0x0002:
        return {"winner": p[0]}
    if cmd == 0x0003:
        hp = struct.unpack("<8H", p)
        return {"ally_3": hp[2], "all": hp}
    if cmd == 0x0104:
        return dict(zip(("level", "offender", "count"), p))
    if cmd == 0x0201:
        f = struct.unpack("<BBHHHHHB", p)
        return dict(zip(("robot_id", "level", "hp", "max_hp", "cooling", "heat_limit",
                         "power_limit", "outputs"), f))
    if cmd == 0x0202:
        f = struct.unpack("<HHIHHH", p)
        return {"buffer_j": f[3], "heat_17": f[4], "heat_42": f[5]}
    if cmd == 0x0206:
        return {"armor": p[0] & 0xF, "reason": p[0] >> 4}
    if cmd == 0x0207:
        f = struct.unpack("<BBBf", p)
        return dict(zip(("bullet_type", "shooter", "freq", "speed"), f))
    if cmd == 0xF101:
        stage, flags, remain, winner, reason, link, gtype = struct.unpack_from("<BBHBBBB", p, 0)
        robots = []
        for r in range(2):
            d = dict(zip(ROBOT_FIELDS, struct.unpack_from("<9H4B", p, 8 + 22 * r)))
            d.update({n: bool(d["flags"] >> i & 1) for i, n in enumerate(FLAG_BITS)})
            robots.append(d)
        rx_ok, rx_err, combat, cooling, dmg, setup, speed = struct.unpack_from("<7H", p, 52)
        return {"stage": stage, "paused": bool(flags & 1), "first_dmg": flags >> 1 & 3,
                "first_shot": flags >> 3 & 3, "remain": remain, "winner": winner,
                "win_reason": WIN_REASONS.get(reason, reason), "link": link,
                "game_type": gtype, "robots": robots, "rx_ok": rx_ok, "rx_err": rx_err,
                "combat_time": combat, "cooling": cooling, "hit_dmg": dmg,
                "setup_time": setup, "speed_limit": speed}
    if cmd == 0xF102:
        robot, kind, detail, hp = struct.unpack("<BBBH", p)
        return {"robot": robot, "kind": EVENTS.get(kind, kind), "detail": detail, "hp": hp}
    return {"raw": p.hex()}


# ---------------------------------------------------------------- commands
def cmd_game(action):
    """action: 1 setup, 2 skip to init, 3 pause, 4 resume, 5 end, 6 reset"""
    return encode(0xF001, bytes([action]))


def cmd_config(game_type=5, link=0, combat=120, max_hp=200, heat_limit=80, cooling=12,
               power_limit=120, hit_dmg=20, setup=120, speed_limit=25, allowance=200):
    """Defaults are the ARCC 2026 1v1 Infantry."""
    return encode(0xF002, struct.pack("<BB9H", game_type, link, combat, max_hp, heat_limit,
                                      cooling, power_limit, hit_dmg, setup, speed_limit,
                                      allowance))


def cmd_hit(robot, armor, kind=0):
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
