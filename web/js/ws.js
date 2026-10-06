// WebSocket transport to arc-refd on the Kria KR260 (over WiFi or Ethernet).
// Same shape as SerialLink: open(), close(), write(bytes), onData, onClose,
// plus onStatus(json) for the board's link report (robot RTT, loss, ...).
//
// Binary messages carry the referee byte stream (whole frames); text
// messages carry JSON: {"type":"hello"|"status"|"pong", ...}.

export const DEFAULT_BOARD = '10.42.0.1';   // the KR260's own WiFi hotspot

export class WsLink {
  constructor(host) {
    this.host = host;
    this.ws = null;
    this.onData = () => {};
    this.onClose = () => {};
    this.onStatus = () => {};
    this.label = 'Kria KR260 (WiFi)';
    this.rtt = [];             // browser <-> board round trips, ms
    this.pingTimer = 0;
  }

  static supported() {
    return 'WebSocket' in window;
  }

  // True when this page was served by arc-refd itself.
  static async servedByBoard() {
    if (!location.protocol.startsWith('http')) return false;
    try {
      const r = await fetch('api/info', { cache: 'no-store' });
      return r.ok && (await r.json()).app === 'arc-refd';
    } catch {
      return false;
    }
  }

  open() {
    const url = `ws://${this.host}/ws`;
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      let opened = false;
      const timer = setTimeout(() => { if (!opened) ws.close(); }, 4000);
      ws.onopen = () => {
        opened = true;
        clearTimeout(timer);
        this.ws = ws;
        this.pingTimer = setInterval(() => this.ping(), 1000);
        resolve();
      };
      ws.onmessage = (ev) => {
        if (typeof ev.data === 'string') this.onText(ev.data);
        else this.onData(new Uint8Array(ev.data));
      };
      ws.onclose = () => {
        clearTimeout(timer);
        clearInterval(this.pingTimer);
        if (!opened) {
          const err = new Error(`No referee board answered at ${url}`);
          err.name = 'BoardUnreachable';
          reject(err);
          return;
        }
        const was = this.ws;
        this.ws = null;
        if (was && !this.closing) this.onClose('Board connection lost');
      };
    });
  }

  onText(text) {
    let msg;
    try { msg = JSON.parse(text); } catch { return; }
    if (msg.type === 'pong' && typeof msg.t === 'number') {
      this.rtt.push(performance.now() - msg.t);
      if (this.rtt.length > 60) this.rtt.shift();
    } else if (msg.type === 'hello') {
      this.label = `${msg.board || 'Kria'} (${location.protocol === 'file:' ? this.host : 'WiFi'})`;
    } else if (msg.type === 'status') {
      this.onStatus(msg);
    }
  }

  ping() {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({ type: 'ping', t: performance.now() }));
  }

  consoleRtt() {
    if (!this.rtt.length) return null;
    const s = [...this.rtt].sort((a, b) => a - b);
    return { p50: s[Math.floor(s.length / 2)], max: s[s.length - 1] };
  }

  async write(bytes) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(bytes);
  }

  async close() {
    this.closing = true;
    clearInterval(this.pingTimer);
    try { this.ws?.close(); } catch { /* ignore */ }
    this.ws = null;
    this.onClose('Disconnected');
  }
}
