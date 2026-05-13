#!/bin/sh
set -eu

ENV_FILE="${ENV_FILE:-/run/pi-easycap.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

DEST_IP="${DEST_IP:-192.168.121.51}"
DEST_PORT="${DEST_PORT:-5600}"
DEV="${DEV:-/dev/video0}"
WIDTH="${WIDTH:-720}"
HEIGHT="${HEIGHT:-480}"
OUT_WIDTH="${OUT_WIDTH:-1280}"
OUT_HEIGHT="${OUT_HEIGHT:-720}"
FPS="${FPS:-25}"
BITRATE="${BITRATE:-2500000}"

find_easycap() {
  v4l2-ctl --list-devices 2>/dev/null | awk '
    /MS210x|AV TO USB2\.0|MacroSilicon/ { grab=1; next }
    grab && $1 ~ /^\/dev\/video[0-9]+$/ { print $1; exit }
    NF == 0 { grab=0 }
  '
}

if [ ! -e "$DEV" ]; then
  detected="$(find_easycap || true)"
  [ -n "$detected" ] && DEV="$detected"
fi

if [ ! -e "$DEV" ]; then
  echo "EasyCAP device not found. Expected $DEV" >&2
  exit 1
fi

v4l2-ctl -d "$DEV" --set-ctrl=brightness=26,contrast=140,saturation=150,hue=0,backlight_compensation=0 >/dev/null 2>&1 || true

exec gst-launch-1.0 -e \
  v4l2src device="$DEV" io-mode=mmap do-timestamp=true ! \
  image/jpeg,width="$WIDTH",height="$HEIGHT",framerate="$FPS/1" ! \
  queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream ! \
  jpegdec ! \
  videoconvert ! \
  videoscale method=0 add-borders=false ! \
  video/x-raw,format=I420,width="$OUT_WIDTH",height="$OUT_HEIGHT",pixel-aspect-ratio=1/1,framerate="$FPS/1" ! \
  queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream ! \
  openh264enc rate-control=bitrate bitrate="$BITRATE" max-bitrate="$BITRATE" complexity=low gop-size="$FPS" enable-frame-skip=true multi-thread=4 ! \
  h264parse config-interval=-1 ! \
  rtph264pay pt=96 mtu=1200 config-interval=1 ! \
  udpsink host="$DEST_IP" port="$DEST_PORT" sync=false async=false buffer-size=65536
