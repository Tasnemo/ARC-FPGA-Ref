#!/usr/bin/env python3
"""ARC referee daemon for the Kria KR260 (Ubuntu on the A53 cores).

The referee itself (rules, clock, HP, frame timing, CRCs) runs in the PL
exactly as on the Zybo. This program only moves bytes, so the timing stays
in hardware:

    PL referee core --AXI--> pump thread --UDP over WiFi--> ESP32 on each robot
                                  |                           --> robot UART
                                  +--WebSocket--> browsers (console, scoreboards)
    browser commands --WebSocket--> pump thread --AXI--> PL

Real-time measures:
  * The pump thread polls the PL FIFO every 1 ms under SCHED_FIFO with its
    memory locked, and sends each batch of frames to the robots in the same
    pass, so the PS adds at most about 1 ms.
  * Robot datagrams are marked for the WiFi voice queue (WMM AC_VO), carry
    whole frames, and are dropped rather than queued when a socket is
    backed up: a robot always gets the newest data, never a backlog.
  * The daemon pings every robot 10 times a second and reports round-trip
    time (p50/p99/max) and loss to the console, so the latency is measured,
    not assumed.

Only the Python 3 standard library is used, so nothing has to be installed.

    sudo python3 kria/arc_refd.py                       # on the KR260
    python3 kria/arc_refd.py --backend fake --port 8080 # anywhere, for testing

Robot datagram format (UDP port 7400 on the board), first byte is the type:
    0x00 REF    referee bytes (board->robot: whole frames; robot->board: 0x0301 etc.)
    0x01 PING   u32 seq, u64 board time in ns (board->robot)
    0x02 PONG   the PING payload echoed back (robot->board)
    0x03 HELLO  UTF-8 robot name (robot->board, every 500 ms)
"""
import argparse
import asyncio
import base64
import collections
import ctypes
import glob
import hashlib
import json
import mimetypes
import mmap
import os
import pathlib
import queue
import socket
import struct
import sys
import threading
import time

VERSION = "1.0.0"

# arc_ref_axi register map (hw/rtl/arc_ref_axi.v)
REG_ID, REG_RX_DATA, REG_TX_DATA, REG_STATUS, REG_CTRL, REG_COUNTERS = 0x00, 0x08, 0x0C, 0x10, 0x14, 0x18
ID_VALUE = 0x41524346          # "ARCF"
TX_VALID = 0x100

DGRAM_REF, DGRAM_PING, DGRAM_PONG, DGRAM_HELLO = 0, 1, 2, 3
MAX_DGRAM = 1400               # stays under one WiFi MPDU, no IP fragmentation
CONSOLE_CMD_MIN = 0xF000       # 0xF101/0xF102 are console-only; robots never see them
PEER_TIMEOUT_S = 2.0
PING_PERIOD_S = 0.1
STATUS_PERIOD_S = 0.5


