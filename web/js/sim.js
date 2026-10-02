// Demo-mode transport: a JavaScript copy of the fabric (arc_rx_parser +
// arc_ref_core + arc_frame_gen) that speaks the same byte stream as the
// Zybo, so the console can be developed and tested without hardware.
// Keep the rules in step with hw/rtl/arc_ref_core.v; web/test checks that a
// replay of the RTL testbench ends the same way.

import { CMD, FrameDecoder, encode } from './protocol.js';

const N = 6;
const ST = { IDLE: 0, PREP: 1, CHECK: 2, COUNT: 3, COMBAT: 4, RESULT: 5 };
const EV = {
  HIT: 1, SHOT: 2, LOCK: 3, CHASSIS: 4, YELLOW: 5, RED: 6, FORFEIT: 7, KILL: 8, REVIVE: 9,
  DISCONNECT: 10, RECONNECT: 11, OFFLINE_HP: 12, UNLOCK: 13, YELLOW_BOTH: 14, EXCHANGE: 15,
  IMMUNE: 16, RESPAWN: 17, CAPTURE: 18, YELLOW_TEAM: 19,
};
const LK = { HEAT: 1, HEAT_ROUND: 2, SPEED15: 3, SPEED20: 4, SPEED_ROUND: 5, AMMO: 6 };
const WR = {
  NONE: 0, DEFEAT: 1, HP: 2, FIRST_DMG: 3, SHOTS: 4, FIRST_SHOT: 5, TIE: 6, FORFEIT: 7,
  VP_ZERO: 8, VP: 9, DAMAGE: 10, TOTAL_HP: 11,
};
const BUFFER_FULL_X10 = 600;
const LOCK_ROUND = 0xffff;
const div10 = (x) => Math.floor(x / 10);
const pctOf = (x, p) => Math.floor((x * p + 50) / 100);
const satSub = (a, b) => (a > b ? a - b : 0);
const teamOf = (r) => (r >= 3 ? 1 : 0);
const roleOf = (r) => r % 3;   // 0 hero, 1 infantry, 2 sentry
const robotId = (r) => (r >= 3 ? 100 : 0) + [1, 3, 7][r % 3];
const penaltyHp = (h, ded) => (h === 0 ? 0 : h <= ded ? 1 : h - ded);

function robotConfig(fielded, cal42, maxHp, heatLimit, cooling, powerLimit, speedLimit, allowance) {
  return {
    fielded, cal42, maxHp, heatLimit, cooling, powerLimit, speedLimit, allowance,
    p5: pctOf(maxHp, 5), p15: pctOf(maxHp, 15), p20: pctOf(maxHp, 20), p25: pctOf(maxHp, 25),
  };
}

export class SimLink {
  constructor() {
    this.onData = () => {};
    this.onClose = () => {};
    this.label = 'Demo (emulated board)';
    this.rx = new FrameDecoder(24);
  }

  async open() {
    this.reset();
    this.timer = setInterval(() => this.tick20(), 20);
    this.onData(new TextEncoder().encode('\r\nARC ref bridge ready (demo)\r\n'));
  }

  async close() {
    clearInterval(this.timer);
    this.onClose('Demo stopped');
  }

  async write(bytes) {
    const before = this.rx.bad;
    for (const f of this.rx.push(bytes)) {
      this.rxOk++;
      this.runCmd(f.cmd, f.data);
      this.runPenalties();
    }
    this.rxErr += this.rx.bad - before;
  }

  reset() {
    Object.assign(this, {
      stage: ST.IDLE, paused: false, remain: 0, gameType: 5, link: 1, unix: 0,
      combatTime: 120, setupTime: 120, sub: 0, t5: 0, t10: 0, c50: 0, c5: 0, c17: 0,
      seq: 0, rxOk: 0, rxErr: 0, warnL: [0, 0, 0], penMask: 0, penKind: 0,
    });
    this.cfg = Array.from({ length: N }, (_, i) => robotConfig(i === 1 || i === 4, false, 200, 80, 12, 120, 25, 200));
    this.robots = Array.from({ length: N }, () => ({ power: 0 }));
    this.teams = [{}, {}];
    this.resetRobots();
  }

