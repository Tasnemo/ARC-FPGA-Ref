// ARC referee wireless receiver, one per robot (ESP32, Arduino core 2.x or 3.x).
//
// Plays the part of the referee module bolted to a real robot: it joins the
// KR260's "ARC-REF" WiFi network, receives referee frames from arc-refd over
// UDP and writes them straight out of a UART into the robot controller's
// referee port, exactly as the official module's serial cable would. Bytes
// the robot sends back (0x0301 interaction data etc.) go the other way.
//
// Real-time choices:
//   * WiFi power save off: the radio never sleeps between beacons, which
//     otherwise adds up to ~100 ms of delay.
//   * Every datagram is written to the UART the moment it arrives; nothing
//     is buffered or reordered. The board already paces frames to the
//     115200-baud link, so the UART never backs up.
//   * Pings from the board are answered immediately, so the console shows
//     the real round-trip time to this robot.
//
// Wiring (ESP32 DevKit defaults, change below for other boards):
//   ESP32 GPIO17 (TX) -> robot referee port RX
//   ESP32 GPIO16 (RX) <- robot referee port TX
//   ESP32 GND         -- robot GND
// Both sides must be 3.3 V logic (the RoboMaster referee UART is).
//
// Build: Arduino IDE (board "ESP32 Dev Module"), or
//   arduino-cli compile --fqbn esp32:esp32:esp32 esp32/robot_link

#include <WiFi.h>
#include <WiFiUdp.h>
#include <esp_wifi.h>

// ------------------------------------------------------------- settings
static const char *WIFI_SSID     = "ARC-REF";
static const char *WIFI_PASSWORD = "arcref2026";   // must match kria/install.sh
static const char *ROBOT_NAME    = "red-infantry"; // shown in the console
static const uint16_t BOARD_PORT = 7400;           // arc-refd UDP port
static const uint16_t LOCAL_PORT = 7401;
// The KR260 is the access point, so it is the gateway. Set an address here
// only if the board is reached some other way (e.g. a venue router).
static const char *BOARD_IP_OVERRIDE = "";

static const int      UART_RX_PIN = 16;
static const int      UART_TX_PIN = 17;
static const uint32_t UART_BAUD   = 115200;        // RoboMaster referee serial
static const int      LED_PIN     = 2;             // on while referee data flows

// ------------------------------------------------------------- protocol
enum : uint8_t { DGRAM_REF = 0, DGRAM_PING = 1, DGRAM_PONG = 2, DGRAM_HELLO = 3 };

static const uint32_t HELLO_MS      = 500;
static const uint32_t LINK_LIVE_MS  = 500;
static const size_t   UPLINK_MAX    = 256;
static const uint32_t UPLINK_GAP_US = 1000;        // flush robot->board after 1 ms idle

HardwareSerial RefSerial(2);
WiFiUDP udp;
IPAddress boardIp;
uint8_t rxBuf[1500];
uint8_t upBuf[1 + UPLINK_MAX];
size_t upLen = 0;
uint32_t lastUpByteUs = 0, lastHelloMs = 0, lastRefMs = 0;
bool wasConnected = false;

void sendHello() {
  udp.beginPacket(boardIp, BOARD_PORT);
  udp.write(DGRAM_HELLO);
  udp.write((const uint8_t *)ROBOT_NAME, strlen(ROBOT_NAME));
  udp.endPacket();
}

void flushUplink() {
  if (upLen == 0) return;
  udp.beginPacket(boardIp, BOARD_PORT);
  upBuf[0] = DGRAM_REF;
  udp.write(upBuf, 1 + upLen);
  udp.endPacket();
  upLen = 0;
}

void onConnected() {
  boardIp = WiFi.gatewayIP();
  if (BOARD_IP_OVERRIDE[0]) boardIp.fromString(BOARD_IP_OVERRIDE);
  udp.begin(LOCAL_PORT);
  Serial.printf("[robot_link] %s on %s, board %s:%u\n", ROBOT_NAME,
                WiFi.localIP().toString().c_str(), boardIp.toString().c_str(), BOARD_PORT);
  sendHello();
  lastHelloMs = millis();
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);
  RefSerial.setRxBufferSize(1024);
  RefSerial.setTxBufferSize(1024);
  RefSerial.begin(UART_BAUD, SERIAL_8N1, UART_RX_PIN, UART_TX_PIN);

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  esp_wifi_set_ps(WIFI_PS_NONE);
  Serial.printf("[robot_link] joining %s ...\n", WIFI_SSID);
}

void loop() {
  bool connected = WiFi.status() == WL_CONNECTED;
  if (connected && !wasConnected) onConnected();
  if (!connected && wasConnected) {
    udp.stop();
    Serial.println("[robot_link] WiFi lost, reconnecting");
  }
  wasConnected = connected;
  uint32_t nowMs = millis();
  digitalWrite(LED_PIN, connected && nowMs - lastRefMs < LINK_LIVE_MS ? HIGH : LOW);
  if (!connected) {
    delay(1);
    return;
  }

  // Board -> robot: drain every pending datagram.
  for (int n = udp.parsePacket(); n > 0; n = udp.parsePacket()) {
    int len = udp.read(rxBuf, sizeof rxBuf);
    if (len <= 0) continue;
    switch (rxBuf[0]) {
      case DGRAM_REF:
        RefSerial.write(rxBuf + 1, len - 1);
        lastRefMs = nowMs;
        break;
      case DGRAM_PING:
        rxBuf[0] = DGRAM_PONG;
        udp.beginPacket(udp.remoteIP(), udp.remotePort());
        udp.write(rxBuf, len);
        udp.endPacket();
        break;
    }
  }

  // Robot -> board: batch bytes until the line goes quiet or the buffer fills.
  while (RefSerial.available() && upLen < UPLINK_MAX) {
    upBuf[1 + upLen++] = (uint8_t)RefSerial.read();
    lastUpByteUs = micros();
  }
  if (upLen == UPLINK_MAX || (upLen && micros() - lastUpByteUs > UPLINK_GAP_US)) flushUplink();

  if (nowMs - lastHelloMs >= HELLO_MS) {
    lastHelloMs = nowMs;
    sendHello();
  }
}
