// Cross-checks web/js/protocol.js against the RTL simulation output, and the
// JS emulator against the same four rounds. Run after `make sim`:
//   node web/test/protocol.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CMD, FrameDecoder, ROBOT_PRESETS, commands, crc8, crc16, decodePayload, encode } from '../js/protocol.js';
import { SimLink } from '../js/sim.js';

// Known-answer CRCs: table entries from the referee protocol.
assert.equal(crc8(Uint8Array.of(0x01), 0, 1, 0), 0x5e);
assert.equal(crc16(Uint8Array.of(0x01), 0, 1, 0), 0x1189);

// Round trip, split into odd-sized chunks with junk in between.
const frames = [encode(...commands.shoot(1, 7, 27.5), 9), encode(...commands.game(2), 10)];
const stream = Uint8Array.from([...new TextEncoder().encode('hi\r\n'), ...frames[0], 0x00, 0x13, ...frames[1]]);
const dec = new FrameDecoder();
let skipped = '';
dec.onSkipped = (b) => { skipped += new TextDecoder().decode(b); };
const got = [];
for (let i = 0; i < stream.length; i += 3) got.push(...dec.push(stream.subarray(i, i + 3)));
assert.equal(got.length, 2);
assert.equal(got[0].cmd, CMD.C_SHOOT);
assert.equal(got[0].seq, 9);
assert.equal(new DataView(got[0].data.buffer).getUint16(6, true), 275, 'speed in 0.1 m/s');
assert.ok(skipped.startsWith('hi'));

// Replay hw/sim/tb_arc_ref.v through the emulator (20 ms ticks).
function emulate() {
  const em = new SimLink();
  const out = new FrameDecoder();
  const seen = [];
  em.onData = (b) => seen.push(...out.push(b));
  em.reset();
  const tx = (c) => em.write(encode(...c));
  const run = (s) => { for (let i = 0; i < Math.round(s * 50); i++) em.tick20(); };
  const finals = [];
  // Snapshot the emulator's server state without disturbing its frame stream.
  const final = () => {
    const prev = em.onData;
    const seq = em.seq;
    let f;
    em.onData = (b) => { f = new FrameDecoder().push(b)[0]; };
    em.sendServer();
    em.onData = prev;
    em.seq = seq;
    finals.push(decodePayload(CMD.SERVER_STATE, f.data));
  };
  const inf = { ...ROBOT_PRESETS.infantry1v1, allowance: 10 };

  // 1v1 round 1
  tx(commands.time(1700000000));
  tx(commands.config({ gameType: 5, link: 1, combatTime: 30, setupTime: 3 }));
  tx(commands.robot(1, inf));
  tx(commands.robot(4, inf));
  tx(commands.game(1)); run(0.5);
  tx(commands.game(3)); run(1);
  tx(commands.game(4)); run(23);
  tx(commands.hit(1, 1));
  tx(commands.hit(1, 2));                    // BTN2 in the RTL test
  tx(commands.hit(4, 0, 1));
  for (let i = 0; i < 9; i++) tx(commands.shoot(1, 5, 25));
  run(0.2);
  tx(commands.shoot(1, 5, 25));
  tx(commands.shoot(4, 5, 31));
  tx(commands.shoot(4, 5, 25));
  tx(commands.penalty(1, 2));
  tx(commands.penalty(1, 2));
  tx(commands.power(4, 200));
  run(31);
  final();
  // 1v1 round 2
  tx(commands.game(6));
  tx(commands.game(2)); run(20.5);
  for (let i = 0; i < 3; i++) tx(commands.penalty(4, 2));
  run(1);
  final();
  // 3v3 round 1
  tx(commands.game(6));
  tx(commands.config({ gameType: 4, link: 1, combatTime: 65, setupTime: 3 }));
  const hero = ROBOT_PRESETS.hero;
  const inf3 = { fielded: true, cal42: false, maxHp: 350, heatLimit: 88, cooling: 24, powerLimit: 75, speedLimit: 25, allowance: 0 };
  const sentry = ROBOT_PRESETS.sentry;
  for (const base of [0, 3]) {
    tx(commands.robot(base, hero));
    tx(commands.robot(base + 1, inf3));
    tx(commands.robot(base + 2, sentry));
  }
  tx(commands.game(2)); run(20.5);
  tx(commands.zone(1, 1));
  tx(commands.exchange(1, 100));
  tx(commands.exchange(0, 5));
  tx(commands.zone(0, 1));
  tx(commands.exchange(0, 5));
  tx(commands.hit(4, 0, 2));
  tx(commands.shoot(0, 1, 14));
  tx(commands.hit(4, 1, 2));
  tx(commands.zone(5, 2));
  for (let i = 0; i < 8; i++) tx(commands.hit(2, 2));
  tx(commands.zone(1, 0));
  for (let i = 0; i < 18; i++) tx(commands.hit(1, 0));
  run(5.5);
  tx(commands.shoot(1, 5, 20));
  tx(commands.hit(1, 0));
  tx(commands.zone(1, 1));
  run(2.2);
  tx(commands.penalty(2, 2));
  run(60);
  final();
  // 3v3 round 2
  tx(commands.game(6));
  tx(commands.game(2)); run(20.5);
  tx(commands.penalty(5, 3)); run(6);
  tx(commands.penalty(1, 4)); run(0.5);
  final();
  return { finals, frames: seen };
}

