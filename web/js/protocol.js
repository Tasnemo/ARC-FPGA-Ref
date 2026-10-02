// ARC referee link protocol (docs/protocol.md). Mirrors tools/arcref.py.
// Real frames follow the RoboMaster 2026 University Series protocol (ARCC 2026).
//
// Frame: SOF 0xA5 | data_length u16 | seq u8 | CRC8 | cmd_id u16 | data | CRC16
// All multi-byte fields are little-endian.

export const SOF = 0xa5;

export const CMD = {
  GAME_STATUS: 0x0001,
  GAME_RESULT: 0x0002,
  ROBOT_HP: 0x0003,
  FIELD_EVENT: 0x0101,
  REFEREE_WARNING: 0x0104,
  ROBOT_STATUS: 0x0201,
  POWER_HEAT: 0x0202,
  BUFF: 0x0204,
  HURT: 0x0206,
  SHOOT: 0x0207,
  SERVER_STATE: 0xf101,
  EVENT: 0xf102,
  // browser -> board
  C_GAME: 0xf001,
  C_CONFIG: 0xf002,
  C_HIT: 0xf003,
  C_SHOOT: 0xf004,
  C_PENALTY: 0xf005,
  C_LIFE: 0xf006,
  C_POWER: 0xf007,
  C_TIME: 0xf008,
  C_ROBOT: 0xf009,
  C_ZONE: 0xf00a,
  C_EXCHANGE: 0xf00b,
};

export const CMD_NAMES = {
  0x0001: 'game_status',
  0x0002: 'game_result',
  0x0003: 'ally_robot_HP',
  0x0101: 'event_data',
  0x0104: 'referee_warning',
  0x0201: 'robot_status',
  0x0202: 'buffer_heat_data',
  0x0204: 'buff',
  0x0206: 'hurt_data',
  0x0207: 'shoot_data',
  0xf101: 'server_state',
  0xf102: 'server_event',
};

export const STAGES = ['Not started', 'Setup period', 'Referee init', 'Countdown', 'Battle', 'Settlement'];
export const GAME_TYPES = { 1: 'RMUC', 2: 'RMUT', 3: 'RMUA', 4: 'RMUL 3v3', 5: 'RMUL 1v1' };
export const EVENT_KINDS = {
  1: 'hit', 2: 'shot', 3: 'locked', 4: 'chassis-cut', 5: 'yellow', 6: 'red', 7: 'forfeit',
  8: 'kill', 9: 'revive', 10: 'disconnect', 11: 'reconnect', 12: 'offline-hp', 13: 'unlocked',
  14: 'yellow-both', 15: 'exchange', 16: 'immune', 17: 'respawn', 18: 'capture', 19: 'yellow-team',
};
export const LOCKS = {
  1: 'barrel heat over limit', 2: 'barrel heat over limit + 100 (rest of round)',
  3: 'over speed (15 s)', 4: 'over speed (20 s)', 5: 'over speed (rest of round)', 6: 'out of projectiles',
};
export const WIN_REASONS = {
  0: '', 1: 'opponent defeated', 2: 'more remaining HP', 3: 'opponent took first damage',
  4: 'more shots fired', 5: 'fired first', 6: 'tie: lighter robot wins (referee decides)', 7: 'forfeit',
  8: 'opponent reached 0 Victory Points', 9: 'more Victory Points', 10: 'more attack damage dealt',
  11: 'more total remaining HP',
};
export const HURT_REASONS = { 0: 'armor hit', 1: 'module offline', 5: 'collision' };
export const GAME = { SETUP: 1, START: 2, PAUSE: 3, RESUME: 4, END: 5, RESET: 6 };
export const PENALTY = { BOTH_YELLOW: 1, YELLOW: 2, RED: 3, FORFEIT: 4 };
export const LIFE = { KILL: 0, REVIVE: 1, DISCONNECT: 2, RECONNECT: 3 };
export const ZONE = { NONE: 0, RESUPPLY: 1, CAPTURE: 2 };
export const MODE = { V1: 5, V3: 4 };

// Six robot slots: team = slot >= 3, role = slot % 3.
export const SLOTS = [
  { team: 0, role: 'hero', id: 1, name: 'Hero' },
  { team: 0, role: 'infantry', id: 3, name: 'Infantry' },
  { team: 0, role: 'sentry', id: 7, name: 'Sentry' },
  { team: 1, role: 'hero', id: 101, name: 'Hero' },
  { team: 1, role: 'infantry', id: 103, name: 'Infantry' },
  { team: 1, role: 'sentry', id: 107, name: 'Sentry' },
];
export const HIT_KIND = { MM17: 0, COLLISION: 1, MM42: 2 };

