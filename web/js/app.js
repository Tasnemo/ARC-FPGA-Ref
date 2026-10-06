import {
  CMD, CMD_NAMES, EVENT_KINDS, GAME, GAME_TYPES, HIT_KIND, HURT_REASONS, LIFE, LOCKS, MODES,
  PENALTY, SLOTS, STAGES, WIN_REASONS, FrameDecoder, commands, decodePayload, encode, hex,
  infantry3v3, modeRobots,
} from './protocol.js';
import { SerialLink } from './serial.js';
import { SimLink } from './sim.js';
import { DEFAULT_BOARD, WsLink } from './ws.js';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const TEAM = ['RED', 'BLUE'];
const STAT_FIELDS = ['maxHp', 'heatLimit', 'cooling', 'powerLimit', 'speedLimit', 'allowance'];

const state = {
  link: null,
  decoder: null,
  seq: 0,
  server: null,        // latest 0xF101
  serverAt: 0,
  real: {},            // latest decoded real frame per cmd_id
  counts: {},
  rates: {},
  lastCounts: {},
  rxBytes: 0,
  txBytes: 0,
  rawPaused: false,
  rawLines: [],
  boardText: '',
  writeChain: Promise.resolve(),
  uiMode: '1v1',       // used until the board reports its mode
  role: [1, 1],        // robot each control panel drives (0 hero, 1 infantry, 2 sentry)
  layout: null,
  lastLog: null,
  configDirty: false,
  wireless: null,      // latest arc-refd status (Kria only)
  servedByBoard: false,
};

const modeOf = (s) => (s ? (s.mode3 ? '3v3' : '1v1') : state.uiMode);
const slotOf = (t) => (modeOf(state.server) === '1v1' ? 3 * t + 1 : 3 * t + state.role[t]);
function slotName(r, mode = modeOf(state.server)) {
  const x = SLOTS[r];
  return mode === '1v1' ? `${TEAM[x.team]} ${x.id}` : `${TEAM[x.team]} ${x.name}`;
}

// ------------------------------------------------------------ team cards
const teamEls = $$('.team');
let teams = [];

function buildTeams(mode) {
  state.layout = mode;
  teams = teamEls.map((el) => {
    const t = Number(el.dataset.team);
    el.replaceChildren($('#teamHeadTemplate').content.cloneNode(true));
    el.classList.toggle('v3', mode === '3v3');
    $('.team-name', el).textContent = mode === '1v1' ? `${TEAM[t]} ${SLOTS[3 * t + 1].id} · INFANTRY` : `${TEAM[t]} TEAM`;
    $('.team-stats', el).hidden = mode !== '3v3';
    $('.team-head .state-badge', el).hidden = mode === '3v3';
    const slots = mode === '1v1' ? [3 * t + 1] : [3 * t, 3 * t + 1, 3 * t + 2];
    const units = slots.map((slot) => {
      const u = $('#unitTemplate').content.firstElementChild.cloneNode(true);
      $('.units', el).append(u);
      $('.unit-head', u).hidden = mode === '1v1';
      $('.unit-name', u).textContent = `${SLOTS[slot].name} ${SLOTS[slot].id}`;
      u.classList.toggle('compact', mode === '3v3');
      return {
        slot, el: u,
        link: mode === '1v1' ? $('.team-head .link-badge', el) : $('.link-badge', u),
        badge: mode === '1v1' ? $('.team-head .state-badge', el) : $('.unit-head .state-badge', u),
        hpValue: $('.hp-value', u), hpMax: $('.hp-max', u),
        hpFill: $('.hp-bar .fill', u), hpGhost: $('.hp-bar .ghost', u),
        heatBar: $('.heat-bar', u), heatFill: $('.heat-bar .fill', u), heatValue: $('.heat-value', u),
        bufferFill: $('.buffer-bar .fill', u), bufferValue: $('.buffer-value', u),
        powerValue: $('.power-value', u), ammoValue: $('.ammo-value', u), cards: $('.cards', u),
        chipShooter: $('.chip-shooter', u), chipChassis: $('.chip-chassis', u),
        chipGimbal: $('.chip-gimbal', u), chipSpecial: $('.chip-special', u),
      };
    });
    return {
      el, t, units,
      vpValue: $('.vp-value', el), vpFill: $('.vp-bar .fill', el),
      coins: $('.coins', el), dmg: $('.dmg', el), hero42: $('.hero42', el),
    };
  });
  buildLinkOptions(mode);
}