# --------------------------------------------------------------- backends
class MmioBackend:
    """arc_ref_axi through /dev/uioN (if generic-uio bound it) or /dev/mem."""

    name = "mmio"

    def __init__(self, base=0xA0000000, size=0x10000):
        path, offset = self._find_uio() or ("/dev/mem", base)
        fd = os.open(path, os.O_RDWR | os.O_SYNC)
        try:
            self._mm = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=offset)
        finally:
            os.close(fd)
        # ctypes element access is a single 32-bit load/store, which matters:
        # each read of TX_DATA pops one byte from the FIFO.
        self._regs = (ctypes.c_uint32 * (size // 4)).from_buffer(self._mm)
        self.path = path
        ident = self._regs[REG_ID >> 2]
        if ident != ID_VALUE:
            raise RuntimeError(
                f"referee core not found at 0x{base:08x} via {path} (read 0x{ident:08x}); "
                "is the bitstream loaded? Run: sudo xmutil loadapp arc-ref")

    @staticmethod
    def _find_uio():
        for d in glob.glob("/sys/class/uio/uio*"):
            try:
                if pathlib.Path(d, "name").read_text().strip() == "arc_ref":
                    return f"/dev/{os.path.basename(d)}", 0
            except OSError:
                pass
        return None

    def reset(self):
        self._regs[REG_CTRL >> 2] = 1
        self._regs[REG_CTRL >> 2] = 0

    def read(self, limit=4096):
        regs = self._regs
        n = min(regs[REG_STATUS >> 2] & 0xFFFF, limit)
        out = bytearray()
        for _ in range(n):
            t = regs[REG_TX_DATA >> 2]
            if not t & TX_VALID:
                break
            out.append(t & 0xFF)
        return bytes(out)

    def write(self, data):
        regs = self._regs
        for b in data:
            regs[REG_RX_DATA >> 2] = b

    def counters(self):
        c = self._regs[REG_COUNTERS >> 2]
        return {"rxOk": c & 0xFFFF, "rxErr": c >> 16}


class FakeBackend:
    """Replays a recorded board stream (hw/sim/out/tx_bytes.hex) in real time.

    Used for tests and for trying the console without a board. `available_at`
    gives the time each byte appeared, so tests can measure added latency.
    """

    name = "fake"

    def __init__(self, stream, rate=11520, loop=True, start=True):
        self.stream = stream
        self.rate = rate
        self.loop = loop
        self.t0 = None
        self.pos = 0
        if start:
            self.start()
        self.written = bytearray()

    @classmethod
    def from_hex(cls, path, **kw):
        lines = pathlib.Path(path).read_text().split()
        return cls(bytes(int(x, 16) for x in lines), **kw)

    def start(self):
        self.t0 = time.monotonic()

    def available_at(self, index):
        return self.t0 + (index + 1) / self.rate

    def reset(self):
        pass

    def read(self, limit=4096):
        if self.t0 is None:
            return b""
        due = int((time.monotonic() - self.t0) * self.rate)
        if not self.loop:
            due = min(due, len(self.stream))
        n = min(due - self.pos, limit)
        if n <= 0:
            return b""
        out = bytes(self.stream[(self.pos + i) % len(self.stream)] for i in range(n))
        self.pos += n
        return out

    def write(self, data):
        self.written += data

    def counters(self):
        return {"rxOk": 0, "rxErr": 0}


# --------------------------------------------------------------- framing
def crc8(data, crc=0xFF):
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8C if crc & 1 else crc >> 1
    return crc


class FrameSplitter:
    """Cuts the board byte stream into whole frames (SOF, len, seq, CRC8 ...).

    The PL only emits valid frames; the header CRC is still checked so the
    splitter resynchronises if it ever starts mid-frame.
    """

    def __init__(self):
        self.buf = bytearray()
        self.skipped = 0

    def push(self, data):
        self.buf += data
        frames = []
        buf = self.buf
        i = 0
        while True:
            j = buf.find(b"\xA5", i)
            if j < 0:
                self.skipped += len(buf) - i
                i = len(buf)
                break
            self.skipped += j - i
            i = j
            if len(buf) - i < 5:
                break
            if crc8(buf[i:i + 4]) != buf[i + 4]:
                i += 1
                self.skipped += 1
                continue
            total = 9 + (buf[i + 1] | buf[i + 2] << 8)
            if len(buf) - i < total:
                break
            cmd = buf[i + 5] | buf[i + 6] << 8
            frames.append((cmd, bytes(buf[i:i + total])))
            i += total
        del buf[:i]
        return frames


# --------------------------------------------------------------- robots
class Peer:
    def __init__(self, addr):
        self.addr = addr
        self.name = f"{addr[0]}"
        self.last_seen = time.monotonic()
        self.rtt = collections.deque(maxlen=200)    # seconds
        self.pings = {}                             # seq -> send time (monotonic)
        self.sent_pings = 0
        self.lost_pings = 0
        self.tx_bytes = self.tx_frames = self.tx_drops = 0
        self.rx_bytes = 0

    def stats(self, now):
        r = sorted(self.rtt)

        def pct(p):
            return round(r[min(len(r) - 1, int(p * len(r)))] * 1000, 2) if r else None
        window = self.sent_pings or 1
        return {
            "name": self.name, "ip": self.addr[0], "port": self.addr[1],
            "ageMs": round((now - self.last_seen) * 1000),
            "rttP50": pct(0.50), "rttP99": pct(0.99), "rttMax": round(r[-1] * 1000, 2) if r else None,
            "loss": round(100.0 * self.lost_pings / window, 1),
            "txBytes": self.tx_bytes, "txFrames": self.tx_frames, "txDrops": self.tx_drops,
            "rxBytes": self.rx_bytes,
        }


class RobotLink:
    """UDP side of the pump. Only ever called from the pump thread."""

    def __init__(self, port, on_uplink):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # CS7 in the TOS byte -> 802.11 user priority 7 -> WMM voice queue,
        # the shortest contention window on the air.
        try:
            self.sock.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, 0xE0)
        except OSError:
            pass
        try:
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_PRIORITY, 6)
        except (OSError, AttributeError):
            pass
        self.sock.bind(("0.0.0.0", port))
        self.sock.setblocking(False)
        self.port = self.sock.getsockname()[1]
        self.peers = {}
        self.on_uplink = on_uplink
        self.ping_seq = 0
        self.next_ping = 0.0
        self.splitter = {}

    def poll(self, now):
        while True:
            try:
                data, addr = self.sock.recvfrom(2048)
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                break
            if not data:
                continue
            peer = self.peers.get(addr)
            if peer is None:
                peer = self.peers[addr] = Peer(addr)
                self.splitter[addr] = FrameSplitter()
            peer.last_seen = now
            kind, body = data[0], data[1:]
            if kind == DGRAM_HELLO:
                peer.name = body.decode("utf-8", "replace")[:32] or peer.name
            elif kind == DGRAM_PONG and len(body) >= 12:
                seq = struct.unpack_from("<I", body)[0]
                sent = peer.pings.pop(seq, None)
                if sent is not None:
                    peer.rtt.append(now - sent)
            elif kind == DGRAM_REF:
                peer.rx_bytes += len(body)
                for _, frame in self.splitter[addr].push(body):
                    self.on_uplink(frame)

        for addr in [a for a, p in self.peers.items() if now - p.last_seen > PEER_TIMEOUT_S]:
            del self.peers[addr]
            self.splitter.pop(addr, None)

        if now >= self.next_ping:
            self.next_ping = now + PING_PERIOD_S
            self.ping_seq = (self.ping_seq + 1) & 0xFFFFFFFF
            msg = struct.pack("<BIQ", DGRAM_PING, self.ping_seq, time.monotonic_ns())
            for peer in self.peers.values():
                for seq in [s for s, t in peer.pings.items() if now - t > 1.0]:
                    del peer.pings[seq]
                    peer.lost_pings += 1
                peer.pings[self.ping_seq] = now
                peer.sent_pings += 1
                self._send(peer, msg)

    def send_frames(self, frames):
        """Whole frames, packed into as few datagrams as fit."""
        if not self.peers:
            return
        chunks, cur, count = [], bytearray([DGRAM_REF]), 0
        for frame in frames:
            if len(cur) + len(frame) > MAX_DGRAM and len(cur) > 1:
                chunks.append((bytes(cur), count))
                cur, count = bytearray([DGRAM_REF]), 0
            cur += frame
            count += 1
        if len(cur) > 1:
            chunks.append((bytes(cur), count))
        for peer in self.peers.values():
            for msg, n in chunks:
                if self._send(peer, msg):
                    peer.tx_bytes += len(msg) - 1
                    peer.tx_frames += n

    def _send(self, peer, msg):
        try:
            self.sock.sendto(msg, peer.addr)
            return True
        except (BlockingIOError, InterruptedError):
            peer.tx_drops += 1      # newest data next time; never build a backlog
        except OSError:
            peer.tx_drops += 1
        return False

    def stats(self, now):
        return [p.stats(now) for p in self.peers.values()]


