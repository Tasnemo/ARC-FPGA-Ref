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


STAGES = ["not started", "preparation", "self-check", "countdown", "combat", "settlement"]
EVENTS = {1: "hit", 2: "shot", 3: "overheat", 4: "overpower", 5: "yellow",
          6: "red", 7: "forfeit", 8: "kill", 9: "revive"}

ROBOT_FIELDS = ("hp", "max_hp", "heat", "heat_limit", "buffer", "power",
                "power_limit", "yellow", "flags")


def decode_payload(cmd, p):
    """Turn a payload into a dict. Unknown commands return {'raw': hex}."""
    if cmd == 0x0001:
        b, remain, ts = struct.unpack("<BHQ", p)
        return {"game_type": b & 0xF, "progress": b >> 4, "remain": remain, "timestamp": ts}
    if cmd == 0x0002:
        return {"winner": p[0]}
    if cmd == 0x0003:
        hp = struct.unpack("<16H", p)
        return {"red_3": hp[2], "blue_3": hp[10], "all": hp}
    if cmd == 0x0104:
        return dict(zip(("level", "offender", "count"), p))
    if cmd == 0x0201:
        f = struct.unpack("<BBHHHHHB", p)
        d = dict(zip(("robot_id", "level", "hp", "max_hp", "cooling", "heat_limit",
                      "power_limit", "outputs"), f))
        return d
    if cmd == 0x0202:
        f = struct.unpack("<HHfHHHH", p)
        return dict(zip(("voltage_mv", "current_ma", "power_w", "buffer_j",
                         "heat_17_1", "heat_17_2", "heat_42"), f))
    if cmd == 0x0206:
        return {"armor": p[0] & 0xF, "reason": p[0] >> 4}
    if cmd == 0x0207:
        f = struct.unpack("<BBBf", p)
        return dict(zip(("bullet_type", "shooter", "freq", "speed"), f))
    if cmd == 0xF101:
        stage, flags, remain, winner, link, gtype = struct.unpack_from("<BBHBBB", p, 0)
        robots = [dict(zip(ROBOT_FIELDS, struct.unpack_from("<7HBB", p, 7 + 16 * r)))
                  for r in range(2)]
        rx_ok, rx_err, combat, cooling, dmg = struct.unpack_from("<5H", p, 39)
        return {"stage": stage, "paused": bool(flags & 1), "remain": remain,
                "winner": winner, "link": link, "game_type": gtype, "robots": robots,
                "rx_ok": rx_ok, "rx_err": rx_err, "combat_time": combat,
                "cooling": cooling, "hit_dmg": dmg}
    if cmd == 0xF102:
        robot, kind, detail, hp = struct.unpack("<BBBH", p)
        return {"robot": robot, "kind": EVENTS.get(kind, kind), "detail": detail, "hp": hp}
    return {"raw": p.hex()}


# ---------------------------------------------------------------- commands
def cmd_game(action):
    """action: 1 prep, 2 start, 3 pause, 4 resume, 5 end, 6 reset"""
    return encode(0xF001, bytes([action]))


def cmd_config(game_type=5, link=0, combat=180, max_hp=200, heat_limit=100,
               cooling=20, power_limit=60, hit_dmg=10):
    return encode(0xF002, struct.pack("<BB6H", game_type, link, combat, max_hp,
                                      heat_limit, cooling, power_limit, hit_dmg))


def cmd_hit(robot, armor):
    return encode(0xF003, bytes([robot, armor]))


def cmd_shoot(robot, freq=5, speed=25.0):
    return encode(0xF004, struct.pack("<BBf", robot, freq, speed))


def cmd_penalty(robot, level):
    """level: 2 yellow, 3 red, 4 forfeit"""
    return encode(0xF005, bytes([robot, level]))


def cmd_life(robot, revive):
    return encode(0xF006, bytes([robot, 1 if revive else 0]))


def cmd_power(robot, watts):
    return encode(0xF007, struct.pack("<BH", robot, watts))


def cmd_time(unix):
    return encode(0xF008, struct.pack("<I", unix))