// ------------------------------------------------------------ controls
const panels = $$('.panel.robot').map((el) => {
  const t = Number(el.dataset.team);
  el.append($('#robotTemplate').content.cloneNode(true));
  const ui = {
    el, t,
    title: $('.robot-title', el),
    plates: $$('.plate', el),
    speed: $('.shoot-speed', el),
    shoot: $('.act-shoot', el),
    powerIn: $('.power-in', el),
    powerOut: $('.power-out', el),
    disconnect: $('.act-disconnect', el),
    slotSeg: $('.slot-seg', el),
    zoneSeg: $('.zone-seg', el),
    buyN: $('.buy-n', el),
    buyCost: $('.buy-cost', el),
    infChassis: $('.inf-chassis', el),
    infLauncher: $('.inf-launcher', el),
    infRow: $('.infantry-row', el),
  };
  $$('.hit-kind input', el).forEach((x) => { x.name = `hitKind${t}`; });
  const hitKind = () => Number($('.hit-kind input:checked', el)?.value || 0);
  const slot = () => slotOf(t);

  ui.plates.forEach((p) => {
    p.setAttribute('tabindex', '0');
    const fire = () => {
      if (!el.classList.contains('disabled')) send(commands.hit(slot(), Number(p.dataset.armor), hitKind()));
    };
    p.addEventListener('click', fire);
    p.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fire(); } });
  });
  ui.shoot.addEventListener('click', () => {
    const speed = Math.max(0, Math.min(60, parseFloat(ui.speed.value) || 0));
    send(commands.shoot(slot(), 5, speed));
  });
  let powerTimer = null;
  ui.powerIn.addEventListener('input', () => {
    ui.powerOut.textContent = `${ui.powerIn.value} W`;
    clearTimeout(powerTimer);
    powerTimer = setTimeout(() => send(commands.power(slot(), Number(ui.powerIn.value))), 60);
  });
  $$('.seg-btn', ui.slotSeg).forEach((b) => b.addEventListener('click', () => {
    state.role[t] = Number(b.dataset.role);
    syncPanelInputs(ui);
    render();
  }));
  $$('.seg-btn', ui.zoneSeg).forEach((b) => b.addEventListener('click', () => send(commands.zone(slot(), Number(b.dataset.zone)))));
  $('.act-buy', el).addEventListener('click', () => send(commands.exchange(slot(), Math.max(1, Math.min(500, Number(ui.buyN.value) || 0)))));
  const sendInfantry = () => send(commands.robot(slot(), infantry3v3(ui.infChassis.value, ui.infLauncher.value)));
  ui.infChassis.addEventListener('change', sendInfantry);
  ui.infLauncher.addEventListener('change', sendInfantry);
  $('.act-yellow', el).addEventListener('click', () => send(commands.penalty(slot(), PENALTY.YELLOW)));
  $('.act-red', el).addEventListener('click', () => {
    if (confirm(`Red card ${slotName(slot())}? The robot is ejected.`)) send(commands.penalty(slot(), PENALTY.RED));
  });
  $('.act-forfeit', el).addEventListener('click', () => {
    if (confirm(`${TEAM[t]} forfeits? The round ends.`)) send(commands.penalty(slot(), PENALTY.FORFEIT));
  });
  $('.act-kill', el).addEventListener('click', () => send(commands.life(slot(), LIFE.KILL)));
  $('.act-revive', el).addEventListener('click', () => send(commands.life(slot(), LIFE.REVIVE)));
  ui.disconnect.addEventListener('click', () => {
    const offline = state.server?.robots[slot()]?.disconnected;
    send(commands.life(slot(), offline ? LIFE.RECONNECT : LIFE.DISCONNECT));
  });
  return ui;
});

// Speed field follows the selected robot's limit (just under it).
function syncPanelInputs(ui) {
  const r = state.server?.robots[slotOf(ui.t)];
  if (r) ui.speed.value = (Math.max(1, r.speedLimit - 1)).toFixed(1);
  if (r) ui.powerIn.value = r.power;
  ui.powerOut.textContent = `${ui.powerIn.value} W`;
}

// ------------------------------------------------------------ match control
$$('[data-game]').forEach((b) => {
  b.addEventListener('click', () => {
    const a = Number(b.dataset.game);
    if (a === GAME.END && !confirm('End the round now? The winner is decided by the rules for this mode.')) return;
    send(commands.game(a));
  });
});
$('#btnBothYellow').addEventListener('click', () => send(commands.penalty(0, PENALTY.BOTH_YELLOW)));

function infantryChoices() {
  return panels.map((p) => ({ chassis: p.infChassis.value, launcher: p.infLauncher.value }));
}

function applyMode(mode, { combatTime, setupTime, link } = MODES[mode], robots = modeRobots(mode, infantryChoices())) {
  send(commands.config({ gameType: MODES[mode].gameType, link, combatTime, setupTime }));
  robots.forEach((c, slot) => send(commands.robot(slot, c)));
}

$$('.mode-seg .seg-btn').forEach((b) => b.addEventListener('click', () => {
  const mode = b.dataset.mode;
  state.uiMode = mode;
  if (state.link && state.server?.stage === 0) {
    applyMode(mode);
    fillStatsTable(modeRobots(mode, infantryChoices()));
    const form = $('#configForm');
    form.combatTime.value = MODES[mode].combatTime;
    form.setupTime.value = MODES[mode].setupTime;
    state.configDirty = false;
  }
  render();
}));