# --------------------------------------------------------------- pump
class Pump(threading.Thread):
    """The only code that touches the PL and the robot socket."""

    def __init__(self, backend, robots, on_frames, on_status, period=0.001, realtime=True):
        super().__init__(name="arc-pump", daemon=True)
        self.backend = backend
        self.robots = robots
        self.on_frames = on_frames
        self.on_status = on_status
        self.period = period
        self.realtime = realtime
        self.commands = queue.SimpleQueue()
        self.splitter = FrameSplitter()
        self.running = True
        self.rt_status = "off"
        self.max_gap = 0.0
        self.loops = 0
        self.frames_in = 0
        self.uplink = []

    def _go_realtime(self):
        if not self.realtime or not hasattr(os, "sched_setscheduler"):
            return
        try:
            os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(50))
            self.rt_status = "SCHED_FIFO 50"
        except (PermissionError, OSError):
            self.rt_status = "normal (run as root for SCHED_FIFO)"
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            if libc.mlockall(3) == 0:           # MCL_CURRENT | MCL_FUTURE
                self.rt_status += ", memory locked"
        except (OSError, AttributeError):
            pass

    def run(self):
        self._go_realtime()
        next_tick = time.monotonic()
        last = next_tick
        next_status = next_tick
        while self.running:
            now = time.monotonic()
            gap = now - last
            last = now
            if self.loops > 10 and gap > self.max_gap:
                self.max_gap = gap
            self.loops += 1

            # Browser commands first: each message is written whole.
            while True:
                try:
                    msg = self.commands.get_nowait()
                except queue.Empty:
                    break
                self.backend.write(msg)

            self.uplink = []
            self.robots.poll(now)

            data = self.backend.read()
            frames = self.splitter.push(data) if data else []
            if frames:
                self.frames_in += len(frames)
                real = [f for c, f in frames if c < CONSOLE_CMD_MIN]
                if real:
                    self.robots.send_frames(real)
            out = [f for _, f in frames] + self.uplink
            if out:
                self.on_frames(b"".join(out))

            if now >= next_status:
                next_status = now + STATUS_PERIOD_S
                self.on_status({
                    "type": "status", "backend": self.backend.name, "rt": self.rt_status,
                    "pumpPeriodMs": self.period * 1000, "pumpMaxGapMs": round(self.max_gap * 1000, 2),
                    "framesIn": self.frames_in, "udpPort": self.robots.port,
                    "robots": self.robots.stats(now), **self.backend.counters(),
                })
                self.max_gap = 0.0

            next_tick += self.period
            delay = next_tick - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_tick = time.monotonic()

    def uplink_frame(self, frame):
        self.uplink.append(frame)


