#!/usr/bin/env python3
"""End-to-end test of arc_refd with the fake backend (no board needed).

The fake backend replays hw/sim/out/tx_bytes.hex, the exact byte stream the
RTL simulation produced, at the board's 115200-baud pace. The test plays a
browser (WebSocket) and a robot ESP32 (UDP) and checks that:

  * browsers get the board stream byte for byte;
  * the robot gets the same stream minus the console-only frames, which must
    equal the RTL's own robot UART output (hw/sim/out/robot_bytes.hex);
  * browser commands reach the PL write port whole;
  * pings are answered and the status reports the robot's RTT;
  * the latency the daemon adds (byte available in the FIFO -> UDP datagram
    received) stays within a couple of pump periods.

    make sim && python3 kria/test_arc_refd.py
"""
import asyncio
import base64
import json
import os
import pathlib
import socket
import struct
import sys
import time
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import arc_refd  # noqa: E402

TX_HEX = ROOT / "hw/sim/out/tx_bytes.hex"
ROBOT_HEX = ROOT / "hw/sim/out/robot_bytes.hex"
RUN_S = 3.0


def load_hex(p):
    return bytes(int(x, 16) for x in p.read_text().split())


async def ws_connect(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    key = base64.b64encode(os.urandom(16)).decode()
    writer.write((f"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    head = await reader.readuntil(b"\r\n\r\n")
    assert b" 101 " in head, head
    return reader, writer


def ws_client_frame(opcode, payload):
    mask = os.urandom(4)
    n = len(payload)
    head = bytes([0x80 | opcode]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack("!H", n))
    return head + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(payload))


async def http_get(port, path):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
    data = await reader.read()
    writer.close()
    head, _, body = data.partition(b"\r\n\r\n")
    return head, body


class RobotProtocol(asyncio.DatagramProtocol):
    def __init__(self):
        self.ref = []          # (receive time, payload)
        self.pings = 0
        self.transport = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        now = time.monotonic()
        if data[0] == arc_refd.DGRAM_REF:
            self.ref.append((now, data[1:]))
        elif data[0] == arc_refd.DGRAM_PING:
            self.pings += 1
            self.transport.sendto(bytes([arc_refd.DGRAM_PONG]) + data[1:], addr)


class DaemonTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not TX_HEX.exists():
            raise unittest.SkipTest("run `make sim` first (needs hw/sim/out/tx_bytes.hex)")
        cls.stream = load_hex(TX_HEX)
        cls.robot_ref = load_hex(ROBOT_HEX)
        cls.result = asyncio.run(cls.scenario())

    @classmethod
    async def scenario(cls):
        args = arc_refd.parse_args(["--backend", "fake", "--port", "0", "--udp-port", "0",
                                    "--host", "127.0.0.1", "--no-rt"])
        backend = arc_refd.FakeBackend(cls.stream, rate=args.fake_rate, loop=False, start=False)
        server = arc_refd.Server(args, backend)
        srv = await server.start()
        port, udp_port = server.port, server.robots.port
        loop = asyncio.get_running_loop()
        res = {"backend": backend}

        res["info_head"], res["info"] = await http_get(port, "/api/info")
        res["index_head"], res["index"] = await http_get(port, "/")
        res["trav_head"], _ = await http_get(port, "/../kria/arc_refd.py")

        # Robot first, so it sees the stream from the first frame.
        robot = RobotProtocol()
        transport, _ = await loop.create_datagram_endpoint(lambda: robot, local_addr=("127.0.0.1", 0))
        transport.sendto(bytes([arc_refd.DGRAM_HELLO]) + b"test-bot", ("127.0.0.1", udp_port))
        await asyncio.sleep(0.05)
        backend.start()                     # start the replay now that the robot is up

        reader, writer = await ws_connect(port)
        binary, texts = bytearray(), []
        cmd = bytes.fromhex("a50600 01 00".replace(" ", "")) + b"\x01\xf1" + b"\x00" * 8
        writer.write(ws_client_frame(0x2, cmd))
        writer.write(ws_client_frame(0x1, json.dumps({"type": "ping", "t": 42}).encode()))
        await writer.drain()

        deadline = time.monotonic() + RUN_S
        while time.monotonic() < deadline:
            try:
                op, payload = await asyncio.wait_for(arc_refd.ws_read(reader), 0.2)
            except asyncio.TimeoutError:
                continue
            if op == 0x2:
                binary += payload
            elif op == 0x1:
                texts.append(json.loads(payload))
            if robot.pings % 5 == 1:     # keep the robot alive between hellos
                transport.sendto(bytes([arc_refd.DGRAM_HELLO]) + b"test-bot", ("127.0.0.1", udp_port))
        writer.close()
        transport.close()
        server.pump.running = False
        server.pump.join(1)
        srv.close()
        res.update(binary=bytes(binary), texts=texts, robot=robot, cmd=cmd, written=bytes(backend.written))
        return res

    def test_http(self):
        r = self.result
        self.assertIn(b"200 OK", r["info_head"])
        self.assertEqual(json.loads(r["info"])["board"], "Kria KR260")
        self.assertIn(b"200 OK", r["index_head"])
        self.assertIn(b"ARC Referee", r["index"])
        self.assertIn(b"404", r["trav_head"])

    def test_browser_stream_is_board_stream(self):
        got = self.result["binary"]
        self.assertGreater(len(got), 20000, "too little data reached the browser")
        self.assertEqual(got, self.stream[:len(got)])

    def test_robot_stream_matches_rtl_robot_uart(self):
        got = b"".join(p for _, p in self.result["robot"].ref)
        self.assertGreater(len(got), 5000)
        self.assertEqual(got, self.robot_ref[:len(got)], "robot stream differs from the RTL robot UART")
        cmds = {f[5] | f[6] << 8 for f in self.frames(got)}
        self.assertFalse(any(c >= 0xF000 for c in cmds), "console frames leaked to the robot")

    def test_commands_reach_pl(self):
        self.assertEqual(self.result["written"], self.result["cmd"])

    def test_status_and_rtt(self):
        texts = self.result["texts"]
        self.assertEqual(texts[0]["type"], "hello")
        self.assertIn({"type": "pong", "t": 42}, texts)
        status = [t for t in texts if t["type"] == "status"]
        self.assertTrue(status)
        robots = status[-1]["robots"]
        self.assertEqual([r["name"] for r in robots], ["test-bot"])
        self.assertIsNotNone(robots[0]["rttP50"])
        # Median only: a shared CI machine can stall a single sample.
        self.assertLess(robots[0]["rttP50"], 5)
        self.assertGreater(self.result["robot"].pings, 10)
        print(f"\n  robot RTT p50 {robots[0]['rttP50']} ms, p99 {robots[0]['rttP99']} ms, "
              f"loss {robots[0]['loss']} %, pump max gap {status[-1]['pumpMaxGapMs']} ms")

    def test_added_latency(self):
        backend = self.result["backend"]
        pos, lat = 0, []
        for t, payload in self.result["robot"].ref:
            # The datagram's last byte left the PL FIFO when the robot stream
            # reached it; find that byte's index in the full board stream.
            pos += len(payload)
            idx = self.robot_index_to_stream(pos - 1)
            lat.append(t - backend.available_at(idx))
        lat.sort()
        p50, p99, worst = lat[len(lat) // 2], lat[int(0.99 * len(lat))], lat[-1]
        print(f"\n  daemon added latency: p50 {p50 * 1000:.2f} ms, p99 {p99 * 1000:.2f} ms, "
              f"max {worst * 1000:.2f} ms over {len(lat)} datagrams")
        self.assertLess(p99, 0.005)

    # helpers
    @staticmethod
    def frames(data):
        i, out = 0, []
        while i + 9 <= len(data):
            n = 9 + (data[i + 1] | data[i + 2] << 8)
            out.append(data[i:i + n])
            i += n
        return out

    _map = None

    def robot_index_to_stream(self, ridx):
        if DaemonTest._map is None:
            m, i, s = [], 0, self.stream
            while i + 9 <= len(s):
                n = 9 + (s[i + 1] | s[i + 2] << 8)
                if (s[i + 5] | s[i + 6] << 8) < 0xF000:
                    m.extend(range(i, i + n))
                i += n
            DaemonTest._map = m
        return DaemonTest._map[ridx]


if __name__ == "__main__":
    unittest.main(verbosity=2)