  resetRobots() {
    this.robots.forEach((rb, i) => {
      const c = this.cfg[i];
      Object.assign(rb, {
        hp: c.fielded ? c.maxHp : 0, heat10: 0, buf10: BUFFER_FULL_X10, ammo: c.allowance, shots: 0,
        yellow: 0, yelK: 0, yelWin: 0, red: false, heatLk: 0, spdLk: 0, chOff: 0, disc: false,
        secT: 0, zone: 0, respT: 0, defeats: 0, invinc: 0, weak: false,
      });
    });
    for (const t of this.teams) Object.assign(t, { vp: 200, coins: 0, dmg: 0, hquiet: 255, hdown: 0 });
    Object.assign(this, {
      bonus: [false, false], vpT: 0, capHolder: 0, penMask: 0, bothYellow: 0,
      firstDmg: 0, firstShot: 0, winner: 0, winReason: WR.NONE,
    });
  }

  get mode3() {
    return this.gameType === 4;
  }

  get inCombat() {
    return this.stage === ST.COMBAT && !this.paused;
  }

  alive(r) {
    return this.cfg[r].fielded && this.robots[r].hp > 0;
  }

  heroLive(t) {
    const tm = this.teams[t];
    return !(tm.hquiet >= 40 || tm.hdown >= 30 || !this.cfg[3 * t].fielded);
  }

  flags(r) {
    const rb = this.robots[r];
    const al = this.alive(r);
    const gim = al && !rb.disc;
    const chs = gim && rb.chOff === 0;
    const sht = gim && !rb.heatLk && !rb.spdLk && rb.ammo > 0 && !rb.weak;
    return (al ? 1 : 0) | (rb.red ? 2 : 0) | (sht ? 4 : 0) | (chs ? 8 : 0) | (gim ? 16 : 0)
      | (rb.disc ? 32 : 0) | (rb.heatLk ? 64 : 0) | (rb.spdLk ? 128 : 0);
  }

  flags2(r) {
    const rb = this.robots[r];
    const c = this.cfg[r];
    return (c.fielded ? 1 : 0) | (c.cal42 ? 2 : 0) | (rb.invinc ? 4 : 0) | (rb.weak ? 8 : 0)
      | (rb.respT ? 16 : 0) | (rb.zone << 5);
  }

  inResupply(t) {
    return [0, 1, 2].some((k) => this.robots[3 * t + k].zone === 1 && this.alive(3 * t + k));
  }

  // ------------------------------------------------------------- outputs
  send(cmd, payload) {
    this.onData(encode(cmd, payload, this.seq));
    this.seq = (this.seq + 1) & 0xff;
  }