# --------------------------------------------------------------- web
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CLIENT_QUEUE_LIMIT = 256 * 1024


class WsClient:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer
        self.queue = collections.deque()
        self.queued = 0
        self.dropped = 0
        self.wake = asyncio.Event()
        self.closed = False

    def push(self, opcode, payload):
        if self.closed:
            return
        # Binary messages are whole frames, so dropping the oldest keeps the
        # stream decodable and the console current if a browser falls behind.
        while self.queued + len(payload) > CLIENT_QUEUE_LIMIT and self.queue:
            _, old = self.queue.popleft()
            self.queued -= len(old)
            self.dropped += 1
        self.queue.append((opcode, payload))
        self.queued += len(payload)
        self.wake.set()

    async def sender(self):
        try:
            while not self.closed:
                await self.wake.wait()
                self.wake.clear()
                while self.queue:
                    opcode, payload = self.queue.popleft()
                    self.queued -= len(payload)
                    self.writer.write(ws_frame(opcode, payload))
                await self.writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            self.closed = True


def ws_frame(opcode, payload):
    n = len(payload)
    if n < 126:
        head = struct.pack("!BB", 0x80 | opcode, n)
    elif n < 65536:
        head = struct.pack("!BBH", 0x80 | opcode, 126, n)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 127, n)
    return head + payload


async def ws_read(reader):
    """One complete message: (opcode, payload). Handles fragmentation."""
    message, first_op = bytearray(), None
    while True:
        b0, b1 = await reader.readexactly(2)
        op, fin, masked, n = b0 & 0x0F, b0 & 0x80, b1 & 0x80, b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", await reader.readexactly(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", await reader.readexactly(8))[0]
        if n > 1 << 20:
            raise ConnectionError("message too large")
        mask = await reader.readexactly(4) if masked else b"\0\0\0\0"
        data = bytearray(await reader.readexactly(n))
        for i in range(n):
            data[i] ^= mask[i & 3]
        if op >= 8:                       # control frames may interleave
            return op, bytes(data)
        if op != 0:
            first_op = op
        message += data
        if fin:
            return first_op, bytes(message)