// ------------------------------------------------------------ rules config
const statsBody = $('#statsBody');
const statRows = SLOTS.map((x, slot) => {
  const tr = document.createElement('tr');
  const name = document.createElement('td');
  name.textContent = `${TEAM[x.team][0]} ${x.name}`;
  name.className = `slot-name t${x.team}`;
  tr.append(name);
  const cell = (input) => { const td = document.createElement('td'); td.append(input); tr.append(td); return input; };
  const box = (cls) => { const i = document.createElement('input'); i.type = 'checkbox'; i.className = cls; return cell(i); };
  const num = (k) => { const i = document.createElement('input'); i.type = 'number'; i.min = 0; i.max = 5000; i.dataset.k = k; return cell(i); };
  const row = { tr, fielded: box('st-on'), cal42: box('st-42'), nums: Object.fromEntries(STAT_FIELDS.map((k) => [k, num(k)])) };
  statsBody.append(tr);
  return row;
});

function fillStatsTable(robots) {
  robots.forEach((c, i) => {
    const row = statRows[i];
    row.fielded.checked = c.fielded;
    row.cal42.checked = c.cal42;
    for (const k of STAT_FIELDS) row.nums[k].value = c[k];
  });
}

function readStatsTable() {
  const n = (x) => Math.max(0, Math.min(0xffff, Math.round(Number(x.value) || 0)));
  return statRows.map((row) => ({
    fielded: row.fielded.checked,
    cal42: row.cal42.checked,
    ...Object.fromEntries(STAT_FIELDS.map((k) => [k, n(row.nums[k])])),
  }));
}

function buildLinkOptions(mode) {
  const sel = $('#configForm').link;
  const keep = sel.value;
  sel.replaceChildren(...(mode === '1v1' ? [1, 4] : [0, 1, 2, 3, 4, 5]).map((slot) => new Option(`${slotName(slot, mode)} (ID ${SLOTS[slot].id})`, slot)));
  if ([...sel.options].some((o) => o.value === keep)) sel.value = keep;
}

$('#btnPreset').addEventListener('click', () => {
  const mode = modeOf(state.server);
  fillStatsTable(modeRobots(mode, infantryChoices()));
  const form = $('#configForm');
  form.combatTime.value = MODES[mode].combatTime;
  form.setupTime.value = MODES[mode].setupTime;
  state.configDirty = true;
});

$('#configForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const form = e.target;
  const n = (k) => Math.max(0, Math.min(0xffff, Math.round(Number(form[k].value) || 0)));
  applyMode(modeOf(state.server), { combatTime: n('combatTime'), setupTime: n('setupTime'), link: n('link') }, readStatsTable());
  state.configDirty = false;
});
$('#configForm').addEventListener('input', () => { state.configDirty = true; });

$('#btnClearLog').addEventListener('click', () => { $('#eventLog').replaceChildren(); });
$('#btnPauseRaw').addEventListener('click', (e) => {
  state.rawPaused = !state.rawPaused;
  e.target.textContent = state.rawPaused ? 'Resume' : 'Pause';
});

// ------------------------------------------------------------ transport
// Kria address: the host that served this page, ?board=host[:port], or the
// KR260 hotspot's default address.
const boardHost = () => (state.servedByBoard ? location.host
  : new URLSearchParams(location.search).get('board') || DEFAULT_BOARD);

function wifiLink() {
  const link = new WsLink(boardHost());
  link.onStatus = (st) => { state.wireless = st; };
  return link;
}

if (!SerialLink.supported()) {
  $('#serialWarning').hidden = false;
  $('#btnConnect').disabled = true;
}

$('#btnConnect').addEventListener('click', () => connect(state.servedByBoard ? wifiLink() : new SerialLink()));
$('#btnWifi').addEventListener('click', () => connect(wifiLink()));
$('#btnOtherPort').addEventListener('click', () => connect(new SerialLink(), { allPorts: true }));
$('#btnDemo').addEventListener('click', () => connect(new SimLink()));
$('#btnDisconnect').addEventListener('click', () => state.link?.close());

async function connect(link, openOpts) {
  await state.link?.close();
  Object.assign(state, {
    wireless: null,
    decoder: new FrameDecoder(), server: null, serverAt: 0, real: {}, counts: {}, rates: {},
    lastCounts: {}, rxBytes: 0, txBytes: 0, rawLines: [], boardText: '', configDirty: false,
  });
  state.decoder.onSkipped = onBoardText;
  link.onData = onData;
  link.onClose = (reason) => {
    if (state.link === link) state.link = null;
    setLinkUi(null, reason);
  };
  try {
    await link.open(openOpts);
  } catch (err) {
    if (err.name === 'NotFoundError') return;   // picker cancelled
    if (err.name === 'BoardUnreachable') {
      alert(`${err.message}.\n\nJoin the board's "ARC-REF" WiFi (or plug in Ethernet), then try again. `
        + 'If the board has another address, open this page with ?board=ADDRESS.');
      return;
    }
    alert(err.name === 'NetworkError' || err.name === 'InvalidStateError'
      ? 'That port is busy. Close any serial terminal (PuTTY, screen, Vitis/Vivado serial console) using it and try again.'
      : `Could not open the port: ${err.message}`);
    return;
  }
  state.link = link;
  state.connectedAt = performance.now();
  setLinkUi(link);
  send(commands.time(Math.floor(Date.now() / 1000)));
}

function send([cmd, payload]) {
  const link = state.link;
  if (!link) return;
  const frame = encode(cmd, payload, state.seq);
  state.seq = (state.seq + 1) & 0xff;
  state.txBytes += frame.length;
  state.writeChain = state.writeChain
    .then(() => link.write(frame))
    .catch((err) => console.error('write failed', err));
}