// Robot stats from the ARCC 2026 Events Manual (tables 3-2, 3-3, 3-4, 4-2).
export const ROBOT_PRESETS = {
  infantry1v1: { fielded: true, cal42: false, maxHp: 200, heatLimit: 80, cooling: 12, powerLimit: 120, speedLimit: 25, allowance: 200 },
  hero: { fielded: true, cal42: true, maxHp: 350, heatLimit: 200, cooling: 24, powerLimit: 100, speedLimit: 15, allowance: 0 },
  sentry: { fielded: true, cal42: false, maxHp: 400, heatLimit: 260, cooling: 30, powerLimit: 100, speedLimit: 25, allowance: 750 },
  absent: { fielded: false, cal42: false, maxHp: 200, heatLimit: 80, cooling: 12, powerLimit: 120, speedLimit: 25, allowance: 0 },
};
// 3v3 Infantry: the pilot picks a chassis and a launcher type during setup.
export const INFANTRY_CHASSIS = { hp: { label: 'HP priority', maxHp: 350, powerLimit: 75 }, power: { label: 'Power priority', maxHp: 300, powerLimit: 90 } };
export const INFANTRY_LAUNCHER = { cooldown: { label: 'Cooldown priority', heatLimit: 88, cooling: 24 }, burst: { label: 'Burst priority', heatLimit: 230, cooling: 14 } };
export function infantry3v3(chassis = 'hp', launcher = 'cooldown') {
  const c = INFANTRY_CHASSIS[chassis];
  const l = INFANTRY_LAUNCHER[launcher];
  return { fielded: true, cal42: false, maxHp: c.maxHp, heatLimit: l.heatLimit, cooling: l.cooling, powerLimit: c.powerLimit, speedLimit: 25, allowance: 0 };
}
export const MODES = {
  '1v1': { gameType: 5, combatTime: 120, setupTime: 120, link: 1 },
  '3v3': { gameType: 4, combatTime: 300, setupTime: 180, link: 1 },
};
export function modeRobots(mode, infantry = [{}, {}]) {
  if (mode === '1v1') {
    const r = ROBOT_PRESETS;
    return [r.absent, r.infantry1v1, r.absent, r.absent, r.infantry1v1, r.absent];
  }
  const inf = infantry.map((x) => infantry3v3(x.chassis, x.launcher));
  return [ROBOT_PRESETS.hero, inf[0], ROBOT_PRESETS.sentry, ROBOT_PRESETS.hero, inf[1], ROBOT_PRESETS.sentry];
}

export const ROBOT_IDS = SLOTS.map((x) => x.id);

const CRC8_TABLE = new Uint8Array(256);
const CRC16_TABLE = new Uint16Array(256);
for (let i = 0; i < 256; i++) {
  let c8 = i;
  let c16 = i;
  for (let b = 0; b < 8; b++) {
    c8 = c8 & 1 ? (c8 >>> 1) ^ 0x8c : c8 >>> 1;
    c16 = c16 & 1 ? (c16 >>> 1) ^ 0x8408 : c16 >>> 1;
  }
  CRC8_TABLE[i] = c8;
  CRC16_TABLE[i] = c16;
}

export function crc8(bytes, start = 0, end = bytes.length, crc = 0xff) {
  for (let i = start; i < end; i++) crc = CRC8_TABLE[(crc ^ bytes[i]) & 0xff];
  return crc;
}

export function crc16(bytes, start = 0, end = bytes.length, crc = 0xffff) {
  for (let i = start; i < end; i++) crc = (crc >>> 8) ^ CRC16_TABLE[(crc ^ bytes[i]) & 0xff];
  return crc;
}

export function encode(cmdId, payload = new Uint8Array(0), seq = 0) {
  const n = payload.length;
  const f = new Uint8Array(9 + n);
  f[0] = SOF;
  f[1] = n & 0xff;
  f[2] = n >> 8;
  f[3] = seq & 0xff;
  f[4] = crc8(f, 0, 4);
  f[5] = cmdId & 0xff;
  f[6] = cmdId >> 8;
  f.set(payload, 7);
  const c = crc16(f, 0, 7 + n);
  f[7 + n] = c & 0xff;
  f[8 + n] = c >> 8;
  return f;
}

// Streaming decoder: push() any chunk of bytes, get back complete frames.
// Bytes outside frames (e.g. the bridge's text banner) go to onSkipped.
export class FrameDecoder {
  constructor(maxLen = 512) {
    this.buf = new Uint8Array(0);
    this.maxLen = maxLen;
    this.bad = 0;
  }

