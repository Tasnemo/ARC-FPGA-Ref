#!/usr/bin/env bash
# Installs the ARC referee on a Kria KR260 running AMD's Ubuntu 22.04 image.
#
#   git clone https://github.com/Tasnemo/ARC-FPGA-Ref && cd ARC-FPGA-Ref
#   sudo ./kria/install.sh            # install and start
#   sudo ./kria/install.sh --uninstall
#
# What it does:
#   1. copies the PL design (prebuilt/kr260/arc-ref.bit.bin + overlay) to
#      /lib/firmware/xilinx/arc-ref so `xmutil loadapp arc-ref` can load it;
#   2. copies arc_refd and the web console to /opt/arc-ref;
#   3. turns a USB WiFi adapter into the "ARC-REF" hotspot (2.4 GHz, so the
#      robots' ESP32s can join; power saving off for low latency);
#   4. installs the arc-refd systemd service, which loads the PL and starts
#      the daemon at boot.
#
# Settings (environment variables):
#   ARC_WIFI_SSID      (ARC-REF)      must match esp32/robot_link
#   ARC_WIFI_PASSWORD  (arcref2026)   must match esp32/robot_link, 8+ chars
#   ARC_WIFI_CHANNEL   (6)            2.4 GHz channel 1-11; pick the quietest
#   ARC_HTTP_PORT      (80)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=arc-ref
FW_DIR=/lib/firmware/xilinx/$APP
OPT=/opt/arc-ref
UNIT=/etc/systemd/system/arc-refd.service
NM_CON=ARC-REF
SSID="${ARC_WIFI_SSID:-ARC-REF}"
PASSWORD="${ARC_WIFI_PASSWORD:-arcref2026}"
CHANNEL="${ARC_WIFI_CHANNEL:-6}"
HTTP_PORT="${ARC_HTTP_PORT:-80}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"

if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now arc-refd 2>/dev/null || true
    rm -f "$UNIT"; systemctl daemon-reload
    command -v xmutil >/dev/null && xmutil unloadapp >/dev/null 2>&1 || true
    command -v nmcli >/dev/null && nmcli con delete "$NM_CON" >/dev/null 2>&1 || true
    rm -rf "$FW_DIR" "$OPT"
    say "removed arc-refd, the $NM_CON hotspot and $FW_DIR"
    exit 0
fi

[ "$(uname -m)" = aarch64 ] || warn "this doesn't look like the Kria (uname -m = $(uname -m))"
command -v python3 >/dev/null || die "python3 not found"
XMUTIL="$(command -v xmutil || true)"
[ -n "$XMUTIL" ] || die "xmutil not found. Use AMD's Kria Ubuntu 22.04 image, or: sudo snap install xlnx-config --classic --channel=2.x"

BIT="$ROOT/prebuilt/kr260/arc-ref.bit.bin"
[ -f "$BIT" ] || die "$BIT is missing. Someone with Vivado runs 'make bitstream-kr260' once and commits it (see prebuilt/README.md)."
[ ${#PASSWORD} -ge 8 ] || die "ARC_WIFI_PASSWORD must be at least 8 characters"

# ------------------------------------------------------------ PL firmware
say "installing the PL design to $FW_DIR"
mkdir -p "$FW_DIR"
install -m 0644 "$BIT" "$FW_DIR/$APP.bit.bin"
if command -v dtc >/dev/null; then
    dtc -q -@ -O dtb -o "$FW_DIR/$APP.dtbo" "$ROOT/kria/firmware/$APP.dtsi"
else
    install -m 0644 "$ROOT/kria/firmware/$APP.dtbo" "$FW_DIR/$APP.dtbo"
fi
install -m 0644 "$ROOT/kria/firmware/shell.json" "$FW_DIR/shell.json"

# ------------------------------------------------------------ daemon + UI
say "installing arc-refd and the console to $OPT"
rm -rf "$OPT"
mkdir -p "$OPT/kria"
install -m 0755 "$ROOT/kria/arc_refd.py" "$OPT/kria/arc_refd.py"
cp -r "$ROOT/web" "$OPT/web"

# ------------------------------------------------------------ WiFi hotspot
WIFI_IF=""
if command -v nmcli >/dev/null; then
    WIFI_IF="$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1; exit}')"
    if [ -n "$WIFI_IF" ]; then
        say "creating the $SSID hotspot on $WIFI_IF (2.4 GHz channel $CHANNEL)"
        nmcli con delete "$NM_CON" >/dev/null 2>&1 || true
        # ipv4.method shared: the board is 10.42.0.1 and hands out addresses.
        # powersave 2 = disabled: the radio never dozes between beacons.
        nmcli con add type wifi ifname "$WIFI_IF" con-name "$NM_CON" autoconnect yes ssid "$SSID" \
            802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel "$CHANNEL" \
            802-11-wireless.powersave 2 \
            wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.psk "$PASSWORD" \
            ipv4.method shared ipv6.method disabled >/dev/null
        nmcli con up "$NM_CON" >/dev/null || warn "hotspot didn't start; check 'nmcli con up $NM_CON' (does the adapter support AP mode?)"
        command -v iw >/dev/null && iw dev "$WIFI_IF" set power_save off 2>/dev/null || true
    else
        warn "no WiFi adapter found. Plug in a USB WiFi adapter that supports AP mode and re-run;"
        warn "until then the console still works over Ethernet."
    fi
else
    warn "NetworkManager (nmcli) not found; set up the hotspot by hand or 'apt install network-manager'"
fi

# ------------------------------------------------------------ service
say "installing the arc-refd service"
cat > "$UNIT" <<EOF
[Unit]
Description=ARC referee (PL referee core + WiFi bridge)
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-$XMUTIL unloadapp
ExecStartPre=$XMUTIL loadapp $APP
ExecStart=/usr/bin/python3 $OPT/kria/arc_refd.py --web $OPT/web --port $HTTP_PORT
Restart=on-failure
RestartSec=2
# The pump thread asks for SCHED_FIFO and locks its memory.
LimitRTPRIO=99
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable arc-refd >/dev/null
systemctl restart arc-refd
sleep 3
if systemctl is-active --quiet arc-refd; then
    say "arc-refd is running"
else
    journalctl -u arc-refd -n 20 --no-pager >&2 || true
    die "arc-refd failed to start (log above)"
fi

IPS="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -3 | tr '\n' ' ')"
PORT_SUFFIX=""; [ "$HTTP_PORT" = 80 ] || PORT_SUFFIX=":$HTTP_PORT"
echo
say "Done. On the laptop: join WiFi \"$SSID\" (password $PASSWORD) and open http://10.42.0.1$PORT_SUFFIX/"
[ -n "$IPS" ] && echo "    (also reachable at: $(for ip in $IPS; do printf 'http://%s%s/ ' "$ip" "$PORT_SUFFIX"; done))"
echo "    Robots: flash esp32/robot_link onto an ESP32 per robot; they show up in the Wireless link panel."
