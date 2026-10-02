// Demo-mode transport: a JavaScript copy of the fabric (arc_rx_parser +
// arc_ref_core + arc_frame_gen) that speaks the same byte stream as the
// Zybo, so the console can be developed and tested without hardware.
// Keep the rules in step with hw/rtl/arc_ref_core.v.

import { CMD, FrameDecoder, encode } from './protocol.js';

const ST = { IDLE: 0, PREP: 1, CHECK: 2, COUNT: 3, COMBAT: 4, RESULT: 5 };
const EV = { HIT: 1, SHOT: 2, OVERHEAT: 3, OVERPOWER: 4, YELLOW: 5, RED: 6, FORFEIT: 7, KILL: 8, REVIVE: 9 };
const BUFFER_FULL_X10 = 600;
const div10 = (x) => Math.floor(x / 10);
const u16 = (x) => Math.max(0, Math.min(0xffff, x));

export class SimLink {
  constructor() {
    this.onData = () => {};
    this.onClose = () => {};
    this.label = 'Demo (emulated board)';
    this.rx = new FrameDecoder(16);
  }

  async open() {
    this.reset();
    this.timer = setInterval(() => this.tick20(), 20);
    this.emitText('\r\nARC ref bridge ready (demo)\r\n');
  }

  async close() {
    clearInterval(this.timer);
    this.onClose('Demo stopped');
  }

  async write(bytes) {
    // Byte-level parse, same as the fabric parser (max 16-byte payload).
    const before = this.rx.bad;
    for (const f of this.rx.push(bytes)) {
      this.rxOk++;
      this.runCmd(f.cmd, f.data);
    }
    this.rxErr += this.rx.bad - before;
  }

  reset() {
    this.cfg = { combatTime: 180, maxHp: 200, heatLimit: 100, cooling: 20, powerLimit: 60, hitDmg: 10 };
    this.stage = ST.IDLE;
    this.paused = false;
    this.remain = 0;
    this.winner = 0;
    this.gameType = 5;
    this.link = 0;
    this.unix = 0;
    this.sub = 0;
    this.t5 = 0;
    this.t10 = 0;
    this.c50 = 0;
    this.c5 = 0;
    this.c17 = 0;
    this.seq = 0;
    this.rxOk = 0;
    this.rxErr = 0;
    this.robots = [0, 1].map(() => ({ hp: 200, heat10: 0, buf10: BUFFER_FULL_X10, power: 0, yellow: 0, red: false }));
  }

  // ------------------------------------------------------------- outputs
  emitText(s) {
    this.onData(new TextEncoder().encode(s));
  }

  send(cmd, payload) {
    this.onData(encode(cmd, payload, this.seq));
    this.seq = (this.seq + 1) & 0xff;
  }

  event(r, kind, detail, hp) {
    const p = new Uint8Array(5);
    const v = new DataView(p.buffer);
    v.setUint8(0, r);
    v.setUint8(1, kind);
    v.setUint8(2, detail & 0xff);
    v.setUint16(3, hp, true);
    this.send(CMD.EVENT, p);
  }

  sendStatus() {
    const p = new Uint8Array(11);
    const v = new DataView(p.buffer);
    v.setUint8(0, (this.stage << 4) | this.gameType);
    v.setUint16(1, this.remain, true);
    v.setUint32(3, this.unix, true);
    this.send(CMD.GAME_STATUS, p);
  }

  sendResult() {
    this.send(CMD.GAME_RESULT, Uint8Array.of(this.winner));
  }

  sendHp() {
    const p = new Uint8Array(32);
    const v = new DataView(p.buffer);
    v.setUint16(4, this.robots[0].hp, true);
    v.setUint16(20, this.robots[1].hp, true);
    this.send(CMD.ROBOT_HP, p);
  }

  sendRobotStatus() {
    const r = this.robots[this.link];
    const p = new Uint8Array(13);
    const v = new DataView(p.buffer);
    const alive = r.hp > 0 ? 1 : 0;
    v.setUint8(0, this.link ? 103 : 3);
    v.setUint8(1, 1);
    v.setUint16(2, r.hp, true);
    v.setUint16(4, this.cfg.maxHp, true);
    v.setUint16(6, this.cfg.cooling, true);
    v.setUint16(8, this.cfg.heatLimit, true);
    v.setUint16(10, this.cfg.powerLimit, true);
    v.setUint8(12, 1 | (alive << 1) | (alive << 2));
    this.send(CMD.ROBOT_STATUS, p);
  }

  sendPowerHeat() {
    const r = this.robots[this.link];
    const p = new Uint8Array(16);
    const v = new DataView(p.buffer);
    v.setUint16(0, 24000, true);
    v.setUint16(2, Math.floor((r.power * 42667) / 1024) & 0xffff, true);
    v.setFloat32(4, r.power, true);
    v.setUint16(8, div10(r.buf10), true);
    v.setUint16(10, div10(r.heat10), true);
    this.send(CMD.POWER_HEAT, p);
  }