function setLinkUi(link, reason) {
  $('#btnConnect').hidden = !!link;
  $('#btnWifi').hidden = !!link || state.servedByBoard;
  $('#btnOtherPort').hidden = !!link || !SerialLink.supported() || state.servedByBoard;
  $('#wirelessPanel').hidden = !(link instanceof WsLink);
  $('#btnDemo').hidden = !!link;
  $('#btnDisconnect').hidden = !link;
  $('#portHint').hidden = true;
  const pill = $('#linkPill');
  pill.className = `pill ${link ? 'on' : 'off'}`;
  pill.textContent = link ? link.label : reason || 'No link';
  if (!link) render();
}

// ------------------------------------------------------------ receive
function onData(chunk) {
  state.rxBytes += chunk.length;
  for (const f of state.decoder.push(chunk)) {
    state.counts[f.cmd] = (state.counts[f.cmd] || 0) + 1;
    const d = decodePayload(f.cmd, f.data);
    if (f.cmd === CMD.SERVER_STATE && d) {
      const first = !state.server;
      state.server = d;
      state.serverAt = performance.now();
      if (first) panels.forEach(syncPanelInputs);
    } else if (f.cmd === CMD.EVENT && d) {
      logEvent(d);
    } else if (d) {
      state.real[f.cmd] = d;
      if (f.cmd === CMD.GAME_RESULT) addLogLine(null, 'k-revive', `round over: ${['draw', 'RED wins', 'BLUE wins'][d.winner] || '?'}`);
    }
    if (!state.rawPaused && !(f.cmd === CMD.POWER_HEAT && $('#hide0202').checked)) {
      state.rawLines.push(`${f.cmd.toString(16).padStart(4, '0')} ${(CMD_NAMES[f.cmd] || '?').padEnd(16)} ${hex(f.raw)}`);
      if (state.rawLines.length > 200) state.rawLines.splice(0, state.rawLines.length - 200);
    }
  }
}

function onBoardText(bytes) {
  const text = Array.from(bytes, (b) => (b === 10 || (b >= 32 && b < 127) ? String.fromCharCode(b) : '')).join('');
  if (!text.trim()) return;
  state.boardText = (state.boardText + text).split('\n').slice(-6).join('\n');
  const el = $('#boardText');
  el.hidden = false;
  el.textContent = state.boardText.trim();
}

// ------------------------------------------------------------ event log
function matchClock() {
  const s = state.server;
  if (!s) return '';
  if (s.stage === 4) return fmtTime(s.remain);
  return ['idle', 'setup', 'init', 'count', '', 'end'][s.stage] || '';
}

function addLogLine(robot, cls, text, valueText = '') {
  const li = document.createElement('li');
  const t = document.createElement('span');
  t.className = 't';
  t.textContent = matchClock();
  const body = document.createElement('span');
  if (robot !== null) {
    const who = document.createElement('span');
    who.className = `who r${SLOTS[robot].team}`;
    who.textContent = `${slotName(robot)} `;
    body.append(who);
  }
  const what = document.createElement('span');
  what.className = cls;
  what.textContent = text;
  body.append(what);
  const v = document.createElement('span');
  v.className = 'hpv';
  v.textContent = valueText;
  li.append(t, body, v);
  const log = $('#eventLog');
  log.prepend(li);
  while (log.children.length > 300) log.lastChild.remove();
  return li;
}

function eventText(e) {
  switch (e.kind) {
    case 1: {
      const what = e.detail & 0x40 ? 'collision' : e.detail & 0x20 ? '42 mm hit' : '17 mm hit';
      return `${what} on armor ${e.detail & 0xf}${e.detail & 0x80 ? ' (board button)' : ''}`;
    }
    case 3: return `launcher locked: ${LOCKS[e.detail] || e.detail}`;
    case 4: return 'buffer energy empty: chassis cut for 5 s';
    case 5: return `yellow card #${e.detail}`;
    case 6: return e.detail === 1 ? 'red card (third yellow): ejected' : 'red card: ejected';
    case 7: return 'forfeits the round';
    case 8: return 'killed by referee';
    case 9: return 'revived by referee';
    case 10: return 'abnormal disconnection: outputs off';
    case 11: return 'reconnected';
    case 12: return 'offline: -5 % max HP';
    case 13: return e.detail === 1 ? 'launcher unlocked (heat back to 0)' : 'launcher unlocked (speed lock over)';
    case 14: return `both teams yellow #${e.detail}: -5 %`;
    case 15: return e.detail === 0 ? `bought projectiles (now ${e.hp})` : 'exchange refused (not in resupply zone, Sentry, or not enough gold)';
    case 16: return "42 mm hit ignored: attacker's Hero is idle or down";
    case 17: return `respawned at ${e.hp} HP (invincible 30 s, weakened)`;
    case 19: return "teammate's yellow card: -5 %";
    default: return EVENT_KINDS[e.kind] || `event ${e.kind}`;
  }
}

