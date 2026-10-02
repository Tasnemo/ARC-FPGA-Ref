import {
  CMD, CMD_NAMES, EVENT_KINDS, GAME, GAME_TYPES, HURT_REASONS, LIFE, LOCKS, PENALTY, PRESETS,
  ROBOT_IDS, STAGES, WIN_REASONS, FrameDecoder, commands, decodePayload, encode, hex,
} from './protocol.js';
import { SerialLink } from './serial.js';
import { SimLink } from './sim.js';

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const TEAM_NAMES = ['RED 3', 'BLUE 103'];
const CONFIG_FIELDS = ['combatTime', 'setupTime', 'maxHp', 'hitDmg', 'heatLimit', 'cooling',
  'powerLimit', 'speedLimit', 'allowance'];

const state = {
  link: null,
  decoder: null,
  seq: 0,
  server: null,        // latest 0xF101
  serverAt: 0,
  real: {},            // latest decoded real frame per cmd_id
  counts: {},          // frames per cmd_id since connect
  rates: {},           // frames per second, refreshed every second
  lastCounts: {},
  rxBytes: 0,
  txBytes: 0,
  rawPaused: false,
  rawLines: [],
  boardText: '',
  lastHp: [null, null],
  writeChain: Promise.resolve(),
};

// ------------------------------------------------------------ build DOM
const teams = $$('.team').map((el) => {
  el.append($('#teamTemplate').content.cloneNode(true));
  const r = Number(el.dataset.team);
  $('.team-name', el).textContent = `${TEAM_NAMES[r]} · INFANTRY`;
  return {
    el,
    linkBadge: $('.link-badge', el),
    stateBadge: $('.state-badge', el),
    hpValue: $('.hp-value', el),
    hpMax: $('.hp-max', el),
    hpFill: $('.hp-bar .fill', el),
    hpGhost: $('.hp-bar .ghost', el),
    heatBar: $('.heat-bar', el),
    heatFill: $('.heat-bar .fill', el),
    heatValue: $('.heat-value', el),
    bufferFill: $('.buffer-bar .fill', el),
    bufferValue: $('.buffer-value', el),
    powerValue: $('.power-value', el),
    ammoValue: $('.ammo-value', el),
    cards: $('.cards', el),
    chipShooter: $('.chip-shooter', el),
    chipChassis: $('.chip-chassis', el),
    chipGimbal: $('.chip-gimbal', el),
  };
});

const robots = $$('.panel.robot').map((el) => {
  el.append($('#robotTemplate').content.cloneNode(true));
  const r = Number(el.dataset.robot);
  $('.robot-title', el).textContent = `${TEAM_NAMES[r]} controls`;
  const ui = {
    el,
    plates: $$('.plate', el),
    speed: $('.shoot-speed', el),
    powerIn: $('.power-in', el),
    powerOut: $('.power-out', el),
    disconnect: $('.act-disconnect', el),
  };
  $$('.hit-kind input', el).forEach((x) => { x.name = `hitKind${r}`; });
  const hitKind = () => Number($('.hit-kind input:checked', el)?.value || 0);
  ui.plates.forEach((p) => {
    p.setAttribute('tabindex', '0');
    const fire = () => {
      if (!el.classList.contains('disabled')) send(commands.hit(r, Number(p.dataset.armor), hitKind()));
    };
    p.addEventListener('click', fire);
    p.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fire(); } });
  });
  $('.act-shoot', el).addEventListener('click', () => {
    const speed = Math.max(0, Math.min(60, parseFloat(ui.speed.value) || 0));
    send(commands.shoot(r, 5, speed));
  });
  let powerTimer = null;
  ui.powerIn.addEventListener('input', () => {
    ui.powerOut.textContent = `${ui.powerIn.value} W`;
    clearTimeout(powerTimer);
    powerTimer = setTimeout(() => send(commands.power(r, Number(ui.powerIn.value))), 60);
  });
  $('.act-yellow', el).addEventListener('click', () => send(commands.penalty(r, PENALTY.YELLOW)));
  $('.act-red', el).addEventListener('click', () => {
    if (confirm(`Red card ${TEAM_NAMES[r]}? The robot is destroyed.`)) send(commands.penalty(r, PENALTY.RED));
  });
  $('.act-forfeit', el).addEventListener('click', () => {
    if (confirm(`${TEAM_NAMES[r]} forfeits? The match ends.`)) send(commands.penalty(r, PENALTY.FORFEIT));
  });
  $('.act-kill', el).addEventListener('click', () => send(commands.life(r, LIFE.KILL)));
  $('.act-revive', el).addEventListener('click', () => send(commands.life(r, LIFE.REVIVE)));
  ui.disconnect.addEventListener('click', () => {
    const offline = state.server?.robots[r]?.disconnected;
    send(commands.life(r, offline ? LIFE.RECONNECT : LIFE.DISCONNECT));
  });
  return ui;
});

