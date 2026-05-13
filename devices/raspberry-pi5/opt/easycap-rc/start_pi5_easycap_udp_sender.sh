#!/bin/sh
set -eu

DEST_IP="${1:-100.97.231.5}"
PORT="${2:-5600}"
DEV="${3:-/dev/video0}"
WIDTH="${4:-720}"
HEIGHT="${5:-480}"
FPS="${6:-25}"

find_easycap() {
  v4l2-ctl --list-devices 2>/dev/null | awk '
    /MS210x|AV TO USB2\.0|MacroSilicon/ { grab=1; next }
    grab && $1 ~ /^\/dev\/video[0-9]+$/ { print $1; exit }
    NF == 0 { grab=0 }
  '
}

if [ ! -e "$DEV" ]; then
  DETECTED="$(find_easycap || true)"
  if [ -n "$DETECTED" ]; then
    DEV="$DETECTED"
  fi
fi

if [ ! -e "$DEV" ]; then
  echo "EasyCAP device not found. Expected $DEV" >&2
  exit 1
fi

exec python3 /opt/easycap-rc/easycap_udp_jpeg_sender_gst.py \
  --dest-ip "${DEST_IP}" \
  --port "${PORT}" \
  --device "${DEV}" \
  --width "${WIDTH}" \
  --height "${HEIGHT}" \
  --fps "${FPS}" \
  --usb-pulse-on-gap