  push(chunk) {
    const merged = new Uint8Array(this.buf.length + chunk.length);
    merged.set(this.buf);
    merged.set(chunk, this.buf.length);
    let b = merged;
    let i = 0;
    const out = [];
    while (true) {
      const skipFrom = i;
      while (i < b.length && b[i] !== SOF) i++;
      if (i > skipFrom) this.onSkipped?.(b.subarray(skipFrom, i));
      if (b.length - i < 5) break;
      if (crc8(b, i, i + 4) !== b[i + 4]) {
        this.bad++;
        i++;
        continue;
      }
      const n = b[i + 1] | (b[i + 2] << 8);
      if (n > this.maxLen) {
        this.bad++;
        i++;
        continue;
      }
      if (b.length - i < 9 + n) break;
      const c = crc16(b, i, i + 7 + n);
      if ((b[i + 7 + n] | (b[i + 8 + n] << 8)) !== c) {
        this.bad++;
        i++;
        continue;
      }
      out.push({
        cmd: b[i + 5] | (b[i + 6] << 8),
        seq: b[i + 3],
        data: b.slice(i + 7, i + 7 + n),
        raw: b.slice(i, i + 9 + n),
      });
      i += 9 + n;
    }
    this.buf = b.slice(i);
    return out;
  }
}

// ----------------------------------------------------------------- payloads
function robotBlock(v, o) {
  const f = v.getUint8(o + 23);
  const f2 = v.getUint8(o + 24);
  const timer = v.getUint16(o + 28, true);
  const respawning = !!(f2 & 16);
  return {
    hp: v.getUint16(o, true),
    maxHp: v.getUint16(o + 2, true),
    heat: Math.floor(v.getUint16(o + 4, true) / 10),
    heatLimit: v.getUint16(o + 6, true),
    buffer: Math.floor(v.getUint16(o + 8, true) / 10),
    power: v.getUint16(o + 10, true),
    powerLimit: v.getUint16(o + 12, true),
    allowance: v.getUint16(o + 14, true),
    shots: v.getUint16(o + 16, true),
    cooling: v.getUint16(o + 18, true),
    speedLimit: v.getUint16(o + 20, true),
    yellow: v.getUint8(o + 22),
    alive: !!(f & 1),
    redCard: !!(f & 2),
    shooterOn: !!(f & 4),
    chassisOn: !!(f & 8),
    gimbalOn: !!(f & 16),
    disconnected: !!(f & 32),
    heatLocked: !!(f & 64),
    speedLocked: !!(f & 128),
    fielded: !!(f2 & 1),
    cal42: !!(f2 & 2),
    invincible: !!(f2 & 4),
    weakened: !!(f2 & 8),
    respawning,
    zone: (f2 >> 5) & 3,
    chassisCutDs: v.getUint8(o + 25),
    speedLockS: v.getUint16(o + 26, true) === 0xffff ? 255 : Math.ceil(v.getUint16(o + 26, true) / 10),
    respawnS: respawning ? Math.ceil(timer / 10) : 0,
    invincibleS: respawning ? 0 : Math.ceil(timer / 10),
  };
}