class Server:
    def __init__(self, args, backend):
        self.args = args
        self.backend = backend
        self.web = pathlib.Path(args.web).resolve()
        self.clients = set()
        self.status = {}
        self.loop = None
        self.robots = None
        self.pump = None

    # Called from the pump thread
    def frames_from_pump(self, data):
        self.loop.call_soon_threadsafe(self._broadcast, 0x2, data)

    def status_from_pump(self, status):
        self.loop.call_soon_threadsafe(self._status, status)

    def _broadcast(self, opcode, payload):
        for c in list(self.clients):
            c.push(opcode, payload)

    def _status(self, status):
        status["browsers"] = len(self.clients)
        status["browserDrops"] = sum(c.dropped for c in self.clients)
        self.status = status
        self._broadcast(0x1, json.dumps(status).encode())

    def info(self):
        return {"board": "Kria KR260", "app": "arc-refd", "version": VERSION,
                "backend": self.backend.name, "udpPort": self.robots.port, "ws": "/ws"}

    async def start(self):
        self.loop = asyncio.get_running_loop()
        self.robots = RobotLink(self.args.udp_port, lambda f: self.pump.uplink_frame(f))
        self.pump = Pump(self.backend, self.robots, self.frames_from_pump, self.status_from_pump,
                         period=self.args.period_ms / 1000, realtime=not self.args.no_rt)
        self.backend.reset()
        self.pump.start()
        srv = await asyncio.start_server(self.handle, self.args.host, self.args.port)
        self.port = srv.sockets[0].getsockname()[1]
        print(f"arc-refd {VERSION}: backend {self.backend.name}, http/ws on port {self.port}, "
              f"robots on udp {self.robots.port}", flush=True)
        return srv

    async def handle(self, reader, writer):
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
            writer.close()
            return
        lines = head.decode("latin-1").split("\r\n")
        try:
            method, target, _ = lines[0].split(" ", 2)
        except ValueError:
            writer.close()
            return
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        path = target.split("?", 1)[0]

        if path == "/ws" and headers.get("upgrade", "").lower() == "websocket":
            await self.websocket(reader, writer, headers)
            return
        try:
            if method not in ("GET", "HEAD"):
                await self.respond(writer, 405, b"method not allowed", "text/plain")
            elif path == "/api/info":
                await self.respond(writer, 200, json.dumps(self.info()).encode(), "application/json")
            elif path == "/api/status":
                await self.respond(writer, 200, json.dumps(self.status).encode(), "application/json")
            else:
                await self.static(writer, path, method == "HEAD")
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()

    async def respond(self, writer, code, body, ctype, head_only=False):
        reason = {200: "OK", 404: "Not Found", 405: "Method Not Allowed"}.get(code, "")
        writer.write((f"HTTP/1.1 {code} {reason}\r\nContent-Type: {ctype}\r\n"
                      f"Content-Length: {len(body)}\r\nCache-Control: no-store\r\n"
                      "Connection: close\r\n\r\n").encode())
        if not head_only:
            writer.write(body)
        await writer.drain()

    async def static(self, writer, path, head_only):
        rel = path.lstrip("/") or "index.html"
        target = (self.web / rel).resolve()
        if self.web not in target.parents and target != self.web or not target.is_file():
            await self.respond(writer, 404, b"not found", "text/plain")
            return
        ctype = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if target.suffix == ".mjs" or target.suffix == ".js":
            ctype = "text/javascript"
        await self.respond(writer, 200, target.read_bytes(), ctype, head_only)

    async def websocket(self, reader, writer, headers):
        key = headers.get("sec-websocket-key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        await writer.drain()
        sock = writer.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client = WsClient(reader, writer)
        self.clients.add(client)
        sender = asyncio.ensure_future(client.sender())
        client.push(0x1, json.dumps({"type": "hello", **self.info()}).encode())
        if self.status:
            client.push(0x1, json.dumps(self.status).encode())
        try:
            while True:
                op, payload = await ws_read(reader)
                if op == 0x8:
                    break
                if op == 0x9:
                    client.push(0xA, payload)
                elif op == 0x2:
                    if payload:
                        self.pump.commands.put(payload)
                elif op == 0x1:
                    self.text_message(client, payload)
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        finally:
            client.closed = True
            client.wake.set()
            self.clients.discard(client)
            sender.cancel()
            try:
                writer.write(ws_frame(0x8, b""))
                writer.close()
            except (ConnectionError, OSError, RuntimeError):
                pass

    def text_message(self, client, payload):
        try:
            msg = json.loads(payload)
        except ValueError:
            return
        if msg.get("type") == "ping":
            # Lets the browser measure its own round trip to the board.
            client.push(0x1, json.dumps({"type": "pong", "t": msg.get("t")}).encode())


def parse_args(argv=None):
    root = pathlib.Path(__file__).resolve().parent.parent
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--backend", choices=["mmio", "fake"], default="mmio")
    p.add_argument("--base", type=lambda s: int(s, 0), default=0xA0000000, help="arc_ref_axi address")
    p.add_argument("--fake-stream", default=str(root / "hw/sim/out/tx_bytes.hex"),
                   help="recorded board stream for --backend fake (make sim writes it)")
    p.add_argument("--fake-rate", type=int, default=11520, help="bytes/s replayed by the fake backend")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=80, help="HTTP + WebSocket port")
    p.add_argument("--udp-port", type=int, default=7400, help="robot link port")
    p.add_argument("--web", default=str(root / "web"), help="directory served to browsers")
    p.add_argument("--period-ms", type=float, default=1.0, help="PL poll period")
    p.add_argument("--no-rt", action="store_true", help="don't ask for SCHED_FIFO")
    return p.parse_args(argv)


def make_backend(args):
    if args.backend == "fake":
        return FakeBackend.from_hex(args.fake_stream, rate=args.fake_rate)
    return MmioBackend(args.base)


async def main_async(args):
    server = Server(args, make_backend(args))
    srv = await server.start()
    async with srv:
        await srv.serve_forever()


def main():
    args = parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass
    except (RuntimeError, PermissionError, FileNotFoundError) as e:
        sys.exit(f"arc-refd: {e}")


if __name__ == "__main__":
    main()
