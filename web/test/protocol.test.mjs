// Cross-checks web/js/protocol.js against the RTL simulation output, and the
// JS emulator against the same scenario. Run after `make sim`:
//   node web/test/protocol.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CMD, FrameDecoder, commands, crc8, crc16, decodePayload, encode } from '../js/protocol.js';
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
  const shot = (r, v) => tx(commands.shoot(r, 5, v));
  tx(commands.time(1700000000));
  tx(commands.config({ gameType: 5, link: 0, combatTime: 30, maxHp: 200, heatLimit: 80, cooling: 12,
    powerLimit: 120, hitDmg: 20, setupTime: 3, speedLimit: 25, allowance: 10 }));
  tx(commands.game(1));
  run(0.5);
  tx(commands.game(3));
  run(1);
  tx(commands.game(4));
  run(23);
  tx(commands.hit(0, 1));
  tx(commands.hit(0, 2));                  // BTN2 in the RTL test
  tx(commands.hit(1, 0, 1));               // collision
  for (let i = 0; i < 9; i++) shot(0, 25);
  run(0.2);
  shot(0, 25);
  shot(1, 31);
  shot(1, 25);
  tx(commands.penalty(0, 2));
  tx(commands.penalty(0, 2));
  tx(commands.power(1, 200));
  run(31);
  const round1 = decodePayload(CMD.SERVER_STATE, seen.filter((f) => f.cmd === CMD.SERVER_STATE).at(-1).data);
  tx(commands.game(6));
  tx(commands.game(2));
  run(20.5);
  for (let i = 0; i < 3; i++) tx(commands.penalty(1, 2));
  run(1);
  const round2 = decodePayload(CMD.SERVER_STATE, seen.filter((f) => f.cmd === CMD.SERVER_STATE).at(-1).data);
  return { round1, round2, frames: seen };
}

const summary = (s) => ({
  stage: s.stage, winner: s.winner, winReason: s.winReason,
  robots: s.robots.map((r) => ({ hp: r.hp, allowance: r.allowance, shots: r.shots, yellow: r.yellow, redCard: r.redCard })),
});

const em = emulate();
assert.equal(em.round1.winner, 2, 'emulator round 1: blue wins on HP');
assert.equal(em.round2.winner, 1, 'emulator round 2: red wins by defeat');
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
const counts = {};
for (const f of rtl) counts[f.cmd] = (counts[f.cmd] || 0) + 1;
for (const c of [0x0001, 0x0002, 0x0003, 0x0104, 0x0201, 0x0202, 0x0206, 0x0207, 0xf101, 0xf102]) {
  assert.ok(counts[c] > 0, `RTL produced 0x${c.toString(16)}`);
  for (const f of rtl.filter((x) => x.cmd === c)) assert.ok(decodePayload(c, f.data), `decode 0x${c.toString(16)}`);
}
const srv = rtl.filter((f) => f.cmd === CMD.SERVER_STATE).map((f) => decodePayload(CMD.SERVER_STATE, f.data));
const firstEnd = srv.findIndex((s) => s.stage === 5);
const rtlRound1 = srv[srv.findIndex((s, i) => i > firstEnd && s.stage !== 5) - 1];
const rtlRound2 = srv.at(-1);
assert.deepEqual(summary(em.round1), summary(rtlRound1), 'emulator matches RTL after round 1');
assert.deepEqual(summary(em.round2), summary(rtlRound2), 'emulator matches RTL after round 2');
console.log(`protocol.js ok; decoded ${rtl.length} RTL frames`);
console.log('sim.js matches RTL:', JSON.stringify([summary(rtlRound1), summary(rtlRound2)].map((s) => s.robots.map((r) => r.hp))));