export function decodePayload(cmd, data) {
  const v = new DataView(data.buffer, data.byteOffset, data.byteLength);
  try {
    switch (cmd) {
      case CMD.GAME_STATUS:
        return {
          gameType: data[0] & 0xf,
          progress: data[0] >> 4,
          remain: v.getUint16(1, true),
          timestamp: Number(v.getBigUint64(3, true)),
        };
      case CMD.GAME_RESULT:
        return { winner: data[0] };
      case CMD.ROBOT_HP: {
        const hp = [];
        for (let i = 0; i < 8; i++) hp.push(v.getUint16(i * 2, true));
        return { ally1: hp[0], ally3: hp[2], ally7: hp[5], all: hp };
      }
      case CMD.FIELD_EVENT: {
        const x = v.getUint32(0, true);
        return { resupply: !!((x >> 2) & 1), center: (x >> 23) & 3, raw: x };
      }
      case CMD.BUFF:
        return { recovery: data[0], cooling: v.getUint16(1, true), defence: data[3], vulnerability: data[4], attack: v.getUint16(5, true), energy: data[7] };
      case CMD.REFEREE_WARNING:
        return { level: data[0], offender: data[1], count: data[2] };
      case CMD.ROBOT_STATUS:
        return {
          robotId: data[0],
          level: data[1],
          hp: v.getUint16(2, true),
          maxHp: v.getUint16(4, true),
          cooling: v.getUint16(6, true),
          heatLimit: v.getUint16(8, true),
          powerLimit: v.getUint16(10, true),
          gimbalOn: !!(data[12] & 1),
          chassisOn: !!(data[12] & 2),
          shooterOn: !!(data[12] & 4),
        };
      case CMD.POWER_HEAT:
        return { buffer: v.getUint16(8, true), heat17: v.getUint16(10, true), heat42: v.getUint16(12, true) };
      case CMD.HURT:
        return { armor: data[0] & 0xf, reason: data[0] >> 4 };
      case CMD.SHOOT:
        return { bulletType: data[0], shooter: data[1], freq: data[2], speed: v.getFloat32(3, true) };
      case CMD.SERVER_STATE: {
        if (data.length < 212) return null;
        const team = (t) => ({
          vp: v.getUint16(8 + 8 * t, true),
          coins: v.getUint16(10 + 8 * t, true),
          damage: v.getUint16(12 + 8 * t, true),
          heroLive: !!(data[14 + 8 * t] & 1),
        });
        return {
          stage: data[0],
          paused: !!(data[1] & 1),
          firstDmg: (data[1] >> 1) & 3,
          firstShot: (data[1] >> 3) & 3,
          capture: (data[1] >> 5) & 3,
          mode3: !!(data[1] & 0x80),
          remain: v.getUint16(2, true),
          winner: data[4],
          winReason: data[5],
          link: data[6],
          gameType: data[7],
          teams: [team(0), team(1)],
          robots: [0, 1, 2, 3, 4, 5].map((r) => robotBlock(v, 24 + 30 * r)),
          rxOk: v.getUint16(204, true),
          rxErr: v.getUint16(206, true),
          combatTime: v.getUint16(208, true),
          setupTime: v.getUint16(210, true),
        };
      }
      case CMD.EVENT:
        return { robot: data[0], kind: data[1], detail: data[2], hp: v.getUint16(3, true) };
      default:
        return null;
    }
  } catch {
    return null; // short payload
  }
}

// ------------------------------------------------------------------ commands
function bytes(n, fill) {
  const b = new Uint8Array(n);
  fill(new DataView(b.buffer));
  return b;
}

export const commands = {
  game: (action) => [CMD.C_GAME, Uint8Array.of(action)],
  // gameType 5 = 1v1, 4 = 3v3; link = slot whose view the real frames give
  config: (c) => [CMD.C_CONFIG, bytes(6, (v) => {
    v.setUint8(0, c.gameType);
    v.setUint8(1, c.link);
    v.setUint16(2, c.combatTime, true);
    v.setUint16(4, c.setupTime, true);
  })],
  robot: (slot, c) => [CMD.C_ROBOT, bytes(15, (v) => {
    v.setUint8(0, slot);
    v.setUint8(1, (c.fielded ? 1 : 0) | (c.cal42 ? 2 : 0));
    [c.maxHp, c.heatLimit, c.cooling, c.powerLimit, c.speedLimit, c.allowance]
      .forEach((x, i) => v.setUint16(2 + 2 * i, x, true));
  })],
  hit: (slot, armor, kind = HIT_KIND.MM17) => [CMD.C_HIT, Uint8Array.of(slot, armor, kind)],
  // speed goes twice: as f32 for 0x0207, and in 0.1 m/s for the fabric's limit check
  shoot: (slot, freq, speed) => [CMD.C_SHOOT, bytes(8, (v) => {
    v.setUint8(0, slot);
    v.setUint8(1, freq);
    v.setFloat32(2, speed, true);
    v.setUint16(6, Math.round(speed * 10), true);
  })],
  penalty: (slot, level) => [CMD.C_PENALTY, Uint8Array.of(slot, level)],
  life: (slot, action) => [CMD.C_LIFE, Uint8Array.of(slot, action)],
  power: (slot, watts) => [CMD.C_POWER, bytes(3, (v) => {
    v.setUint8(0, slot);
    v.setUint16(1, watts, true);
  })],
  time: (unix) => [CMD.C_TIME, bytes(4, (v) => v.setUint32(0, unix >>> 0, true))],
  zone: (slot, zone) => [CMD.C_ZONE, Uint8Array.of(slot, zone)],
  exchange: (slot, n) => [CMD.C_EXCHANGE, bytes(3, (v) => {
    v.setUint8(0, slot);
    v.setUint16(1, n, true);
  })],
};

export function hex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(' ');
}
