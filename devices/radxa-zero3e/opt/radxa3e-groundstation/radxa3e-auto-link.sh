#!/bin/sh
set -eu

LOCAL_PI_IP="${LOCAL_PI_IP:-192.168.121.50}"
CAMERA_IP="${CAMERA_IP:-192.168.121.50}"
TAILSCALE_PI_HOST="${TAILSCALE_PI_HOST:-ground}"
TAILSCALE_PI_FALLBACK_IP="${TAILSCALE_PI_FALLBACK_IP:-100.91.223.27}"
LOCAL_RADXA_IP="${LOCAL_RADXA_IP:-192.168.121.51}"
TAILSCALE_RADXA_IP="${TAILSCALE_RADXA_IP:-100.80.47.96}"
PI_SOURCE_MODE_PORT="${PI_SOURCE_MODE_PORT:-5513}"
CONTROL_DEFAULTS="${CONTROL_DEFAULTS:-/etc/default/radxa3e-control-bridge}"
OSD_DEFAULTS="${OSD_DEFAULTS:-/etc/default/radxa3e-osd-status}"
MODE_FILE="${MODE_FILE:-/run/radxa3e-link-mode}"
SOURCE_MODE_FILE="${SOURCE_MODE_FILE:-/etc/default/radxa3e-source-mode}"
SPLASH_ACTIVE_FILE="${SPLASH_ACTIVE_FILE:-/run/radxa3e-splash-active}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
SWITCH_CONFIRMATIONS="${SWITCH_CONFIRMATIONS:-3}"

PIXELPILOT_CMD='pixelpilot -p 5600 --codec h264 --screen-mode 1920x1080@60 --wfb-api-port 0 --osd --osd-elements 0 --osd-refresh 250 --osd-custom-message --osd-config /opt/radxa3e-groundstation/pixelpilot-osd-minimal.json --dvr-framerate 60 --dvr-fmp4 --dvr-sequenced-files --dvr-template /media/recordings/fpv_%Y-%m-%d_%H-%M-%S.fmp4'

tailscale_ok() {
  target="$1"
  if command -v tailscale >/dev/null 2>&1; then
    tailscale ping --timeout=3s --c 1 "$target" >/dev/null 2>&1 && return 0
  fi
  ping -c 1 -W 1 "$target" >/dev/null 2>&1
}

set_kv() {
  file="$1"
  key="$2"
  value="$3"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

choose_target() {
  source_mode="$(sed -n 's/^RADXA3E_SOURCE_MODE=//p' "$SOURCE_MODE_FILE" 2>/dev/null | tail -n 1)"
  source_mode="${source_mode:-camera}"
  case "$source_mode" in
    camera|optics)
      printf '%s camera\n' "$CAMERA_IP"
      return
      ;;
    pi-local)
      printf '%s local\n' "$LOCAL_PI_IP"
      return
      ;;
    pi-internet)
      tailscale_ip="$(getent ahostsv4 "$TAILSCALE_PI_HOST" 2>/dev/null | awk '{print $1; exit}')"
      tailscale_ip="${tailscale_ip:-$TAILSCALE_PI_FALLBACK_IP}"
      printf '%s tailscale\n' "$tailscale_ip"
      return
      ;;
    pi-easycap)
      if ping -c 1 -W 1 "$LOCAL_PI_IP" >/dev/null 2>&1; then
        printf '%s easycap\n' "$LOCAL_PI_IP"
        return
      fi
      tailscale_ip="$(getent ahostsv4 "$TAILSCALE_PI_HOST" 2>/dev/null | awk '{print $1; exit}')"
      tailscale_ip="${tailscale_ip:-$TAILSCALE_PI_FALLBACK_IP}"
      printf '%s easycap-tailscale\n' "$tailscale_ip"
      return
      ;;
  esac

  if ping -c 1 -W 1 "$LOCAL_PI_IP" >/dev/null 2>&1; then
    printf '%s local\n' "$LOCAL_PI_IP"
    return
  fi

  tailscale_ip="$(getent ahostsv4 "$TAILSCALE_PI_HOST" 2>/dev/null | awk '{print $1; exit}')"
  tailscale_ip="${tailscale_ip:-$TAILSCALE_PI_FALLBACK_IP}"
  if tailscale_ok "$TAILSCALE_PI_HOST" || tailscale_ok "$tailscale_ip"; then
    printf '%s tailscale\n' "$tailscale_ip"
    return
  fi

  printf '%s waiting\n' "$tailscale_ip"
}