function logEvent(e) {
  if (e.kind === 2) return; // shots are frequent; heat and projectile gauges show them
  if (e.kind === 1) flashPlate(e.robot, e.detail & 0xf);
  if (e.kind === 18) {
    addLogLine(null, 'k-capture', `capture point: ${['free', 'RED holds', 'BLUE holds', 'contested'][e.detail]}`);
    return;
  }
  const kind = EVENT_KINDS[e.kind] || `event-${e.kind}`;
  const text = eventText(e);
  const value = e.kind === 15 ? '' : `${e.hp} HP`;
  const last = state.lastLog;
  if (e.kind === 12 && last && last.robot === e.robot && last.kind === e.kind && last.li.isConnected) {
    last.n++;
    last.li.children[1].lastChild.textContent = `${text} ×${last.n}`;
    last.li.children[2].textContent = value;
  } else {
    const li = addLogLine(e.robot, `k-${kind}`, text, value);
    state.lastLog = { li, robot: e.robot, kind: e.kind, n: 1 };
  }
  if (e.hp === 0 && [1, 6, 8, 12].includes(e.kind)) addLogLine(e.robot, 'k-defeated', 'defeated');
  if ([1, 5, 12, 14, 19].includes(e.kind)) {
    const u = teams.flatMap((t) => t.units).find((x) => x.slot === e.robot);
    if (u) {
      u.el.classList.remove('flash');
      void u.el.offsetWidth;
      u.el.classList.add('flash');
    }
  }
}

function flashPlate(robot, armor) {
  const panel = panels[SLOTS[robot].team];
  if (slotOf(panel.t) !== robot) return;
  const p = panel.plates[armor];
  if (!p) return;
  p.classList.remove('hit');
  void p.getBoundingClientRect();
  p.classList.add('hit');
}