const summary = (s) => ({
  stage: s.stage, winner: s.winner, winReason: s.winReason,
  teams: s.teams.map((t) => ({ vp: t.vp, coins: t.coins, damage: t.damage })),
  robots: s.robots.map((r) => ({ hp: r.hp, allowance: r.allowance, shots: r.shots, yellow: r.yellow, redCard: r.redCard })),
});

const em = emulate();
assert.deepEqual(em.finals.map((f) => [f.winner, f.winReason]), [[2, 2], [1, 1], [2, 9], [2, 7]],
  'emulator: blue on HP, red by defeat, blue on VP, blue by forfeit');
for (const f of em.frames) assert.ok(decodePayload(f.cmd, f.data), `emulator frame 0x${f.cmd.toString(16)} decodes`);

// Decode the RTL simulation dump, if present, and compare.
let hexDump;
try {
  hexDump = readFileSync(new URL('../../hw/sim/out/tx_bytes.hex', import.meta.url), 'utf8');
} catch {
  console.log('protocol.js and sim.js ok (no simulation dump; run `make sim` to cross-check the RTL)');
  process.exit(0);
}
const bytes = Uint8Array.from(hexDump.trim().split(/\s+/), (h) => parseInt(h, 16));
const d2 = new FrameDecoder();
const rtl = d2.push(bytes);
assert.equal(d2.bad, 0, 'RTL frames decode without CRC errors');
for (const c of [0x0001, 0x0002, 0x0003, 0x0101, 0x0104, 0x0201, 0x0202, 0x0204, 0x0206, 0x0207, 0xf101, 0xf102]) {
  const fs = rtl.filter((x) => x.cmd === c);
  assert.ok(fs.length > 0, `RTL produced 0x${c.toString(16)}`);
  for (const f of fs) assert.ok(decodePayload(c, f.data), `decode 0x${c.toString(16)}`);
}
// The settlement state right after each 0x0002.
const rtlFinals = [];
rtl.forEach((f, i) => {
  if (f.cmd !== CMD.GAME_RESULT) return;
  const s = rtl.slice(i).find((x) => x.cmd === CMD.SERVER_STATE && x.data[0] === 5);
  rtlFinals.push(decodePayload(CMD.SERVER_STATE, s.data));
});
assert.equal(rtlFinals.length, 4);
rtlFinals.forEach((r, k) => assert.deepEqual(summary(em.finals[k]), summary(r), `emulator matches RTL after round ${k + 1}`));
console.log(`protocol.js ok; decoded ${rtl.length} RTL frames`);
console.log('sim.js matches RTL in all 4 rounds; final HP:', JSON.stringify(rtlFinals.map((s) => s.robots.map((r) => r.hp))));