notify_pi_source_mode() {
  target="$1"
  mode="$2"
  case "$mode" in
    camera)
      msg="camera"
      ;;
    local)
      msg="dji ${LOCAL_RADXA_IP} 5600 udp"
      ;;
    tailscale)
      msg="dji ${TAILSCALE_RADXA_IP} 5604 tcp"
      ;;
    easycap)
      msg="easycap ${LOCAL_RADXA_IP} 5600 udp"
      ;;
    easycap-tailscale)
      msg="easycap ${TAILSCALE_RADXA_IP} 5600 udp"
      ;;
    *)
      return
      ;;
  esac

  tailscale_pi_ip="$(getent ahostsv4 "$TAILSCALE_PI_HOST" 2>/dev/null | awk '{print $1; exit}')"
  tailscale_pi_ip="${tailscale_pi_ip:-$TAILSCALE_PI_FALLBACK_IP}"

  # Send to both the current video target and the Pi's management address.
  # This matters when the camera and Pi are both connected: in camera mode the
  # video target is the camera, but the Pi still needs a stop command.
  sent_targets=""
  for notify_target in "$target" "$tailscale_pi_ip" "$TAILSCALE_PI_HOST"; do
    [ -n "$notify_target" ] || continue
    case " $sent_targets " in
      *" $notify_target "*) continue ;;
    esac
    sent_targets="$sent_targets $notify_target"
    MSG="$msg" TARGET="$notify_target" PORT="$PI_SOURCE_MODE_PORT" python3 - <<'PY' >/dev/null 2>&1 || true
import os
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.2)
sock.sendto((os.environ["MSG"] + "\n").encode("ascii", "ignore"), (os.environ["TARGET"], int(os.environ["PORT"])))
PY
  done
}

ensure_pixelpilot() {
  if [ -e "$SPLASH_ACTIVE_FILE" ]; then
    return
  fi

  # PixelPilot must be owned by systemd. Starting it here with nohup creates
  # duplicate decoders/DVR state and breaks record start/stop signalling.
  if ! systemctl is-active --quiet radxa3e-gs.service; then
    systemctl start radxa3e-gs.service >/dev/null 2>&1 || true
  fi
}

apply_aux_services() {
  mode="$1"
  if [ "$mode" = "tailscale" ]; then
    systemctl start tcp-rtp-to-udp.service >/dev/null 2>&1 || true
  else
    systemctl stop tcp-rtp-to-udp.service >/dev/null 2>&1 || true
  fi
}

apply_mode() {
  target="$1"
  mode="$2"
  old="$(cat "$MODE_FILE" 2>/dev/null || true)"
  new="${mode} ${target}"

  if [ "$old" = "$new" ]; then
    ensure_pixelpilot
    apply_aux_services "$mode"
    notify_pi_source_mode "$target" "$mode"
    return
  fi

  echo "$new" > "$MODE_FILE"
  echo "radxa3e-auto-link: mode=$mode target=$target"

  set_kv "$CONTROL_DEFAULTS" CAMERA_IP "$target"
  set_kv "$OSD_DEFAULTS" RADXA3E_PEER_PING_HOST "$target"
  if [ "$mode" = "camera" ]; then
    set_kv "$OSD_DEFAULTS" RADXA3E_HIDE_OPTICAL_RX "0"
    set_kv "$OSD_DEFAULTS" RADXA3E_PEER_PING_ENABLED "0"
  else
    set_kv "$OSD_DEFAULTS" RADXA3E_HIDE_OPTICAL_RX "1"
    set_kv "$OSD_DEFAULTS" RADXA3E_PEER_PING_ENABLED "1"
  fi

  systemctl restart radxa3e-control-bridge.service >/dev/null 2>&1 || true
  systemctl restart radxa3e-external-osd.service >/dev/null 2>&1 || true
  apply_aux_services "$mode"
  notify_pi_source_mode "$target" "$mode"

  systemctl enable --now radxa3e-signal-loss-watch.service >/dev/null 2>&1 || true

  ensure_pixelpilot
}

mkdir -p /run
pending_target=""
pending_count=0

while true; do
  source_mode="$(sed -n 's/^RADXA3E_SOURCE_MODE=//p' "$SOURCE_MODE_FILE" 2>/dev/null | tail -n 1)"
  source_mode="${source_mode:-camera}"
  set -- $(choose_target)
  target="$1"
  mode="$2"
  old="$(cat "$MODE_FILE" 2>/dev/null || true)"
  old_mode="$(printf '%s\n' "$old" | awk '{print $1}')"
  old_target="$(printf '%s\n' "$old" | awk '{print $2}')"

  if [ "$source_mode" = "auto" ] && [ -n "$old" ] && [ "$old_mode" = "local" ] && [ "$mode" != "local" ]; then
    candidate="${mode} ${target}"
    if [ "$candidate" = "$pending_target" ]; then
      pending_count=$((pending_count + 1))
    else
      pending_target="$candidate"
      pending_count=1
    fi
    if [ "$pending_count" -lt "$SWITCH_CONFIRMATIONS" ]; then
      apply_mode "$old_target" "$old_mode"
      sleep "$CHECK_INTERVAL"
      continue
    fi
  else
    pending_target=""
    pending_count=0
  fi

  apply_mode "$target" "$mode"
  sleep "$CHECK_INTERVAL"
done
