// Cross-checks web/js/protocol.js against the RTL simulation output and the
// JS emulator against the same rules. Run after `make sim`:
//   node web/test/protocol.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { CMD, FrameDecoder, commands, crc8, crc16, decodePayload, encode } from '../js/protocol.js';

// Known-answer CRCs: table entries from the referee protocol appendix.
assert.equal(crc8(Uint8Array.of(0x01), 0, 1, 0), 0x5e);
assert.equal(crc16(Uint8Array.of(0x01), 0, 1, 0), 0x1189);

// Round trip through encode/decode, split into odd-sized chunks with junk in between.
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
assert.ok(skipped.startsWith('hi'));

// Decode the RTL simulation dump, if present.
let hexDump;
try {
  hexDump = readFileSync(new URL('../../hw/sim/out/tx_bytes.hex', import.meta.url), 'utf8');
} catch {
  console.log('protocol.js ok (no simulation dump; run `make sim` to cross-check the RTL)');
  process.exit(0);
}
const bytes = Uint8Array.from(hexDump.trim().split(/\s+/), (h) => parseInt(h, 16));
const d2 = new FrameDecoder();
const sim = d2.push(bytes);
assert.equal(d2.bad, 0, 'RTL frames decode without CRC errors');
const counts = {};
for (const f of sim) counts[f.cmd] = (counts[f.cmd] || 0) + 1;
for (const c of [0x0001, 0x0002, 0x0003, 0x0104, 0x0201, 0x0202, 0x0206, 0x0207, 0xf101, 0xf102]) {
  assert.ok(counts[c] > 0, `RTL produced 0x${c.toString(16)}`);
  for (const f of sim.filter((x) => x.cmd === c)) assert.ok(decodePayload(c, f.data), `decode 0x${c.toString(16)}`);
}
const last = decodePayload(CMD.SERVER_STATE, sim.filter((f) => f.cmd === CMD.SERVER_STATE).at(-1).data);
assert.equal(last.stage, 5);
assert.equal(last.rxOk, 14);
assert.equal(last.rxErr, 1);
const shot = decodePayload(CMD.SHOOT, sim.find((f) => f.cmd === CMD.SHOOT).data);
assert.equal(shot.speed, 25);
console.log(`protocol.js ok; decoded ${sim.length} RTL frames`, counts);

// Replay the testbench scenario through the JS emulator; it must end the same
// way as the RTL (same rules, same 100 ms schedule).
const { SimLink } = await import('../js/sim.js');
const em = new SimLink();
const out = new FrameDecoder();
const emFrames = [];
em.onData = (b) => emFrames.push(...out.push(b));
em.reset();
const tx = (c) => em.write(encode(...c));
await tx(commands.time(1700000000));
await tx(commands.config({ gameType: 5, link: 0, combatTime: 10, maxHp: 100, heatLimit: 50, cooling: 10, powerLimit: 60, hitDmg: 10 }));
await tx(commands.game(2));
for (let i = 0; i < 1025; i++) em.tick20();
await tx(commands.hit(0, 1));
await tx(commands.hit(0, 2));                // the RTL test uses BTN2 here
for (let i = 0; i < 7; i++) await tx(commands.shoot(0, 5, 25));
await tx(commands.penalty(1, 2));
await tx(commands.penalty(0, 2));
await tx(commands.power(1, 100));
for (let i = 0; i < 550; i++) em.tick20();
const emLast = decodePayload(CMD.SERVER_STATE, emFrames.filter((f) => f.cmd === CMD.SERVER_STATE).at(-1).data);
assert.equal(emLast.stage, 5);
assert.deepEqual(emLast.robots.map((r) => r.hp), last.robots.map((r) => r.hp), 'emulator matches RTL final HP');
console.log('sim.js matches RTL: final HP', emLast.robots.map((r) => r.hp));