  sendServer() {
    const p = new Uint8Array(49);
    const v = new DataView(p.buffer);
    v.setUint8(0, this.stage);
    v.setUint8(1, this.paused ? 1 : 0);
    v.setUint16(2, this.remain, true);
    v.setUint8(4, this.winner);
    v.setUint8(5, this.link);
    v.setUint8(6, this.gameType);
    this.robots.forEach((r, i) => {
      const o = 7 + 16 * i;
      v.setUint16(o, r.hp, true);
      v.setUint16(o + 2, this.cfg.maxHp, true);
      v.setUint16(o + 4, div10(r.heat10), true);
      v.setUint16(o + 6, this.cfg.heatLimit, true);
      v.setUint16(o + 8, div10(r.buf10), true);
      v.setUint16(o + 10, r.power, true);
      v.setUint16(o + 12, this.cfg.powerLimit, true);
      v.setUint8(o + 14, r.yellow);
      v.setUint8(o + 15, (r.hp > 0 ? 1 : 0) | (r.red ? 2 : 0));
    });
    v.setUint16(39, this.rxOk, true);
    v.setUint16(41, this.rxErr, true);
    v.setUint16(43, this.cfg.combatTime, true);
    v.setUint16(45, this.cfg.cooling, true);
    v.setUint16(47, this.cfg.hitDmg, true);
    this.send(CMD.SERVER_STATE, p);
  }

  // --------------------------------------------------------------- rules
  get inCombat() {
    return this.stage === ST.COMBAT && !this.paused;
  }

  damage(r, dmg, kind, detail, reason, armor) {
    const rb = this.robots[r];
    rb.hp = rb.hp > dmg ? rb.hp - dmg : 0;
    this.event(r, kind, detail, rb.hp);
    if (r === this.link) this.send(CMD.HURT, Uint8Array.of((reason << 4) | (armor & 0xf)));
  }

  warn(r, level, count) {
    if (r === this.link) this.send(CMD.REFEREE_WARNING, Uint8Array.of(level, r ? 103 : 3, count & 0xff));
  }

  resetRobots() {
    for (const rb of this.robots) {
      rb.hp = this.cfg.maxHp;
      rb.heat10 = 0;
      rb.buf10 = BUFFER_FULL_X10;
      rb.yellow = 0;
      rb.red = false;
    }
  }

  finish(w) {
    this.stage = ST.RESULT;
    this.remain = 0;
    this.paused = false;
    this.winner = w;
    this.sendResult();
    this.sendStatus();
  }

  hpWinner() {
    const [a, b] = this.robots;
    return a.hp > b.hp ? 1 : b.hp > a.hp ? 2 : 0;
  }

  hit(r, detail) {
    if (this.inCombat && this.robots[r].hp > 0) this.damage(r, this.cfg.hitDmg, EV.HIT, detail, 0, detail & 0xf);
  }

