#!/usr/bin/env bash
# router-diagnose.sh — find what's slowing down your home network.
# Run on a computer connected to the router (macOS or Linux):
#   bash router-diagnose.sh
# Read-only: it only pings, resolves names and downloads a test file.

set -u
OS="$(uname -s)"
PUBLIC_HOST="1.1.1.1"
LOAD_URL="https://speed.cloudflare.com/__down?bytes=100000000"

hr()   { printf '\n=== %s ===\n' "$1"; }
warn() { printf '  [!] %s\n' "$1"; }
ok()   { printf '  [ok] %s\n' "$1"; }

# --- Find the router (default gateway) --------------------------------------
if [ "$OS" = "Darwin" ]; then
  GW="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
  IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
else
  GW="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
  IFACE="$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')"
fi
[ -z "${GW:-}" ] && { echo "Could not find a default gateway. Are you connected?"; exit 1; }
hr "Router"
echo "  Gateway: $GW   Interface: $IFACE"

# ping stats helper -> prints "loss avg jitter" (jitter = mdev/stddev)
pstats() {
  local out loss rtt
  out="$(ping -c "${2:-20}" -i 0.2 "$1" 2>/dev/null)"
  loss="$(echo "$out" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')"
  rtt="$(echo "$out" | tail -1 | awk -F'= ' '{print $2}' | awk '{print $1}')"
  # rtt = min/avg/max/mdev
  echo "${loss:-100} $(echo "${rtt:-0/0/0/0}" | awk -F/ '{print $2, $4}')"
}

# --- 1. Local link: you -> router -------------------------------------------
hr "1. Your device -> router (Wi-Fi/Ethernet link)"
read -r L_LOSS L_AVG L_JIT <<<"$(pstats "$GW" 30)"
echo "  loss=${L_LOSS}%  avg=${L_AVG}ms  jitter=${L_JIT}ms"
awk "BEGIN{exit !($L_LOSS>1)}"   && warn "Packet loss to the router: weak Wi-Fi signal, interference, or a bad cable."
awk "BEGIN{exit !($L_AVG>10)}"   && warn "Slow to reach the router (>10ms): usually a Wi-Fi problem (distance, walls, crowded channel)."
awk "BEGIN{exit !($L_JIT>5)}"    && warn "High jitter on the local link: interference or the router CPU is overloaded."
awk "BEGIN{exit !($L_LOSS<=1 && $L_AVG<=10)}" && ok "Local link looks healthy."

# --- 2. Wi-Fi details ---------------------------------------------------------
hr "2. Wi-Fi signal and channel"
if [ "$OS" = "Darwin" ]; then
  system_profiler SPAirPortDataType 2>/dev/null \
    | awk '/Current Network Information:/{f=1} f&&/PHY Mode|Channel|Signal \/ Noise|Transmit Rate/{print "  "$0} /Other Local Wi-Fi Networks:/{exit}'
  echo "  Neighbouring networks on the same channel compete for airtime."
elif command -v iw >/dev/null 2>&1 && [ -n "$IFACE" ] && iw dev "$IFACE" link >/dev/null 2>&1; then
  iw dev "$IFACE" link | sed 's/^/  /'
  SIG="$(iw dev "$IFACE" link | awk '/signal/{print $2}')"
  [ -n "$SIG" ] && awk "BEGIN{exit !($SIG < -70)}" && warn "Signal ${SIG} dBm is weak (want better than -67). Move closer or add a mesh node."
  if command -v nmcli >/dev/null 2>&1; then
    echo "  Nearby networks (CHAN/SIGNAL):"
    nmcli -f SSID,CHAN,SIGNAL dev wifi list 2>/dev/null | head -15 | sed 's/^/    /'
  fi
else
  echo "  (Wired connection or no Wi-Fi tools found; skipped.)"
fi

