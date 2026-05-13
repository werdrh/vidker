#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

VID="${VID:-0x2ca3}"
PID="${PID:-}"
IFACE="${IFACE:-}"
EP_IN="${EP_IN:-}"
EP_OUT="${EP_OUT:-}"
DEST_IP="${DEST_IP:-127.0.0.1}"
DEST_PORT="${DEST_PORT:-5600}"

if [[ -z "$PID" || -z "$IFACE" || -z "$EP_IN" || -z "$EP_OUT" ]]; then
  cat >&2 <<EOF
Missing required env vars.

Run first:
  ./pi5_dji_probe.sh

Then start with discovered values, for example:
  PID=0x1234 IFACE=1 EP_IN=0x81 EP_OUT=0x02 DEST_IP=127.0.0.1 ./pi5_dji_liveview.sh

Optional:
  DEST_IP=100.97.231.5  # PC over Tailscale
  DEST_PORT=5600
EOF
  exit 2
fi

echo "[dji] starting bridge VID=$VID PID=$PID IFACE=$IFACE EP_IN=$EP_IN EP_OUT=$EP_OUT DEST=$DEST_IP:$DEST_PORT"
exec python3 ./radxa_goggles_bridge.py \
  --vid "$VID" \
  --pid "$PID" \
  --interface "$IFACE" \
  --ep-in "$EP_IN" \
  --ep-out "$EP_OUT" \
  --dest-ip "$DEST_IP" \
  --dest-port "$DEST_PORT" \
  --replay-trigger \
  --send-format-cmd \
  --dump-raw \
  --verbose
