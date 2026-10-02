// Web Serial transport to the Zybo USB-UART (115200 8N1).
// Transports share one shape: open(), close(), write(bytes), and the
// callbacks onData(Uint8Array) / onClose(reason).

export class SerialLink {
  constructor() {
    this.port = null;
    this.reader = null;
    this.writer = null;
    this.onData = () => {};
    this.onClose = () => {};
    this.label = 'Zybo (USB-UART)';
  }

  static supported() {
    return 'serial' in navigator;
  }

  // allPorts=false shows only FTDI devices (the Zybo's FT2232H), which hides
  // Bluetooth and modem ports on macOS. allPorts=true is for other bridges.
  async open({ allPorts = false } = {}) {
    this.port = await navigator.serial.requestPort(allPorts ? {} : { filters: [{ usbVendorId: 0x0403 }] });
    await this.port.open({ baudRate: 115200, dataBits: 8, stopBits: 1, parity: 'none', bufferSize: 65536 });
    const info = this.port.getInfo();
    if (info.usbVendorId === 0x0403) this.label = 'Zybo (FTDI USB-UART)';
    this.writer = this.port.writable.getWriter();
    this.readLoop();
  }

  async readLoop() {
    while (this.port && this.port.readable) {
      this.reader = this.port.readable.getReader();
      try {
        for (;;) {
          const { value, done } = await this.reader.read();
          if (done) break;
          if (value) this.onData(value);
        }
      } catch (err) {
        // Framing/parity/buffer errors are recoverable: loop and re-acquire.
        if (err.name === 'NetworkError') {
          this.reader.releaseLock();
          this.closeQuietly('USB device disconnected');
          return;
        }
      } finally {
        try { this.reader.releaseLock(); } catch { /* already released */ }
      }
      if (this.closing) break;
    }
  }

  async write(bytes) {
    if (this.writer) await this.writer.write(bytes);
  }

  async close() {
    this.closing = true;
    try { await this.reader?.cancel(); } catch { /* ignore */ }
    try { this.writer?.releaseLock(); } catch { /* ignore */ }
    try { await this.port?.close(); } catch { /* ignore */ }
    this.port = null;
    this.onClose('Disconnected');
  }

  closeQuietly(reason) {
    this.port = null;
    this.writer = null;
    this.onClose(reason);
  }
}