# --- 3. Router -> internet ----------------------------------------------------
hr "3. Router -> internet (ISP link)"
read -r W_LOSS W_AVG W_JIT <<<"$(pstats "$PUBLIC_HOST" 30)"
echo "  loss=${W_LOSS}%  avg=${W_AVG}ms  jitter=${W_JIT}ms  (to $PUBLIC_HOST)"
EXTRA="$(awk "BEGIN{print $W_AVG-$L_AVG}")"
echo "  Latency added beyond the router: ${EXTRA}ms"
awk "BEGIN{exit !($W_LOSS>$L_LOSS+1)}" && warn "Loss appears past the router: likely the ISP line or modem. Call the ISP if it persists."
awk "BEGIN{exit !($EXTRA>60)}"         && warn "High latency past the router: ISP congestion or a long route."
awk "BEGIN{exit !($W_LOSS<=1 && $EXTRA<=60)}" && ok "ISP link looks healthy at idle."

# --- 4. DNS -------------------------------------------------------------------
hr "4. DNS lookup speed"
dnstime() { # $1 = server (optional)
  local t
  if command -v dig >/dev/null 2>&1; then
    t="$(dig +tries=1 +time=3 ${1:+@$1} "test-$RANDOM.example.com" 2>/dev/null | awk '/Query time/{print $4}')"
  fi
  echo "${t:-n/a}"
}
D_ROUTER="$(dnstime)"; D_CF="$(dnstime 1.1.1.1)"
echo "  Current DNS (usually the router): ${D_ROUTER}ms   Cloudflare 1.1.1.1: ${D_CF}ms"
if [ "$D_ROUTER" != "n/a" ] && [ "$D_CF" != "n/a" ]; then
  awk "BEGIN{exit !($D_ROUTER>100 && $D_ROUTER>2*$D_CF)}" \
    && warn "Your DNS is slow. Point the router's DNS at 1.1.1.1 / 8.8.8.8, which makes every page start loading sooner." \
    || ok "DNS speed is fine."
else
  echo "  ('dig' not installed; skipped.)"
fi

# --- 5. Bufferbloat: latency while the line is busy --------------------------
hr "5. Bufferbloat (latency under load, takes ~15s)"
curl -s -o /dev/null --max-time 15 "$LOAD_URL" &
CURL_PID=$!
sleep 2
read -r B_LOSS B_AVG B_JIT <<<"$(pstats "$PUBLIC_HOST" 50)"
wait "$CURL_PID" 2>/dev/null
BLOAT="$(awk "BEGIN{print $B_AVG-$W_AVG}")"
echo "  idle=${W_AVG}ms  loaded=${B_AVG}ms  increase=${BLOAT}ms"
if   awk "BEGIN{exit !($BLOAT>100)}"; then warn "Severe bufferbloat: calls and games lag whenever someone downloads. Turn on SQM / Smart Queue / QoS in the router."
elif awk "BEGIN{exit !($BLOAT>30)}";  then warn "Moderate bufferbloat. Turning on SQM/QoS (if your router has it) would help."
else ok "Little bufferbloat (grade A/B)."; fi

# --- 6. Busy network / other devices -----------------------------------------
hr "6. Devices on your network"
if [ "$OS" = "Darwin" ]; then N="$(arp -an | grep -vc incomplete)"; else N="$(ip neigh 2>/dev/null | grep -vc FAILED)"; fi
echo "  Devices recently seen: ${N}"
awk "BEGIN{exit !($N>30)}" && warn "Lots of devices. Check the router's client list for unknown ones or heavy users (backups, torrents, game updates)."

# --- 7. Router admin page -----------------------------------------------------
hr "7. Router admin page"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://$GW/")"
echo "  http://$GW/ responded with HTTP $CODE"
echo "  Log in there and check: firmware updates, CPU/memory load, uptime, connected clients, QoS/SQM settings."

hr "Done"
echo "Paste this output back to Claude to get a diagnosis."