$$('[data-game]').forEach((b) => {
  b.addEventListener('click', () => {
    const a = Number(b.dataset.game);
    if (a === GAME.END && !confirm('End the round now? The winner is decided by the 1v1 criteria.')) return;
    send(commands.game(a));
  });
});
$('#btnBothYellow').addEventListener('click', () => send(commands.penalty(0, PENALTY.BOTH_YELLOW)));

const presetSelect = $('#presetSelect');
for (const [key, p] of Object.entries(PRESETS)) presetSelect.append(new Option(p.label, key));
presetSelect.append(new Option('Custom', 'custom'));
presetSelect.addEventListener('change', () => {
  const p = PRESETS[presetSelect.value];
  if (!p) return;
  const form = $('#configForm');
  form.gameType.value = String(p.gameType);
  for (const k of CONFIG_FIELDS) form[k].value = p[k];
  configDirty = true;
});

$('#configForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  const n = (k) => Math.max(0, Math.min(0xffff, Math.round(Number(f.get(k)) || 0)));
  const c = { gameType: n('gameType'), link: n('link') };
  for (const k of CONFIG_FIELDS) c[k] = n(k);
  send(commands.config(c));
  configDirty = false;
});
let configDirty = false;
$('#configForm').addEventListener('input', (e) => {
  configDirty = true;
  if (e.target !== presetSelect) presetSelect.value = 'custom';
});

$('#btnClearLog').addEventListener('click', () => { $('#eventLog').replaceChildren(); });
$('#btnPauseRaw').addEventListener('click', (e) => {
  state.rawPaused = !state.rawPaused;
  e.target.textContent = state.rawPaused ? 'Resume' : 'Pause';
});

// ------------------------------------------------------------ transport
if (!SerialLink.supported()) {
  $('#serialWarning').hidden = false;
  $('#btnConnect').disabled = true;
}

$('#btnConnect').addEventListener('click', () => connect(new SerialLink()));
$('#btnOtherPort').addEventListener('click', () => connect(new SerialLink(), { allPorts: true }));
$('#btnDemo').addEventListener('click', () => connect(new SimLink()));
$('#btnDisconnect').addEventListener('click', () => state.link?.close());

