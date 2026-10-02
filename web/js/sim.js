// Demo-mode transport: a JavaScript copy of the fabric (arc_rx_parser +
// arc_ref_core + arc_frame_gen) that speaks the same byte stream as the
// Zybo, so the console can be developed and tested without hardware.
// Keep the rules in step with hw/rtl/arc_ref_core.v; web/test checks that a
// replay of the RTL testbench ends the same way.

import { CMD, FrameDecoder, encode } from './protocol.js';

const ST = { IDLE: 0, PREP: 1, CHECK: 2, COUNT: 3, COMBAT: 4, RESULT: 5 };
const EV = {
  HIT: 1, SHOT: 2, LOCK: 3, CHASSIS: 4, YELLOW: 5, RED: 6, FORFEIT: 7, KILL: 8,
  REVIVE: 9, DISCONNECT: 10, RECONNECT: 11, OFFLINE_HP: 12, UNLOCK: 13, YELLOW_BOTH: 14,
};
const LK = { HEAT: 1, HEAT_ROUND: 2, SPEED15: 3, SPEED20: 4, SPEED_ROUND: 5, AMMO: 6 };
const WR = { NONE: 0, DEFEAT: 1, HP: 2, FIRST_DMG: 3, SHOTS: 4, FIRST_SHOT: 5, TIE: 6, FORFEIT: 7 };
const BUFFER_FULL_X10 = 600;
const LOCK_ROUND = 0xffff;
const YELLOW_WINDOW = 300;
const CHASSIS_CUT = 50;
const div10 = (x) => Math.floor(x / 10);
const pctOf = (x, p) => Math.floor((x * p + 50) / 100);
const robotId = (r) => (r ? 103 : 3);

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
    }
    this.rxErr += this.rx.bad - before;
  }

  reset() {
    this.cfg = {
      combatTime: 120, maxHp: 200, heatLimit: 80, cooling: 12, powerLimit: 120,
      hitDmg: 20, setupTime: 120, speedLimit: 25, allowance: 200,
    };
    Object.assign(this, {
      stage: ST.IDLE, paused: false, remain: 0, gameType: 5, link: 0, unix: 0,
      sub: 0, t5: 0, t10: 0, c50: 0, c5: 0, c17: 0, seq: 0, rxOk: 0, rxErr: 0,
      warnL: [0, 0, 0],
    });
    this.robots = [0, 1].map(() => ({ power: 0 }));
    this.resetRobots();
  }

  resetRobots() {
    for (const rb of this.robots) {
      Object.assign(rb, {
        hp: this.cfg.maxHp, heat10: 0, buf10: BUFFER_FULL_X10, ammo: this.cfg.allowance, shots: 0,
        yellow: 0, yelPct: 0, yelWin: 0, red: false, heatLk: 0, spdLk: 0, chOff: 0, disc: false, discT: 0,
      });
    }
    this.bothYellow = 0;
    this.firstDmg = 0;
    this.firstShot = 0;
    this.winner = 0;
    this.winReason = WR.NONE;
  }

  // ------------------------------------------------------------- outputs
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

  sendWarn() {
    this.send(CMD.REFEREE_WARNING, Uint8Array.from(this.warnL));
  }

  sendHp() {
    const p = new Uint8Array(16);
    new DataView(p.buffer).setUint16(4, this.robots[this.link].hp, true);
    this.send(CMD.ROBOT_HP, p);
  }

  flags(r) {
    const rb = this.robots[r];
    const alive = rb.hp > 0;
    const gimbal = alive && !rb.disc;
    const chassis = gimbal && rb.chOff === 0;
    const shooter = gimbal && rb.heatLk === 0 && rb.spdLk === 0 && rb.ammo > 0;
    return (alive ? 1 : 0) | (rb.red ? 2 : 0) | (shooter ? 4 : 0) | (chassis ? 8 : 0) | (gimbal ? 16 : 0)
      | (rb.disc ? 32 : 0) | (rb.heatLk ? 64 : 0) | (rb.spdLk ? 128 : 0);
  }

  shooterOn(r) {
    return !!(this.flags(r) & 4);
  }

  sendRobotStatus() {
    const r = this.link;
    const f = this.flags(r);
    const p = new Uint8Array(13);
    const v = new DataView(p.buffer);
    v.setUint8(0, robotId(r));
    v.setUint8(1, 1);
    v.setUint16(2, this.robots[r].hp, true);
    v.setUint16(4, this.cfg.maxHp, true);
    v.setUint16(6, this.cfg.cooling, true);
    v.setUint16(8, this.cfg.heatLimit, true);
    v.setUint16(10, this.cfg.powerLimit, true);
    v.setUint8(12, ((f >> 4) & 1) | (((f >> 3) & 1) << 1) | (((f >> 2) & 1) << 2));
    this.send(CMD.ROBOT_STATUS, p);
  }

  sendPowerHeat() {
    const rb = this.robots[this.link];
    const p = new Uint8Array(14);
    const v = new DataView(p.buffer);
    v.setUint16(8, div10(rb.buf10), true);
    v.setUint16(10, div10(rb.heat10), true);
    this.send(CMD.POWER_HEAT, p);
  }

  sendServer() {
    const p = new Uint8Array(66);
    const v = new DataView(p.buffer);
    v.setUint8(0, this.stage);
    v.setUint8(1, (this.paused ? 1 : 0) | (this.firstDmg << 1) | (this.firstShot << 3));
    v.setUint16(2, this.remain, true);
    v.setUint8(4, this.winner);
    v.setUint8(5, this.winReason);
    v.setUint8(6, this.link);
    v.setUint8(7, this.gameType);
    this.robots.forEach((rb, i) => {
      const o = 8 + 22 * i;
      [rb.hp, this.cfg.maxHp, div10(rb.heat10), this.cfg.heatLimit, div10(rb.buf10), rb.power,
        this.cfg.powerLimit, rb.ammo, rb.shots].forEach((x, k) => v.setUint16(o + 2 * k, x, true));
      v.setUint8(o + 18, rb.yellow);
      v.setUint8(o + 19, this.flags(i));
      v.setUint8(o + 20, rb.spdLk === LOCK_ROUND ? 255 : Math.min(254, div10(rb.spdLk + 9)));
      v.setUint8(o + 21, rb.chOff);
    });
    [this.rxOk, this.rxErr, this.cfg.combatTime, this.cfg.cooling, this.cfg.hitDmg,
      this.cfg.setupTime, this.cfg.speedLimit].forEach((x, k) => v.setUint16(52 + 2 * k, x & 0xffff, true));
    this.send(CMD.SERVER_STATE, p);
  }

  // --------------------------------------------------------------- rules
  get inCombat() {
    return this.stage === ST.COMBAT && !this.paused;
  }

  finish(w, why) {
    Object.assign(this, { stage: ST.RESULT, remain: 0, paused: false, winner: w, winReason: why });
    this.send(CMD.GAME_RESULT, Uint8Array.of(w));
    this.sendStatus();
  }

  setHp(r, nh) {
    const wasCombat = this.stage === ST.COMBAT;
    if (this.inCombat && this.firstDmg === 0) this.firstDmg = r ? 2 : 1;
    this.robots[r].hp = nh;
    if (wasCombat && nh === 0) this.finish(r ? 1 : 2, WR.DEFEAT);
  }

  warn(r, level, id, count) {
    if (r === this.link) {
      this.warnL = [level, id, count & 0xff];
      this.sendWarn();
    }
  }

  judge() {
    const [a, b] = this.robots;
    if (a.hp !== b.hp) return [a.hp > b.hp ? 1 : 2, WR.HP];
    if (a.hp !== this.cfg.maxHp && this.firstDmg) return [this.firstDmg === 1 ? 2 : 1, WR.FIRST_DMG];
    if (a.shots !== b.shots) return [a.shots > b.shots ? 1 : 2, WR.SHOTS];
    if (this.firstShot) return [this.firstShot, WR.FIRST_SHOT];
    return [0, WR.TIE];
  }

  hit(r, armor, kind) {
    const rb = this.robots[r];
    if (!(this.inCombat && rb.hp > 0 && !rb.disc)) return;
    const dmg = kind === 1 ? 2 : kind === 2 ? 200 : this.cfg.hitDmg;
    const nh = rb.hp > dmg ? rb.hp - dmg : 0;
    const detail = (kind === 1 ? 0x40 : 0) | (kind === 2 ? 0x20 : 0) | (armor & 0xf);
    if (r === this.link) this.send(CMD.HURT, Uint8Array.of(((kind === 1 ? 5 : 0) << 4) | (armor & 0xf)));
    this.event(r, EV.HIT, detail, nh);
    this.setHp(r, nh);
  }

  penaltyHp(h, ded) {
    return h === 0 ? 0 : h <= ded ? 1 : h - ded;
  }

  yellowCard(r) {
    const rb = this.robots[r];
    const cnt = (rb.yellow + 1) & 0xff;
    const pct = Math.min(200, rb.yelWin ? rb.yelPct * 2 : 15);
    rb.yellow = cnt;
    rb.yelPct = pct;
    rb.yelWin = YELLOW_WINDOW;
    this.warn(r, 2, robotId(r), cnt);
    if (cnt >= 3) {
      rb.red = true;
      this.event(r, EV.YELLOW, cnt, 0);
      this.event(r, EV.RED, 1, 0);
      this.setHp(r, 0);
    } else {
      const nh = this.penaltyHp(rb.hp, pctOf(this.cfg.maxHp, pct));
      this.event(r, EV.YELLOW, cnt, nh);
      if (nh !== rb.hp) this.setHp(r, nh);
    }
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
            if (this.stage === ST.IDLE) {
              Object.assign(this, { stage: ST.PREP, remain: this.cfg.setupTime, sub: 0, paused: false });
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
        if (this.stage === ST.IDLE && d.length >= 20) {
          this.gameType = d[0] & 0xf;
          this.link = d[1] & 1;
          const k = ['combatTime', 'maxHp', 'heatLimit', 'cooling', 'powerLimit', 'hitDmg', 'setupTime', 'speedLimit', 'allowance'];
          k.forEach((name, i) => { this.cfg[name] = v.getUint16(2 + 2 * i, true); });
          for (const x of this.robots) { x.hp = this.cfg.maxHp; x.ammo = this.cfg.allowance; }
          this.sendStatus();
        }
        break;
      case CMD.C_HIT:
        this.hit(r, a & 0xf, d.length >= 3 ? d[2] & 3 : 0);
        break;
      case CMD.C_SHOOT:
        if (this.inCombat && this.shooterOn(r)) {
          rb.heat10 = Math.min(0xffff, rb.heat10 + 100);
          rb.ammo--;
          rb.shots++;
          if (!this.firstShot) this.firstShot = r ? 2 : 1;
          this.event(r, EV.SHOT, a, rb.hp);
          const sp = d.length >= 8 ? v.getUint16(6, true) : 0;
          const lim10 = this.cfg.speedLimit * 10;
          if (sp > lim10) {
            const over = sp - lim10;
            const [lk, lkd] = over < 50 ? [150, LK.SPEED15] : over < 100 ? [200, LK.SPEED20] : [LOCK_ROUND, LK.SPEED_ROUND];
            if (rb.spdLk !== LOCK_ROUND && lk > rb.spdLk) rb.spdLk = lk;
            this.event(r, EV.LOCK, lkd, rb.hp);
          } else if (rb.ammo === 0) {
            this.event(r, EV.LOCK, LK.AMMO, rb.hp);
          }
          if (r === this.link) {
            const p = new Uint8Array(7);
            p[0] = 1; p[1] = 1; p[2] = a;
            p.set(d.slice(2, 6), 3);
            this.send(CMD.SHOOT, p);
          }
        }
        break;
      case CMD.C_PENALTY:
        if (a === 1) {
          this.bothYellow = (this.bothYellow + 1) & 0xff;
          this.robots.forEach((x, i) => {
            x.hp = this.penaltyHp(x.hp, pctOf(this.cfg.maxHp, 5));
            this.event(i, EV.YELLOW_BOTH, this.bothYellow, x.hp);
          });
          this.warn(this.link, 1, 0, this.bothYellow);
        } else if (a === 2) {
          this.yellowCard(r);
        } else if (a === 3) {
          rb.red = true;
          this.event(r, EV.RED, 0, 0);
          this.warn(r, 3, robotId(r), 1);
          this.setHp(r, 0);
        } else if (a === 4 && this.stage >= ST.PREP && this.stage <= ST.COMBAT) {
          if (this.stage !== ST.COMBAT) { rb.hp = 0; this.robots[r ^ 1].hp = this.cfg.maxHp; }
          this.event(r, EV.FORFEIT, 0, rb.hp);
          this.warn(r, 4, 0, 1);
          this.finish(r ? 1 : 2, WR.FORFEIT);
        }
        break;
      case CMD.C_LIFE:
        if (a === 0) {
          this.event(r, EV.KILL, 0, 0);
          this.setHp(r, 0);
        } else if (a === 1) {
          Object.assign(rb, { hp: this.cfg.maxHp, heat10: 0, red: false, heatLk: 0, spdLk: 0, disc: false });
          this.event(r, EV.REVIVE, 0, rb.hp);
        } else if (a === 2 && !rb.disc) {
          rb.disc = true;
          rb.discT = 0;
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
      default:
    }
  }

  stageStep() {
    if (this.paused || this.stage < ST.PREP || this.stage > ST.COMBAT) return;
    if (this.sub !== 9) { this.sub++; return; }
    this.sub = 0;
    if (this.remain > 1) { this.remain--; return; }
    if (this.stage === ST.PREP) {
      Object.assign(this, { stage: ST.CHECK, remain: 15 });
      this.resetRobots();
      this.sendStatus();
    } else if (this.stage === ST.CHECK) {
      Object.assign(this, { stage: ST.COUNT, remain: 5 });
      this.sendStatus();
    } else if (this.stage === ST.COUNT) {
      Object.assign(this, { stage: ST.COMBAT, remain: this.cfg.combatTime });
      this.sendStatus();
    } else {
      this.finish(...this.judge());
    }
  }

  heatStep(r) {
    if (this.paused) return;
    const rb = this.robots[r];
    const h = rb.heat10;
    const alive = rb.hp > 0;
    if (this.inCombat && alive && rb.heatLk !== 2 && h > (this.cfg.heatLimit + 100) * 10) {
      rb.heatLk = 2;
      this.event(r, EV.LOCK, LK.HEAT_ROUND, rb.hp);
    } else if (this.inCombat && alive && rb.heatLk === 0 && h > this.cfg.heatLimit * 10) {
      rb.heatLk = 1;
      this.event(r, EV.LOCK, LK.HEAT, rb.hp);
    } else if (rb.heatLk === 1 && h <= this.cfg.cooling) {
      rb.heatLk = 0;
      this.event(r, EV.UNLOCK, LK.HEAT, rb.hp);
    }
    rb.heat10 = h > this.cfg.cooling ? h - this.cfg.cooling : 0;
  }

  powerStep(r) {
    const rb = this.robots[r];
    const lim = this.cfg.powerLimit;
    if (this.inCombat && rb.hp > 0 && !rb.disc) {
      const p = rb.chOff ? 0 : rb.power;
      if (rb.chOff) rb.chOff--;
      if (p > lim) {
        const d = p - lim;
        if (rb.buf10 > d) rb.buf10 -= d;
        else {
          rb.buf10 = 0;
          rb.chOff = CHASSIS_CUT;
          this.event(r, EV.CHASSIS, 0, rb.hp);
        }
      } else {
        rb.buf10 = Math.min(BUFFER_FULL_X10, rb.buf10 + (lim - p));
      }
    } else if (!this.paused) {
      rb.buf10 = BUFFER_FULL_X10;
      rb.chOff = 0;
    }
  }

  timerStep(r) {
    if (!this.inCombat) return;
    const rb = this.robots[r];
    if (rb.yelWin) rb.yelWin--;
    if (rb.spdLk === 1) {
      rb.spdLk = 0;
      this.event(r, EV.UNLOCK, LK.SPEED15, rb.hp);
    } else if (rb.spdLk !== 0 && rb.spdLk !== LOCK_ROUND) {
      rb.spdLk--;
    }
    if (rb.disc && rb.hp > 0) {
      if (rb.discT === 9) {
        rb.discT = 0;
        const ded = pctOf(this.cfg.maxHp, 5);
        const nh = rb.hp > ded ? rb.hp - ded : 0;
        this.event(r, EV.OFFLINE_HP, 0, nh);
        this.setHp(r, nh);
      } else {
        rb.discT++;
      }
    }
  }

  tick20() {
    if (this.t5 === 4) {
      this.t5 = 0;
      if (this.t10 === 9) { this.t10 = 0; this.unix = (this.unix + 1) >>> 0; } else this.t10++;
      this.stageStep();
      for (let r = 0; r < 2; r++) {
        this.heatStep(r);
        this.powerStep(r);
        this.timerStep(r);
      }
    } else {
      this.t5++;
    }
    // Same periodic schedule as arc_frame_gen.
    if (this.c50 === 0) this.sendStatus();
    if (this.c50 === 25) this.sendWarn();
    if (this.c5 === 0) this.sendRobotStatus();
    if (this.c5 === 1) this.sendPowerHeat();
    if (this.c17 === 0) this.sendHp();
    if (this.c5 === 3) this.sendServer();
    this.c50 = this.c50 === 49 ? 0 : this.c50 + 1;
    this.c5 = this.c5 === 4 ? 0 : this.c5 + 1;
    this.c17 = this.c17 === 16 ? 0 : this.c17 + 1;
  }
}