  event(r, kind, detail, value) {
    const p = new Uint8Array(5);
    const v = new DataView(p.buffer);
    v.setUint8(0, r);
    v.setUint8(1, kind);
    v.setUint8(2, detail & 0xff);
    v.setUint16(3, value & 0xffff, true);
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

  sendWarn() {
    this.send(CMD.REFEREE_WARNING, Uint8Array.from(this.warnL));
  }

  sendHp() {
    const t = teamOf(this.link);
    const p = new Uint8Array(16);
    const v = new DataView(p.buffer);
    v.setUint16(0, this.robots[3 * t].hp, true);
    v.setUint16(4, this.robots[3 * t + 1].hp, true);
    v.setUint16(10, this.robots[3 * t + 2].hp, true);
    this.send(CMD.ROBOT_HP, p);
  }

  capView() {
    const lt = teamOf(this.link);
    if (this.capHolder === 3) return 3;
    if (this.capHolder === 0) return 0;
    return this.capHolder === lt + 1 ? 1 : 2;
  }

  sendField() {
    const x = this.mode3 ? ((this.inResupply(teamOf(this.link)) ? 1 : 0) << 2) | (this.capView() << 23) : 0;
    const p = new Uint8Array(4);
    new DataView(p.buffer).setUint32(0, x >>> 0, true);
    this.send(CMD.FIELD_EVENT, p);
  }

  sendBuff() {
    const r = this.link;
    const rb = this.robots[r];
    const heal = this.mode3 && this.alive(r) && rb.zone === 1;
    const p = Uint8Array.of(heal ? 25 : 0, 0, 0, rb.invinc ? 100 : 0, 0, 0, 0, 0x80);
    this.send(CMD.BUFF, p);
  }

  sendRobotStatus() {
    const r = this.link;
    const f = this.flags(r);
    const c = this.cfg[r];
    const p = new Uint8Array(13);
    const v = new DataView(p.buffer);
    v.setUint8(0, robotId(r));
    v.setUint8(1, 1);
    v.setUint16(2, this.robots[r].hp, true);
    v.setUint16(4, c.maxHp, true);
    v.setUint16(6, c.cooling, true);
    v.setUint16(8, c.heatLimit, true);
    v.setUint16(10, c.powerLimit, true);
    v.setUint8(12, ((f >> 4) & 1) | (((f >> 3) & 1) << 1) | (((f >> 2) & 1) << 2));
    this.send(CMD.ROBOT_STATUS, p);
  }

  sendPowerHeat() {
    const rb = this.robots[this.link];
    const p = new Uint8Array(14);
    const v = new DataView(p.buffer);
    v.setUint16(8, div10(rb.buf10), true);
    v.setUint16(this.cfg[this.link].cal42 ? 12 : 10, div10(rb.heat10), true);
    this.send(CMD.POWER_HEAT, p);
  }

  sendServer() {
    const p = new Uint8Array(212);
    const v = new DataView(p.buffer);
    v.setUint8(0, this.stage);
    v.setUint8(1, (this.paused ? 1 : 0) | (this.firstDmg << 1) | (this.firstShot << 3)
      | (this.capHolder << 5) | (this.mode3 ? 0x80 : 0));
    v.setUint16(2, this.remain, true);
    v.setUint8(4, this.winner);
    v.setUint8(5, this.winReason);
    v.setUint8(6, this.link);
    v.setUint8(7, this.gameType);
    this.teams.forEach((t, i) => {
      v.setUint16(8 + 8 * i, t.vp, true);
      v.setUint16(10 + 8 * i, t.coins & 0xffff, true);
      v.setUint16(12 + 8 * i, t.dmg & 0xffff, true);
      v.setUint8(14 + 8 * i, this.heroLive(i) ? 1 : 0);
    });
    this.robots.forEach((rb, i) => {
      const o = 24 + 30 * i;
      const c = this.cfg[i];
      [rb.hp, c.maxHp, rb.heat10, c.heatLimit, rb.buf10, rb.power, c.powerLimit, rb.ammo, rb.shots,
        c.cooling, c.speedLimit].forEach((x, k) => v.setUint16(o + 2 * k, x & 0xffff, true));
      v.setUint8(o + 22, rb.yellow);
      v.setUint8(o + 23, this.flags(i));
      v.setUint8(o + 24, this.flags2(i));
      v.setUint8(o + 25, rb.chOff);
      v.setUint16(o + 26, rb.spdLk, true);
      v.setUint16(o + 28, rb.respT ? rb.respT : rb.invinc, true);
    });
    [this.rxOk, this.rxErr, this.combatTime, this.setupTime].forEach((x, k) => v.setUint16(204 + 2 * k, x & 0xffff, true));
    this.send(CMD.SERVER_STATE, p);
  }

  // --------------------------------------------------------------- rules
  finish(w, why) {
    if (this.stage === ST.RESULT) return;
    Object.assign(this, { stage: ST.RESULT, remain: 0, paused: false, winner: w, winReason: why });
    this.send(CMD.GAME_RESULT, Uint8Array.of(w));
    this.sendStatus();
  }

  loseVp(t, n) {
    const v = satSub(this.teams[t].vp, n);
    this.teams[t].vp = v;
    if (v === 0 && this.stage === ST.COMBAT) this.finish(t ? 1 : 2, WR.VP_ZERO);
  }

  setHp(r, nh, attack, eject = false) {
    const rb = this.robots[r];
    const t = teamOf(r);
    const old = rb.hp;
    if (attack && nh < old) this.teams[t ^ 1].dmg += old - nh;
    if (this.inCombat && this.firstDmg === 0 && !this.mode3) this.firstDmg = t ? 2 : 1;
    rb.hp = nh;
    if (this.stage === ST.COMBAT && nh === 0 && old !== 0) {
      if (!this.mode3) {
        this.finish(t ? 1 : 2, WR.DEFEAT);
      } else {
        rb.heat10 = 0;
        rb.buf10 = BUFFER_FULL_X10;
        if (rb.heatLk === 1) rb.heatLk = 0;
        rb.invinc = 0;
        rb.weak = false;
        if (!rb.red && !eject) rb.respT = 50 * (rb.defeats + 1);
        rb.defeats++;
        this.loseVp(t, 20);
      }
    }
  }

  warn(r, level, id, count) {
    if (teamOf(r) === teamOf(this.link)) {
      this.warnL = [level, id, count & 0xff];
      this.sendWarn();
    }
  }

  judge() {
    const rb = this.robots;
    if (this.mode3) {
      const [a, b] = this.teams;
      const th = (t) => [0, 1, 2].reduce((s, k) => s + (this.cfg[3 * t + k].fielded ? rb[3 * t + k].hp : 0), 0);
      if (a.vp !== b.vp) return [a.vp > b.vp ? 1 : 2, WR.VP];
      if (a.dmg !== b.dmg) return [a.dmg > b.dmg ? 1 : 2, WR.DAMAGE];
      if (th(0) !== th(1)) return [th(0) > th(1) ? 1 : 2, WR.TOTAL_HP];
      return [0, WR.TIE];
    }
    const [a, b] = [rb[1], rb[4]];
    if (a.hp !== b.hp) return [a.hp > b.hp ? 1 : 2, WR.HP];
    if (a.hp !== this.cfg[1].maxHp && this.firstDmg) return [this.firstDmg === 1 ? 2 : 1, WR.FIRST_DMG];
    if (a.shots !== b.shots) return [a.shots > b.shots ? 1 : 2, WR.SHOTS];
    if (this.firstShot) return [this.firstShot, WR.FIRST_SHOT];
    return [0, WR.TIE];
  }

  hit(r, armor, kind) {
    const rb = this.robots[r];
    const t = teamOf(r);
    if (!(this.inCombat && this.alive(r) && !rb.disc && !(this.mode3 && rb.invinc))) return;
    if (kind === 2 && this.mode3 && !this.heroLive(t ^ 1)) {
      this.event(r, EV.IMMUNE, armor, rb.hp);
      return;
    }
    const d = kind === 1 ? 2 : kind === 2 ? 200 : 20;
    const nh = satSub(rb.hp, d);
    if (r === this.link) this.send(CMD.HURT, Uint8Array.of(((kind === 1 ? 5 : 0) << 4) | (armor & 0xf)));
    this.event(r, EV.HIT, (kind === 1 ? 0x40 : 0) | (kind === 2 ? 0x20 : 0) | (armor & 0xf), nh);
    this.setHp(r, nh, kind !== 1);
  }

  yellowCard(r) {
    const rb = this.robots[r];
    const c = this.cfg[r];
    const t = teamOf(r);
    const cnt = (rb.yellow + 1) & 0xff;
    const k = rb.yelWin ? Math.min(rb.yelK + 1, 3) : 0;
    rb.yellow = cnt;
    rb.yelK = k;
    rb.yelWin = 300;
    this.warn(r, 2, robotId(r), cnt);
    if (cnt >= 3) {
      rb.red = true;
      this.event(r, EV.YELLOW, cnt, 0);
      this.event(r, EV.RED, 1, 0);
      this.setHp(r, 0, true, true);
    } else {
      const nh = penaltyHp(rb.hp, (c.p15 << k) & 0xffff);
      this.event(r, EV.YELLOW, cnt, nh);
      if (nh !== rb.hp) this.setHp(r, nh, true);
      if (this.mode3 && roleOf(r) === 2) rb.chOff = 20;
    }
    if (this.mode3) {
      this.penKind = EV.YELLOW_TEAM;
      this.penMask = (t ? 0b111000 : 0b000111) & ~(1 << r);
    }
  }

  // 5 % penalties to several robots (one per cycle in the fabric)
  runPenalties() {
    for (let i = 0; i < N && this.penMask; i++) {
      if (!(this.penMask & (1 << i))) continue;
      this.penMask &= ~(1 << i);
      if (!this.alive(i)) continue;
      const nh = penaltyHp(this.robots[i].hp, this.cfg[i].p5);
      this.event(i, this.penKind, this.penKind === EV.YELLOW_BOTH ? this.bothYellow : 0, nh);
      this.setHp(i, nh, this.penKind === EV.YELLOW_TEAM);
    }
  }

  runCmd(cmd, d) {
    const v = new DataView(d.buffer, d.byteOffset, d.byteLength);
    const r = Math.min(5, (d[0] ?? 0) & 7);
    const t = teamOf(r);
    const a = d[1] ?? 0;
    const rb = this.robots[r];
    const c = this.cfg[r];
    switch (cmd) {
      case CMD.C_GAME:
        switch (d[0]) {
          case 1:
            if (this.stage === ST.IDLE) {
              Object.assign(this, { stage: ST.PREP, remain: this.setupTime, sub: 0, paused: false });
              this.sendStatus();
            }
            break;
          case 2:
            if (this.stage === ST.IDLE || this.stage === ST.PREP) {
              Object.assign(this, { stage: ST.CHECK, remain: 15, sub: 0, paused: false });
              this.resetRobots();
              this.sendStatus();
            }
            break;
          case 3:
            if (this.stage >= ST.PREP && this.stage <= ST.COMBAT && !this.paused) { this.paused = true; this.sendStatus(); }
            break;
          case 4:
            if (this.paused) { this.paused = false; this.sendStatus(); }
            break;
          case 5:
            if (this.stage >= ST.PREP && this.stage <= ST.COMBAT) this.finish(...this.judge());
            break;
          case 6:
            Object.assign(this, { stage: ST.IDLE, remain: 0, paused: false, warnL: [0, 0, 0] });
            this.resetRobots();
            for (const x of this.robots) x.power = 0;
            this.sendWarn();
            this.sendStatus();
            break;
          default:
        }
        break;
      case CMD.C_CONFIG:
        if (this.stage === ST.IDLE && d.length >= 6) {
          this.gameType = d[0] & 0xf;
          this.link = Math.min(5, d[1] & 7);
          this.combatTime = v.getUint16(2, true);
          this.setupTime = v.getUint16(4, true);
          this.sendStatus();
        }
        break;
      case CMD.C_ROBOT:
        if ((this.stage === ST.IDLE || this.stage === ST.PREP) && d.length >= 15) {
          const g = (k) => v.getUint16(2 + 2 * k, true);
          this.cfg[r] = robotConfig(!!(a & 1), !!(a & 2), g(0), g(1), g(2), g(3), g(4), g(5));
          rb.hp = this.cfg[r].fielded ? this.cfg[r].maxHp : 0;
          rb.ammo = this.cfg[r].allowance;
          this.sendStatus();
        }
        break;
      case CMD.C_HIT:
        this.hit(r, a & 0xf, d.length >= 3 ? d[2] & 3 : 0);
        break;
      case CMD.C_SHOOT:
        if (this.inCombat && (this.flags(r) & 4)) {
          rb.heat10 = Math.min(0xffff, rb.heat10 + (c.cal42 ? 1000 : 100));
          rb.ammo--;
          rb.shots++;
          if (!this.firstShot && !this.mode3) this.firstShot = t ? 2 : 1;
          if (c.cal42 && roleOf(r) === 0) this.teams[t].hquiet = 0;
          this.event(r, EV.SHOT, a, rb.ammo);
          const sp = d.length >= 8 ? v.getUint16(6, true) : 0;
          const lim10 = c.speedLimit * 10;
          if (sp > lim10) {
            let lk;
            if (c.cal42) {
              lk = sp <= lim10 + c.speedLimit ? [150, LK.SPEED15] : sp <= lim10 + 2 * c.speedLimit ? [200, LK.SPEED20] : [LOCK_ROUND, LK.SPEED_ROUND];
            } else {
              lk = sp - lim10 < 50 ? [150, LK.SPEED15] : sp - lim10 < 100 ? [200, LK.SPEED20] : [LOCK_ROUND, LK.SPEED_ROUND];
            }
            if (rb.spdLk !== LOCK_ROUND && lk[0] > rb.spdLk) rb.spdLk = lk[0];
            this.event(r, EV.LOCK, lk[1], rb.hp);
          } else if (rb.ammo === 0) {
            this.event(r, EV.LOCK, LK.AMMO, rb.hp);
          }
          if (r === this.link) {
            const p = new Uint8Array(7);
            p[0] = c.cal42 ? 2 : 1;
            p[1] = c.cal42 ? 3 : 1;
            p[2] = a;
            p.set(d.slice(2, 6), 3);
            this.send(CMD.SHOOT, p);
          }
        }
        break;
      case CMD.C_PENALTY:
        if (a === 1) {
          this.bothYellow = (this.bothYellow + 1) & 0xff;
          this.penKind = EV.YELLOW_BOTH;
          this.penMask = 0b111111;
          this.warn(this.link, 1, 0, this.bothYellow);
        } else if (a === 2) {
          this.yellowCard(r);
        } else if (a === 3) {
          rb.red = true;
          this.event(r, EV.RED, 0, 0);
          this.warn(r, 3, robotId(r), 1);
          this.setHp(r, 0, true, true);
        } else if (a === 4 && this.stage >= ST.PREP && this.stage <= ST.COMBAT) {
          if (this.mode3) {
            this.teams[t].vp = 0;
          } else if (this.stage !== ST.COMBAT) {
            rb.hp = 0;
            this.robots[t ? 1 : 4].hp = this.cfg[t ? 1 : 4].maxHp;
          }
          this.event(r, EV.FORFEIT, 0, rb.hp);
          this.warn(r, 4, 0, 1);
          this.finish(t ? 1 : 2, WR.FORFEIT);
        }
        break;
      case CMD.C_LIFE:
        if (a === 0 && c.fielded) {
          this.event(r, EV.KILL, 0, 0);
          this.setHp(r, 0, false);
        } else if (a === 1 && c.fielded) {
          Object.assign(rb, { hp: c.maxHp, heat10: 0, red: false, heatLk: 0, spdLk: 0, disc: false, respT: 0, weak: false, invinc: 0 });
          this.event(r, EV.REVIVE, 0, rb.hp);
        } else if (a === 2 && c.fielded && !rb.disc) {
          rb.disc = true;
          rb.secT = 0;
          this.event(r, EV.DISCONNECT, 0, rb.hp);
        } else if (a === 3 && rb.disc) {
          rb.disc = false;
          this.event(r, EV.RECONNECT, 0, rb.hp);
        }
        break;
      case CMD.C_POWER:
        rb.power = v.getUint16(1, true);
        break;
      case CMD.C_TIME:
        this.unix = v.getUint32(0, true);
        break;
      case CMD.C_ZONE:
        rb.zone = a & 3;
        if (this.mode3 && (a & 3) === 1 && this.alive(r)) {
          rb.weak = false;
          rb.invinc = 0;
        }
        break;
      case CMD.C_EXCHANGE: {
        const n = d.length >= 3 ? v.getUint16(1, true) : 0;
        const cost = c.cal42 ? 10 * n : n;
        const tm = this.teams[t];
        if (this.mode3 && this.inCombat && this.alive(r) && roleOf(r) !== 2 && rb.zone === 1 && n && tm.coins >= cost) {
          tm.coins -= cost;
          rb.ammo += n;
          this.event(r, EV.EXCHANGE, 0, rb.ammo);
        } else {
          this.event(r, EV.EXCHANGE, 1, rb.ammo);
        }
        break;
      }
      default:
    }
  }

  giveCoins(n) {
    for (const t of this.teams) t.coins += n;
  }

  stageStep() {
    if (this.paused || this.stage < ST.PREP || this.stage > ST.COMBAT) return;
    if (this.sub !== 9) { this.sub++; return; }
    this.sub = 0;
    if (this.remain > 1) {
      if (this.stage === ST.COMBAT && this.mode3) {
        if (this.remain === 240 || this.remain === 180) this.giveCoins(200);
        if (this.remain === 120 || this.remain === 60) this.giveCoins(300);
      }
      this.remain--;
      return;
    }
    if (this.stage === ST.PREP) {
      Object.assign(this, { stage: ST.CHECK, remain: 15 });
      this.resetRobots();
      this.sendStatus();
    } else if (this.stage === ST.CHECK) {
      Object.assign(this, { stage: ST.COUNT, remain: 5 });
      this.sendStatus();
    } else if (this.stage === ST.COUNT) {
      Object.assign(this, { stage: ST.COMBAT, remain: this.combatTime });
      if (this.mode3) this.giveCoins(200);
      this.sendStatus();
    } else {
      this.finish(...this.judge());
    }
  }

  heatStep(r) {
    if (this.paused) return;
    const rb = this.robots[r];
    const c = this.cfg[r];
    const h = rb.heat10;
    const lim10 = c.heatLimit * 10;
    const rnd10 = lim10 + (c.cal42 ? 2000 : 1000);
    const al = this.alive(r);
    if (this.inCombat && al && rb.heatLk !== 2 && h > rnd10) {
      rb.heatLk = 2;
      this.event(r, EV.LOCK, LK.HEAT_ROUND, rb.hp);
    } else if (this.inCombat && al && rb.heatLk === 0 && h > lim10) {
      rb.heatLk = 1;
      this.event(r, EV.LOCK, LK.HEAT, rb.hp);
    } else if (rb.heatLk === 1 && h <= c.cooling) {
      rb.heatLk = 0;
      this.event(r, EV.UNLOCK, LK.HEAT, rb.hp);
    }
    rb.heat10 = satSub(h, c.cooling);
  }

  powerStep(r) {
    const rb = this.robots[r];
    const lim = this.cfg[r].powerLimit;
    if (this.inCombat && this.alive(r) && !rb.disc) {
      const p = rb.chOff ? 0 : rb.power;
      if (rb.chOff) rb.chOff--;
      if (p > lim) {
        const d = p - lim;
        if (rb.buf10 > d) rb.buf10 -= d;
        else {
          rb.buf10 = 0;
          rb.chOff = 50;
          this.event(r, EV.CHASSIS, 0, rb.hp);
        }
      } else {
        rb.buf10 = Math.min(BUFFER_FULL_X10, rb.buf10 + (lim - p));
      }
    } else if (!this.paused && !this.inCombat) {
      rb.buf10 = BUFFER_FULL_X10;
      rb.chOff = 0;
    }
  }

  timerStep(r) {
    if (!this.inCombat) return;
    const rb = this.robots[r];
    const c = this.cfg[r];
    const wasAlive = this.alive(r);
    const tick = rb.secT === 9;
    if (rb.yelWin) rb.yelWin--;
    if (rb.invinc) rb.invinc--;
    if (rb.spdLk === 1) {
      rb.spdLk = 0;
      this.event(r, EV.UNLOCK, LK.SPEED15, rb.hp);
    } else if (rb.spdLk && rb.spdLk !== LOCK_ROUND) {
      rb.spdLk--;
    }
    if (rb.respT && !rb.disc) {
      if (rb.respT === 1) {
        rb.hp = c.p20;
        rb.invinc = 300;
        rb.weak = true;
        this.event(r, EV.RESPAWN, rb.defeats, c.p20);
      }
      rb.respT--;
    }
    rb.secT = tick ? 0 : rb.secT + 1;
    if (tick && wasAlive) {
      if (rb.disc) {
        const nh = satSub(rb.hp, c.p5);
        this.event(r, EV.OFFLINE_HP, 0, nh);
        this.setHp(r, nh, false);
      } else if (this.mode3 && rb.zone === 1) {
        rb.hp = Math.min(c.maxHp, rb.hp + c.p25);
        rb.weak = false;
        rb.invinc = 0;
      }
    }
  }

  teamStep() {
    if (!(this.inCombat && this.mode3)) return;
    this.teams.forEach((tm, i) => {
      if (tm.hquiet !== 255) tm.hquiet++;
      const hero = this.robots[3 * i];
      if (this.cfg[3 * i].fielded && (hero.hp === 0 || hero.disc)) tm.hdown = Math.min(255, tm.hdown + 1);
      else tm.hdown = 0;
    });
    const pres = [0, 1].map((t) => [0, 1, 2].some((k) => {
      const s = 3 * t + k;
      const rb = this.robots[s];
      return this.alive(s) && !rb.disc && !rb.weak && rb.zone === 2;
    }));
    let h;
    if ((this.capHolder === 1 && pres[0]) || (this.capHolder === 2 && pres[1])) h = this.capHolder;
    else if (pres[0] && !pres[1]) h = 1;
    else if (pres[1] && !pres[0]) h = 2;
    else if (pres[0] && pres[1]) h = 3;
    else h = 0;
    if (h !== this.capHolder) {
      this.capHolder = h;
      this.event(0, EV.CAPTURE, h, 0);
    }
    const [v0, v1] = [this.teams[0].vp, this.teams[1].vp];
    if (this.vpT === 9) {
      this.vpT = 0;
      if (h === 1) this.loseVp(1, 1);
      if (h === 2) this.loseVp(0, 1);
    } else {
      this.vpT++;
    }
    const gap = Math.abs(v0 - v1);
    const lower = v0 < v1 ? 0 : 1;
    if (gap >= 70 && !this.bonus[0]) {
      this.bonus[0] = true;
      this.teams[lower].coins += 200;
    } else if (gap >= 140 && !this.bonus[1]) {
      this.bonus[1] = true;
      this.teams[lower].coins += 200;
    }
  }

  tick20() {
    if (this.t5 === 4) {
      this.t5 = 0;
      if (this.t10 === 9) { this.t10 = 0; this.unix = (this.unix + 1) >>> 0; } else this.t10++;
      this.stageStep();
      for (let r = 0; r < N; r++) {
        if (!this.cfg[r].fielded) continue;
        this.heatStep(r);
        this.powerStep(r);
        this.timerStep(r);
      }
      this.teamStep();
      this.runPenalties();
    } else {
      this.t5++;
    }
    // Same periodic schedule as arc_frame_gen.
    if (this.c50 === 0) this.sendStatus();
    if (this.c50 === 10) this.sendField();
    if (this.c50 === 25) this.sendWarn();
    if (this.c5 === 0) this.sendRobotStatus();
    if (this.c5 === 1) this.sendPowerHeat();
    if (this.c17 === 0) this.sendHp();
    if (this.c17 === 8) this.sendBuff();
    if (this.c5 === 3) this.sendServer();
    this.c50 = this.c50 === 49 ? 0 : this.c50 + 1;
    this.c5 = this.c5 === 4 ? 0 : this.c5 + 1;
    this.c17 = this.c17 === 16 ? 0 : this.c17 + 1;
  }
}