async function connect(link, openOpts) {
  await state.link?.close();
  Object.assign(state, {
    decoder: new FrameDecoder(), server: null, serverAt: 0, real: {}, counts: {}, rates: {},
    lastCounts: {}, rxBytes: 0, txBytes: 0, rawLines: [], boardText: '', lastHp: [null, null],
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
    alert(err.name === 'NetworkError' || err.name === 'InvalidStateError'
      ? 'That port is busy. Close any serial terminal (PuTTY, screen, Vitis/Vivado serial console) using it and try again.'
      : `Could not open the port: ${err.message}`);
    return;
  }
  state.link = link;
  state.connectedAt = performance.now();
  setLinkUi(link);
  // Give the board wall-clock time for SyncTimeStamp.
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
  $('#btnDemo').hidden = !!link;
  $('#btnOtherPort').hidden = !!link || !SerialLink.supported();
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
      state.server = d;
      state.serverAt = performance.now();
    } else if (f.cmd === CMD.EVENT && d) {
      logEvent(d);
    } else if (d) {
      state.real[f.cmd] = d;
      if (f.cmd === CMD.GAME_RESULT || f.cmd === CMD.REFEREE_WARNING) logReal(f.cmd, d);
    }
    if (!state.rawPaused && !(f.cmd === CMD.POWER_HEAT && $('#hide0202').checked)) {
      state.rawLines.push(`${f.cmd.toString(16).padStart(4, '0')} ${(CMD_NAMES[f.cmd] || '?').padEnd(15)} ${hex(f.raw)}`);
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

function addLogLine(robot, cls, text, hpText = '') {
  const li = document.createElement('li');
  const t = document.createElement('span');
  t.className = 't';
  t.textContent = matchClock();
  const body = document.createElement('span');
  if (robot !== null) {
    const who = document.createElement('span');
    who.className = `who r${robot}`;
    who.textContent = `${TEAM_NAMES[robot]} `;
    body.append(who);
  }
  const what = document.createElement('span');
  what.className = cls;
  what.textContent = text;
  body.append(what);
  const hp = document.createElement('span');
  hp.className = 'hpv';
  hp.textContent = hpText;
  li.append(t, body, hp);
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
    default: return EVENT_KINDS[e.kind] || `event ${e.kind}`;
  }
}

function logEvent(e) {
  const kind = EVENT_KINDS[e.kind] || `event-${e.kind}`;
  if (e.kind === 1) flashPlate(e.robot, e.detail & 0xf);
  if (e.kind === 2) return; // shots are frequent; heat and projectile gauges show them
  const text = eventText(e);
  // Offline drain repeats every second; fold a run into one line.
  const last = state.lastLog;
  if (e.kind === 12 && last && last.robot === e.robot && last.kind === e.kind && last.li.isConnected) {
    last.n++;
    last.li.children[1].lastChild.textContent = `${text} ×${last.n}`;
    last.li.children[2].textContent = `${e.hp} HP`;
  } else {
    const li = addLogLine(e.robot, `k-${kind}`, text, `${e.hp} HP`);
    state.lastLog = { li, robot: e.robot, kind: e.kind, n: 1 };
  }
  if (e.hp === 0 && [1, 6, 8, 12].includes(e.kind)) addLogLine(e.robot, 'k-defeated', 'defeated');
  if ([1, 5, 12, 14].includes(e.kind)) {
    teams[e.robot].el.classList.remove('flash');
    void teams[e.robot].el.offsetWidth;
    teams[e.robot].el.classList.add('flash');
  }
}

function logReal(cmd, d) {
  if (cmd === CMD.GAME_RESULT) {
    addLogLine(null, 'k-revive', `round over: ${['draw', 'RED wins', 'BLUE wins'][d.winner] || '?'}`);
  }
}

function flashPlate(robot, armor) {
  const p = robots[robot]?.plates[armor];
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

function renderTeams(s) {
  teams.forEach((t, i) => {
    const r = s?.robots[i];
    if (!r) {
      t.hpValue.textContent = '---';
      t.hpMax.textContent = '';
      t.hpFill.style.width = t.hpGhost.style.width = '0%';
      t.heatValue.textContent = t.bufferValue.textContent = t.powerValue.textContent = t.ammoValue.textContent = '';
      for (const c of [t.chipShooter, t.chipChassis, t.chipGimbal]) { c.textContent = ''; c.hidden = true; }
      t.heatFill.style.width = t.bufferFill.style.width = '0%';
      t.stateBadge.textContent = 'OFFLINE';
      t.stateBadge.className = 'badge state-badge';
      t.linkBadge.hidden = true;
      t.cards.replaceChildren();
      t.el.classList.remove('dead');
      return;
    }
    t.hpValue.textContent = r.hp;
    t.hpMax.textContent = `/ ${r.maxHp}`;
    t.hpFill.style.width = `${pct(r.hp, r.maxHp)}%`;
    t.hpGhost.style.width = `${pct(r.hp, r.maxHp)}%`;
    t.heatFill.style.width = `${pct(r.heat, r.heatLimit)}%`;
    t.heatBar.classList.toggle('over', r.heat > r.heatLimit);
    t.heatValue.textContent = `${r.heat} / ${r.heatLimit}`;
    t.bufferFill.style.width = `${pct(r.buffer, 60)}%`;
    t.bufferValue.textContent = `${r.buffer} J`;
    t.powerValue.textContent = `${r.power} / ${r.powerLimit} W`;
    t.ammoValue.textContent = `${r.allowance} (${r.shots} fired)`;
    t.linkBadge.hidden = s.link !== i;
    const dead = !r.alive;
    t.stateBadge.textContent = r.redCard ? 'EJECTED' : dead ? 'DEFEATED' : r.disconnected ? 'OFFLINE' : 'ONLINE';
    let shooter = ['on', 'Launcher on'];
    if (!r.shooterOn) {
      if (r.speedLocked) shooter = ['bad', r.speedLockS === 255 ? 'Launcher locked: speed (round)' : `Launcher locked: speed ${r.speedLockS} s`];
      else if (r.heatLocked) shooter = ['bad', 'Launcher locked: heat'];
      else if (r.allowance === 0 && r.alive) shooter = ['warn', 'No projectiles'];
      else shooter = ['', 'Launcher off'];
    }
    const chassis = r.chassisOn ? ['on', 'Chassis on']
      : r.chassisCutDs ? ['bad', `Chassis cut ${(r.chassisCutDs / 10).toFixed(1)} s`] : ['', 'Chassis off'];
    const gimbal = r.disconnected ? ['bad', 'Disconnected'] : r.gimbalOn ? ['on', 'Gimbal on'] : ['', 'Gimbal off'];
    for (const [chip, [cls, text]] of [[t.chipShooter, shooter], [t.chipChassis, chassis], [t.chipGimbal, gimbal]]) {
      chip.hidden = false;
      chip.className = `chip ${cls}`;
      chip.textContent = text;
    }
    t.stateBadge.className = `badge state-badge${dead || r.disconnected ? ' dead' : ''}`;
    t.el.classList.toggle('dead', dead);
    const cards = [];
    for (let k = 0; k < Math.min(r.yellow, 8); k++) cards.push('<span class="card yellow"></span>');
    if (r.redCard) cards.push('<span class="card red"></span>');
    t.cards.innerHTML = cards.length ? cards.join('') : '<span class="hint">none</span>';
  });
}

function renderClock(s) {
  const stageEl = $('#stageName');
  const timeEl = $('#clockTime');
  const sub = $('#clockSub');
  const banner = $('#resultBanner');
  if (!s) {
    stageEl.textContent = state.link ? 'Waiting for board' : 'Not connected';
    stageEl.className = 'stage';
    timeEl.textContent = '--:--';
    timeEl.className = 'time';
    sub.innerHTML = '&nbsp;';
    banner.hidden = true;
    $('#resultWhy').hidden = true;
    return;
  }
  stageEl.textContent = s.paused ? `${STAGES[s.stage]} · paused` : STAGES[s.stage] || `Stage ${s.stage}`;
  stageEl.className = `stage${s.stage === 4 ? ' combat' : ''}${s.paused ? ' paused' : ''}`;
  if (s.stage === 0) timeEl.textContent = fmtTime(s.combatTime);
  else if (s.stage === 5) timeEl.textContent = '0:00';
  else timeEl.textContent = fmtTime(s.remain);
  timeEl.className = `time${s.stage >= 1 && s.stage <= 3 ? ' countdown' : ''}`;
  sub.textContent = `${GAME_TYPES[s.gameType] || `type ${s.gameType}`} · link ${TEAM_NAMES[s.link]}`;
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
  const enable = {
    1: st === 0,
    2: st === 0 || st === 1,
    3: st >= 1 && st <= 4 && !s?.paused,
    4: !!s?.paused,
    5: st >= 1 && st <= 4,
    6: true,
  };
  $$('[data-game]').forEach((b) => { b.disabled = !connected || !enable[b.dataset.game]; });
  const combat = st === 4 && !s?.paused;
  $('#btnBothYellow').disabled = !connected;
  robots.forEach((ui, i) => {
    const r = s?.robots[i];
    ui.el.classList.toggle('disabled', !connected || !combat || !r?.alive || r?.disconnected);
    $('.act-shoot', ui.el).disabled = !connected || !combat || !r?.shooterOn;
    ui.disconnect.textContent = r?.disconnected ? 'Reconnect' : 'Disconnect';
    $$('button', ui.el).filter((b) => !b.classList.contains('act-shoot')).forEach((b) => { b.disabled = !connected; });
    $$('.hit-kind input', ui.el).forEach((x) => { x.disabled = !connected; });
    $('.act-forfeit', ui.el).disabled = !connected || !(st >= 1 && st <= 4);
    ui.powerIn.disabled = !connected;
  });
  const form = $('#configForm');
  $$('input, select, button', form).forEach((x) => { x.disabled = !connected || st !== 0; });
  if (s && !configDirty && document.activeElement?.form !== form) {
    const live = {
      gameType: s.gameType, combatTime: s.combatTime, setupTime: s.setupTime, maxHp: s.robots[0].maxHp,
      hitDmg: s.hitDmg, heatLimit: s.robots[0].heatLimit, cooling: s.cooling,
      powerLimit: s.robots[0].powerLimit, speedLimit: s.speedLimit, allowance: null,
    };
    form.gameType.value = String(s.gameType);
    form.link.value = String(s.link);
    for (const k of CONFIG_FIELDS) if (live[k] !== null) form[k].value = live[k];
    if (st === 0) form.allowance.value = s.robots[0].allowance;
    const match = Object.entries(PRESETS).find(([, p]) => CONFIG_FIELDS.every((k) => live[k] === null || p[k] === live[k])
      && p.gameType === s.gameType);
    presetSelect.value = match ? match[0] : 'custom';
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
  const hurt = state.real[CMD.HURT];
  const shot = state.real[CMD.SHOOT];
  const warn = state.real[CMD.REFEREE_WARNING];
  $('#linkRobotName').textContent = rs ? `(robot_id ${rs.robotId})` : '';
  if (!g && !rs) {
    field(dl, 'status', state.link ? 'waiting for frames' : 'not connected');
  }
  if (g) {
    field(dl, '0x0001 game_progress', `${g.progress} (${STAGES[g.progress] || '?'})`);
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
    field(dl, '0x0202 17mm barrel heat', `${ph.heat17}`);
  }
  if (hp) field(dl, '0x0003 ally_3 HP', `${hp.ally3}`);
  if (hurt) field(dl, '0x0206 last hurt', `armor ${hurt.armor}, ${HURT_REASONS[hurt.reason] || hurt.reason}`);
  if (shot) field(dl, '0x0207 last shot', `${shot.speed.toFixed(1)} m/s`);
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
  // Connected but nothing decodable after 2.5 s: almost always the wrong port.
  const silent = state.link instanceof SerialLink && !state.serverAt
    && performance.now() - state.connectedAt > 2500;
  $('#portHint').hidden = !silent;
  if (state.link) {
    const stale = !state.serverAt || performance.now() - state.serverAt > 1000;
    pill.className = `pill ${stale ? 'stale' : 'on'}`;
    pill.textContent = stale ? `${state.link.label} · no data` : state.link.label;
  }
  $('#linkStats').textContent = state.link
    ? `rx ${state.rxBytes} B · tx ${state.txBytes} B · bad ${state.decoder?.bad ?? 0}${s ? ` · board ok ${s.rxOk} / err ${s.rxErr}` : ''}`
    : '';
}

function render() {
  const s = state.link ? state.server : null;
  renderTeams(s);
  renderClock(s);
  renderControls(s);
  renderLinkView();
  renderLinkStats();
  if (!state.rawPaused) $('#rawLog').textContent = state.rawLines.slice(-80).join('\n');
}

setInterval(() => {
  for (const [c, n] of Object.entries(state.counts)) {
    state.rates[c] = n - (state.lastCounts[c] || 0);
  }
  state.lastCounts = { ...state.counts };
}, 1000);

(function loop() {
  render();
  setTimeout(() => requestAnimationFrame(loop), 100);
})();

// Exposed for debugging from the devtools console.
window.arcRef = { state, send, commands, ROBOT_IDS };
