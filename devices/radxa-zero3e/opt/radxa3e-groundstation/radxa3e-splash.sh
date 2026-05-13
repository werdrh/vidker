#!/usr/bin/env bash
set -euo pipefail

: "${SPLASH_IMAGE:=/opt/radxa3e-groundstation/no-signal.jpg}"
: "${FB_DEVICE:=/dev/fb0}"
: "${FB_WIDTH:=}"
: "${FB_HEIGHT:=}"
: "${SOURCE_MODE_FILE:=/etc/default/radxa3e-source-mode}"
: "${LINK_MODE_FILE:=/run/radxa3e-link-mode}"
: "${SPLASH_FONT:=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf}"

detect_fb_size() {
  local size_file width height
  size_file="/sys/class/graphics/$(basename "${FB_DEVICE}")/virtual_size"
  if [[ -r "${size_file}" ]]; then
    IFS=',' read -r width height < "${size_file}"
  fi
  FB_WIDTH="${FB_WIDTH:-${width:-1280}}"
  FB_HEIGHT="${FB_HEIGHT:-${height:-720}}"
}

mode_label() {
  local source text
  source="$(sed -n 's/^RADXA3E_SOURCE_MODE=//p' "${SOURCE_MODE_FILE}" 2>/dev/null | tail -n 1)"
  source="${source:-camera}"
  case "${source}" in
    camera) text="Оптика" ;;
    pi-local) text="PI Lan" ;;
    pi-internet) text="Internet" ;;
    *) text="MODE ${source^^}" ;;
  esac
  printf '%s' "${text}"
}

ff_escape() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g; s/:/\\\\:/g"
}

show_splash() {
  [[ -r "${SPLASH_IMAGE}" ]] || exit 0
  [[ -w "${FB_DEVICE}" ]] || exit 0
  detect_fb_size

  local label escaped filter
  label="$(mode_label)"
  escaped="$(ff_escape "${label}")"
  filter="scale=${FB_WIDTH}:${FB_HEIGHT}:force_original_aspect_ratio=decrease,pad=${FB_WIDTH}:${FB_HEIGHT}:(ow-iw)/2:(oh-ih)/2:black"
  if [[ -r "${SPLASH_FONT}" ]]; then
    filter="${filter},drawtext=fontfile=${SPLASH_FONT}:text='${escaped}':x=40:y=40:fontsize=34:fontcolor=white:borderw=3:bordercolor=black"
  fi
  filter="${filter},format=bgra"

  ffmpeg -v error -y \
    -i "${SPLASH_IMAGE}" \
    -vf "${filter}" \
    -frames:v 1 \
    -f rawvideo "${FB_DEVICE}" >/dev/null 2>&1 || true
}

case "${1:-show}" in
  show)
    show_splash
    ;;
  *)
    echo "Usage: $0 show" >&2
    exit 2
    ;;
esac