// ------------------------------------------------------------ render
function fmtTime(s) {
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function pct(a, b) {
  return b ? Math.max(0, Math.min(100, (100 * a) / b)) : 0;
}

function setChip(chip, cls, text) {
  chip.hidden = !text;
  chip.className = `chip ${cls}`;
  chip.textContent = text;
}

function renderUnit(u, r, s) {
  if (!r || !r.fielded) {
    u.el.classList.add('absent');
    u.hpValue.textContent = r ? '—' : '---';
    u.hpMax.textContent = r ? 'not fielded' : '';
    u.hpFill.style.width = u.hpGhost.style.width = '0%';
    for (const x of [u.heatValue, u.bufferValue, u.powerValue, u.ammoValue]) x.textContent = '';
    u.heatFill.style.width = u.bufferFill.style.width = '0%';
    u.badge.textContent = r ? '' : 'OFFLINE';
    u.badge.className = 'badge state-badge';
    u.link.hidden = true;
    u.cards.replaceChildren();
    for (const c of [u.chipShooter, u.chipChassis, u.chipGimbal, u.chipSpecial]) setChip(c, '', '');
    u.el.classList.remove('dead');
    return;
  }
  u.el.classList.remove('absent');
  u.hpValue.textContent = r.hp;
  u.hpMax.textContent = `/ ${r.maxHp}`;
  u.hpFill.style.width = u.hpGhost.style.width = `${pct(r.hp, r.maxHp)}%`;
  u.heatFill.style.width = `${pct(r.heat, r.heatLimit)}%`;
  u.heatBar.classList.toggle('over', r.heat > r.heatLimit);
  u.heatValue.textContent = `${r.heat} / ${r.heatLimit}`;
  u.bufferFill.style.width = `${pct(r.buffer, 60)}%`;
  u.bufferValue.textContent = `${r.buffer} J`;
  u.powerValue.textContent = `${r.power} / ${r.powerLimit} W`;
  u.ammoValue.textContent = u.el.classList.contains('compact')
    ? `${r.allowance} × ${r.cal42 ? '42' : '17'} mm`
    : `${r.allowance} ${r.cal42 ? '42 mm' : '17 mm'} (${r.shots} fired)`;
  u.link.hidden = s.link !== u.slot;
  const dead = !r.alive;
  u.badge.textContent = r.redCard ? 'EJECTED' : r.respawning ? `RESPAWN ${r.respawnS}s` : dead ? 'DEFEATED'
    : r.disconnected ? 'OFFLINE' : 'ONLINE';
  u.badge.className = `badge state-badge${dead || r.disconnected ? ' dead' : ''}`;
  u.el.classList.toggle('dead', dead);
  let shooter = ['on', 'Launcher on'];
  if (!r.shooterOn) {
    if (r.weakened) shooter = ['warn', 'Launcher locked: weakened'];
    else if (r.speedLocked) shooter = ['bad', r.speedLockS === 255 ? 'Launcher locked: speed (round)' : `Launcher locked: speed ${r.speedLockS} s`];
    else if (r.heatLocked) shooter = ['bad', 'Launcher locked: heat'];
    else if (r.allowance === 0 && r.alive) shooter = ['warn', 'No projectiles'];
    else shooter = ['', 'Launcher off'];
  }
  setChip(u.chipShooter, ...shooter);
  setChip(u.chipChassis, ...(r.chassisOn ? ['on', 'Chassis on']
    : r.chassisCutDs ? ['bad', `Chassis cut ${(r.chassisCutDs / 10).toFixed(1)} s`] : ['', 'Chassis off']));
  setChip(u.chipGimbal, ...(r.disconnected ? ['bad', 'Disconnected'] : r.gimbalOn ? ['on', 'Gimbal on'] : ['', 'Gimbal off']));
  const special = r.invincible ? ['on', `Invincible ${r.invincibleS} s`]
    : r.zone === 1 ? ['on', 'In resupply zone'] : r.zone === 2 ? ['warn', 'On capture point'] : ['', ''];
  setChip(u.chipSpecial, ...special);
  const cards = [];
  for (let k = 0; k < Math.min(r.yellow, 8); k++) cards.push('<span class="card yellow"></span>');
  if (r.redCard) cards.push('<span class="card red"></span>');
  u.cards.innerHTML = cards.length ? cards.join('') : '<span class="hint">none</span>';
}

function renderTeams(s) {
  const mode = modeOf(s);
  if (state.layout !== mode) buildTeams(mode);
  for (const tm of teams) {
    for (const u of tm.units) renderUnit(u, s?.robots[u.slot], s);
    if (mode === '3v3') {
      const t = s?.teams[tm.t];
      tm.vpValue.textContent = t ? t.vp : '---';
      tm.vpFill.style.width = `${t ? pct(t.vp, 200) : 0}%`;
      tm.coins.textContent = t ? t.coins : '';
      tm.dmg.textContent = t ? t.damage : '';
      setChip(tm.hero42, t?.heroLive ? 'on' : '', t ? (t.heroLive ? '42 mm hits count' : '42 mm hits blocked') : '');
    }
  }
}

function renderClock(s) {
  const stageEl = $('#stageName');
  const timeEl = $('#clockTime');
  const sub = $('#clockSub');
  const banner = $('#resultBanner');
  const cap = $('#captureInfo');
  $('#modeTag').textContent = modeOf(s);
  if (!s) {
    stageEl.textContent = state.link ? 'Waiting for board' : 'Not connected';
    stageEl.className = 'stage';
    timeEl.textContent = '--:--';
    timeEl.className = 'time';
    sub.innerHTML = '&nbsp;';
    banner.hidden = true;
    cap.hidden = true;
    $('#resultWhy').hidden = true;
    return;
  }
  stageEl.textContent = s.paused ? `${STAGES[s.stage]} · paused` : STAGES[s.stage] || `Stage ${s.stage}`;
  stageEl.className = `stage${s.stage === 4 ? ' combat' : ''}${s.paused ? ' paused' : ''}`;
  if (s.stage === 0) timeEl.textContent = fmtTime(s.combatTime);
  else if (s.stage === 5) timeEl.textContent = '0:00';
  else timeEl.textContent = fmtTime(s.remain);
  timeEl.className = `time${s.stage >= 1 && s.stage <= 3 ? ' countdown' : ''}`;
  sub.textContent = `${GAME_TYPES[s.gameType] || `type ${s.gameType}`} · link ${slotName(s.link)}`;
  cap.hidden = !s.mode3;
  cap.className = `capture c${s.capture}`;
  cap.textContent = `Capture point: ${['free', 'RED holds', 'BLUE holds', 'contested'][s.capture]}`;
  banner.hidden = s.stage !== 5;
  if (s.stage === 5) {
    const w = s.winner;
    banner.textContent = w === 1 ? 'RED WINS' : w === 2 ? 'BLUE WINS' : 'DRAW';
    banner.className = `result ${w === 1 ? 'red' : w === 2 ? 'blue' : 'draw'}`;
  }
  const why = $('#resultWhy');
  why.hidden = s.stage !== 5 || !WIN_REASONS[s.winReason];
  why.textContent = WIN_REASONS[s.winReason] || '';
}

function renderControls(s) {
  const connected = !!(state.link && s);
  const st = s?.stage ?? -1;
  const mode = modeOf(s);
  const enable = {
    1: st === 0,
    2: st === 0 || st === 1,
    3: st >= 1 && st <= 4 && !s?.paused,
    4: !!s?.paused,
    5: st >= 1 && st <= 4,
    6: true,
  };
  $$('[data-game]').forEach((b) => { b.disabled = !connected || !enable[b.dataset.game]; });
  $('#btnBothYellow').disabled = !connected;
  $$('.mode-seg .seg-btn').forEach((b) => {
    b.classList.toggle('active', b.dataset.mode === mode);
    b.setAttribute('aria-checked', b.dataset.mode === mode);
    b.disabled = !!state.link && (!s || st !== 0);
  });
  const combat = st === 4 && !s?.paused;
  for (const ui of panels) {
    const slot = slotOf(ui.t);
    const r = s?.robots[slot];
    ui.title.textContent = `${slotName(slot, mode)} controls`;
    ui.slotSeg.hidden = mode !== '3v3';
    $$('.seg-btn', ui.slotSeg).forEach((b) => b.classList.toggle('active', Number(b.dataset.role) === state.role[ui.t]));
    $$('.v3-only', ui.el).forEach((x) => { x.hidden = mode !== '3v3'; });
    ui.infRow.hidden = mode !== '3v3' || SLOTS[slot].role !== 'infantry';
    ui.el.classList.toggle('disabled', !connected || !combat || !r?.alive || r?.disconnected);
    ui.shoot.disabled = !connected || !combat || !r?.shooterOn;
    ui.shoot.textContent = r?.cal42 ? 'Fire 42 mm' : 'Fire 17 mm';
    ui.disconnect.textContent = r?.disconnected ? 'Reconnect' : 'Disconnect';
    $$('button, select, input', ui.el).filter((b) => b !== ui.shoot && !b.closest('.slot-seg'))
      .forEach((b) => { b.disabled = !connected || !r?.fielded; });
    $('.act-forfeit', ui.el).disabled = !connected || !(st >= 1 && st <= 4);
    ui.infChassis.disabled = ui.infLauncher.disabled = !connected || st > 1;
    $$('.seg-btn', ui.zoneSeg).forEach((b) => b.classList.toggle('active', Number(b.dataset.zone) === (r?.zone ?? 0)));
    const n = Math.max(1, Number(ui.buyN.value) || 0);
    ui.buyCost.textContent = r ? `${r.cal42 ? 10 * n : n} gold (${TEAM[ui.t]} has ${s.teams[ui.t].coins})` : '';
  }
  const form = $('#configForm');
  $$('input, select, button', form).forEach((x) => { x.disabled = !connected || st !== 0; });
  if (s && !state.configDirty && !form.contains(document.activeElement)) {
    form.combatTime.value = s.combatTime;
    form.setupTime.value = s.setupTime;
    form.link.value = String(s.link);
    fillStatsTable(s.robots.map((r) => ({
      fielded: r.fielded, cal42: r.cal42, maxHp: r.maxHp, heatLimit: r.heatLimit, cooling: r.cooling,
      powerLimit: r.powerLimit, speedLimit: r.speedLimit, allowance: r.allowance,
    })));
  }
}

function field(dl, name, value) {
  const dt = document.createElement('dt');
  dt.textContent = name;
  const dd = document.createElement('dd');
  dd.textContent = value;
  dl.append(dt, dd);
}

function renderLinkView() {
  const dl = $('#linkFields');
  dl.replaceChildren();
  const g = state.real[CMD.GAME_STATUS];
  const rs = state.real[CMD.ROBOT_STATUS];
  const ph = state.real[CMD.POWER_HEAT];
  const hp = state.real[CMD.ROBOT_HP];
  const ev = state.real[CMD.FIELD_EVENT];
  const buff = state.real[CMD.BUFF];
  const allow = state.real[CMD.ALLOWANCE];
  const rfid = state.real[CMD.RFID];
  const hurt = state.real[CMD.HURT];
  const shot = state.real[CMD.SHOOT];
  const warn = state.real[CMD.REFEREE_WARNING];
  $('#linkRobotName').textContent = rs ? `(robot_id ${rs.robotId})` : '';
  if (!g && !rs) field(dl, 'status', state.link ? 'waiting for frames' : 'not connected');
  if (g) {
    field(dl, '0x0001 game_type / progress', `${g.gameType} / ${g.progress} (${STAGES[g.progress] || '?'})`);
    field(dl, '0x0001 stage_remain_time', `${g.remain} s`);
    field(dl, '0x0001 SyncTimeStamp', g.timestamp ? new Date(g.timestamp * 1000).toLocaleTimeString() : '0');
  }
  if (rs) {
    field(dl, '0x0201 current_HP', `${rs.hp} / ${rs.maxHp}`);
    field(dl, '0x0201 heat limit / cooling', `${rs.heatLimit} / ${rs.cooling}`);
    field(dl, '0x0201 chassis_power_limit', `${rs.powerLimit} W`);
    field(dl, '0x0201 outputs', `gimbal ${rs.gimbalOn ? 'on' : 'off'}, chassis ${rs.chassisOn ? 'on' : 'off'}, shooter ${rs.shooterOn ? 'on' : 'off'}`);
  }
  if (ph) {
    field(dl, '0x0202 buffer_energy', `${ph.buffer} J`);
    field(dl, '0x0202 barrel heat 17 / 42 mm', `${ph.heat17} / ${ph.heat42}`);
  }
  if (hp) field(dl, '0x0003 ally HP 1 / 3 / 7', `${hp.ally1} / ${hp.ally3} / ${hp.ally7}`);
  if (ev && state.server?.mode3) {
    field(dl, '0x0101 resupply zone', ev.resupply ? 'occupied' : 'free');
    field(dl, '0x0101 center point', ['free', 'ours', 'enemy', 'both'][ev.center]);
  }
  if (buff && state.server?.mode3) field(dl, '0x0204 recovery / defence', `${buff.recovery} % / ${buff.defence} %`);
  if (allow) field(dl, '0x0208 allowance 17 / 42 mm, gold', `${allow.allow17} / ${allow.allow42}, ${allow.gold}`);
  if (rfid && state.server?.mode3) field(dl, '0x0209 RFID cards seen', [rfid.resupplyCard && 'resupply zone', rfid.centerCard && 'center point'].filter(Boolean).join(', ') || 'none');
  if (hurt) field(dl, '0x0206 last hurt', `armor ${hurt.armor}, ${HURT_REASONS[hurt.reason] || hurt.reason}`);
  if (shot) field(dl, '0x0207 last shot', `${shot.bulletType === 2 ? '42' : '17'} mm at ${shot.speed.toFixed(1)} m/s`);
  if (warn) field(dl, '0x0104 last warning', `level ${warn.level}, robot ${warn.offender}, count ${warn.count}`);

  const rows = Object.keys(state.counts).map(Number).sort((a, b) => a - b).map((c) => {
    const tr = document.createElement('tr');
    for (const v of [`0x${c.toString(16).padStart(4, '0')}`, CMD_NAMES[c] || '?', state.rates[c] ?? 0, state.counts[c]]) {
      const td = document.createElement('td');
      td.textContent = v;
      tr.append(td);
    }
    return tr;
  });
  $('#rateTable').replaceChildren(...rows);
}

function renderLinkStats() {
  const s = state.server;
  const pill = $('#linkPill');
  const silent = state.link instanceof SerialLink && !state.serverAt && performance.now() - state.connectedAt > 2500;
  $('#portHint').hidden = !silent;
  if (state.link) {
    const stale = !state.serverAt || performance.now() - state.serverAt > 1000;
    pill.className = `pill ${stale ? 'stale' : 'on'}`;
    pill.textContent = stale ? `${state.link.label} · no data` : state.link.label;
  }
  const rtt = state.link instanceof WsLink ? state.link.consoleRtt() : null;
  $('#linkStats').textContent = state.link
    ? `rx ${state.rxBytes} B · tx ${state.txBytes} B · bad ${state.decoder?.bad ?? 0}${s ? ` · board ok ${s.rxOk} / err ${s.rxErr}` : ''}`
      + (rtt ? ` · console RTT ${rtt.p50.toFixed(1)} ms` : '')
    : '';
}

// Colour thresholds for RTT: under 10 ms is well inside the 50 Hz frame
// period; over 30 ms a robot would notice.
const rttClass = (ms) => (ms == null ? '' : ms < 10 ? 'good' : ms < 30 ? 'fair' : 'bad');
const fmtMs = (ms) => (ms == null ? '–' : ms < 10 ? ms.toFixed(1) : String(Math.round(ms)));

function renderWireless() {
  if (!(state.link instanceof WsLink)) return;
  const w = state.wireless;
  const robots = w?.robots || [];
  $('#wirelessSummary').textContent = w
    ? `${robots.length} robot${robots.length === 1 ? '' : 's'} · pump ${w.pumpPeriodMs} ms (max gap ${w.pumpMaxGapMs} ms) · ${w.rt}`
      + ` · ${w.browsers} browser${w.browsers === 1 ? '' : 's'}${w.backend === 'fake' ? ' · FAKE BACKEND' : ''}`
    : 'waiting for the board…';
  $('#wirelessEmpty').hidden = robots.length > 0;
  $('#robotRows').replaceChildren(...robots.map((r) => {
    const tr = document.createElement('tr');
    if (r.ageMs > 1000) tr.className = 'gone';
    const cells = [
      [r.name], [r.ip], [fmtMs(r.rttP50), rttClass(r.rttP50)], [fmtMs(r.rttP99), rttClass(r.rttP99)],
      [fmtMs(r.rttMax), rttClass(r.rttMax)], [`${r.loss} %`, r.loss < 1 ? 'good' : r.loss < 5 ? 'fair' : 'bad'],
      [String(r.txFrames)], [String(r.txDrops), r.txDrops ? 'fair' : ''], [`${r.ageMs} ms`, r.ageMs > 1000 ? 'bad' : ''],
    ];
    for (const [text, cls] of cells) {
      const td = document.createElement('td');
      td.textContent = text;
      if (cls) td.className = cls;
      tr.append(td);
    }
    return tr;
  }));
}

function render() {
  const s = state.link ? state.server : null;
  renderTeams(s);
  renderClock(s);
  renderControls(s);
  renderLinkView();
  renderLinkStats();
  renderWireless();
  if (!state.rawPaused) $('#rawLog').textContent = state.rawLines.slice(-80).join('\n');
}

// Served by arc-refd on a Kria: connect straight away over WiFi.
WsLink.servedByBoard().then((yes) => {
  if (!yes) return;
  state.servedByBoard = true;
  $('#serialWarning').hidden = true;
  $('#btnConnect').disabled = false;
  $('#btnConnect').textContent = 'Connect board';
  $('#boardSub').textContent = 'FPGA referee \u00b7 Kria KR260 over WiFi';
  setLinkUi(null);
  connect(wifiLink());
});

buildTeams(state.uiMode);
fillStatsTable(modeRobots('1v1'));

setInterval(() => {
  for (const [c, n] of Object.entries(state.counts)) state.rates[c] = n - (state.lastCounts[c] || 0);
  state.lastCounts = { ...state.counts };
}, 1000);

(function loop() {
  render();
  setTimeout(() => requestAnimationFrame(loop), 100);
})();

// Exposed for debugging from the devtools console.
window.arcRef = { state, send, commands, HIT_KIND };
