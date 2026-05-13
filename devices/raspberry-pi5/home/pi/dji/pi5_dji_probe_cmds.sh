#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

VID="${VID:-0x2ca3}"
PID="${PID:-}"
IFACE="${IFACE:-}"
EP_IN="${EP_IN:-}"
EP_OUT="${EP_OUT:-}"
CMD_SET="${CMD_SET:-9}"
CMD_ID="${CMD_ID:-2357}"
PAYLOAD_HEX="${PAYLOAD_HEX:-}"
DEST_IP="${DEST_IP:-127.0.0.1}"
DEST_PORT="${DEST_PORT:-5600}"

if [[ -z "$PID" || -z "$IFACE" || -z "$EP_IN" || -z "$EP_OUT" ]]; then
  echo "Need PID IFACE EP_IN EP_OUT. Run ./pi5_dji_probe.sh first." >&2
  exit 2
fi

echo "[dji] one-shot probe cmdSet=$CMD_SET cmdId=$CMD_ID payload=$PAYLOAD_HEX"
exec python3 ./radxa_goggles_bridge.py \
  --vid "$VID" \
  --pid "$PID" \
  --interface "$IFACE" \
  --ep-in "$EP_IN" \
  --ep-out "$EP_OUT" \
  --dest-ip "$DEST_IP" \
  --dest-port "$DEST_PORT" \
  --probe-cmd-set "$CMD_SET" \
  --probe-cmd-id "$CMD_ID" \
  --probe-payload-hex "$PAYLOAD_HEX" \
  --probe-wrap-55cc \
  --dump-raw \
  --verbose