  runCmd(cmd, d) {
    const v = new DataView(d.buffer, d.byteOffset, d.byteLength);
    const r = (d[0] ?? 0) & 1;
    const a = d[1] ?? 0;
    const rb = this.robots[r];
    switch (cmd) {
      case CMD.C_GAME:
        switch (d[0]) {
          case 1:
            if (this.stage === ST.IDLE) { this.stage = ST.PREP; this.sendStatus(); }
            break;
          case 2:
            if (this.stage === ST.IDLE || this.stage === ST.PREP) {
              this.stage = ST.CHECK; this.remain = 15; this.sub = 0;
              this.paused = false; this.winner = 0;
              this.resetRobots();
              this.sendStatus();
            }
            break;
          case 3:
            if (this.stage >= ST.CHECK && this.stage <= ST.COMBAT) { this.paused = true; this.sendStatus(); }
            break;
          case 4:
            if (this.paused) { this.paused = false; this.sendStatus(); }
            break;
          case 5:
            if (this.stage >= ST.PREP && this.stage <= ST.COMBAT) this.finish(this.hpWinner());
            break;
          case 6:
            this.stage = ST.IDLE; this.remain = 0; this.paused = false; this.winner = 0;
            this.resetRobots();
            for (const x of this.robots) x.power = 0;
            this.sendStatus();
            break;
          default:
        }
        break;
      case CMD.C_CONFIG:
        if (this.stage === ST.IDLE && d.length >= 14) {
          this.gameType = d[0] & 0xf;
          this.link = d[1] & 1;
          this.cfg = {
            combatTime: v.getUint16(2, true),
            maxHp: v.getUint16(4, true),
            heatLimit: v.getUint16(6, true),
            cooling: v.getUint16(8, true),
            powerLimit: v.getUint16(10, true),
            hitDmg: v.getUint16(12, true),
          };
          for (const x of this.robots) x.hp = this.cfg.maxHp;
          this.sendStatus();
        }
        break;
      case CMD.C_HIT:
        this.hit(r, a & 3);
        break;
      case CMD.C_SHOOT:
        if (this.inCombat && rb.hp > 0) {
          rb.heat10 = u16(rb.heat10 + 100);
          this.event(r, EV.SHOT, a, rb.hp);
          if (r === this.link) {
            const p = new Uint8Array(7);
            p[0] = 1; p[1] = 1; p[2] = a;
            p.set(d.slice(2, 6), 3);
            this.send(CMD.SHOOT, p);
          }
        }
        break;
      case CMD.C_PENALTY:
        if (a === 2) {
          rb.yellow = (rb.yellow + 1) & 0xff;
          this.event(r, EV.YELLOW, rb.yellow, rb.hp);
          this.warn(r, 2, rb.yellow);
        } else if (a === 3) {
          rb.red = true; rb.hp = 0;
          this.event(r, EV.RED, 0, 0);
          this.warn(r, 3, 1);
        } else if (a === 4 && this.stage >= ST.PREP && this.stage <= ST.COMBAT) {
          this.event(r, EV.FORFEIT, 0, rb.hp);
          this.warn(r, 4, 1);
          this.finish(r ? 1 : 2);
        }
        break;
      case CMD.C_LIFE:
        if (a === 0) {
          rb.hp = 0;
          this.event(r, EV.KILL, 0, 0);
        } else {
          rb.hp = this.cfg.maxHp; rb.heat10 = 0; rb.red = false;
          this.event(r, EV.REVIVE, 0, rb.hp);
        }
        break;
      case CMD.C_POWER:
        rb.power = v.getUint16(1, true);
        break;
      case CMD.C_TIME:
        this.unix = v.getUint32(0, true);
        break;
      default:
    }
  }

  step100() {
    if (!this.paused && this.stage >= ST.CHECK && this.stage <= ST.COMBAT) {
      if (this.sub === 9) {
        this.sub = 0;
        if (this.remain > 1) this.remain--;
        else if (this.stage === ST.CHECK) { this.stage = ST.COUNT; this.remain = 5; this.sendStatus(); }
        else if (this.stage === ST.COUNT) { this.stage = ST.COMBAT; this.remain = this.cfg.combatTime; this.sendStatus(); }
        else this.finish(this.hpWinner());
      } else {
        this.sub++;
      }
    }
    for (let r = 0; r < 2; r++) {
      this.heatStep(r);
      this.powerStep(r);
    }
  }

  heatStep(r) {
    if (this.paused) return;
    const rb = this.robots[r];
    const lim10 = this.cfg.heatLimit * 10;
    rb.heat10 = rb.heat10 > this.cfg.cooling ? rb.heat10 - this.cfg.cooling : 0;
    if (this.inCombat && rb.hp > 0 && rb.heat10 > lim10) {
      this.damage(r, ((rb.heat10 - lim10) >> 6) + 1, EV.OVERHEAT, 0, 3, 0);
    }
  }

  powerStep(r) {
    const rb = this.robots[r];
    const lim = this.cfg.powerLimit;
    if (this.inCombat && rb.hp > 0) {
      if (rb.power > lim) {
        const d = rb.power - lim;
        if (rb.buf10 > d) rb.buf10 -= d;
        else {
          rb.buf10 = 0;
          this.damage(r, (d >> 2) + 1, EV.OVERPOWER, 0, 4, 0);
        }
      } else {
        rb.buf10 = Math.min(BUFFER_FULL_X10, rb.buf10 + (lim - rb.power));
      }
    } else if (!this.paused) {
      rb.buf10 = BUFFER_FULL_X10;
    }
  }

  tick20() {
    if (this.t5 === 4) {
      this.t5 = 0;
      if (this.t10 === 9) { this.t10 = 0; this.unix = (this.unix + 1) >>> 0; } else this.t10++;
      this.step100();
    } else {
      this.t5++;
    }
    // Same periodic schedule as arc_frame_gen.
    if (this.c50 === 0) this.sendStatus();
    if (this.c5 === 0) this.sendRobotStatus();
    this.sendPowerHeat();
    if (this.c17 === 0) this.sendHp();
    if (this.c5 === 2) this.sendServer();
    this.c50 = this.c50 === 49 ? 0 : this.c50 + 1;
    this.c5 = this.c5 === 4 ? 0 : this.c5 + 1;
    this.c17 = this.c17 === 16 ? 0 : this.c17 + 1;
  }
}
