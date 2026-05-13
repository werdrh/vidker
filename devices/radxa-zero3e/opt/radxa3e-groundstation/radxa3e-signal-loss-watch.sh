#!/usr/bin/env bash
set -euo pipefail

: "${AUTO_LINK_SERVICE:=radxa3e-auto-link.service}"
: "${RECORD_BUTTON_SCRIPT:=/opt/radxa3e-groundstation/radxa3e-record-button.sh}"
: "${SPLASH_SCRIPT:=/opt/radxa3e-groundstation/radxa3e-splash.sh}"
: "${STREAM_IFACE:=any}"
: "${STREAM_PORT:=5600}"
: "${LOSS_TIMEOUT_SEC:=20}"
: "${RECORD_LOSS_TIMEOUT_SEC:=${LOSS_TIMEOUT_SEC}}"
: "${SPLASH_LOSS_TIMEOUT_SEC:=20}"
: "${KILL_ACTIVE_VIEWER_ON_LOSS:=0}"
: "${POLL_SEC:=1}"
: "${TCPDUMP_BIN:=/usr/bin/tcpdump}"
: "${SPLASH_ACTIVE_FILE:=/run/radxa3e-splash-active}"
: "${RECORD_STOPPED_FILE:=/run/radxa3e-record-stopped-for-signal-loss}"

last_seen=0
stream_seen=0
splash_visible=0

now_s() { date +%s; }

log() {
  echo "[signal-watch] $*"
}

has_stream_packet() {
  # Only real RTP/video packets count. Interface bitrate is intentionally not
  # used here, because Tailscale/internet keepalive traffic can otherwise keep
  # the no-signal splash hidden while no video exists.
  timeout 0.5s "${TCPDUMP_BIN}" -p -ni "${STREAM_IFACE}" -c 1 "udp dst port ${STREAM_PORT}" >/dev/null 2>&1
}

pixelpilot_active() {
  pgrep -x pixelpilot >/dev/null 2>&1
}

stop_pixelpilot() {
  pkill -x pixelpilot >/dev/null 2>&1 || true
}

stop_recording_for_loss() {
  if [[ ! -e "${RECORD_STOPPED_FILE}" ]]; then
    "${RECORD_BUTTON_SCRIPT}" --stop-for-signal-loss || true
    touch "${RECORD_STOPPED_FILE}"
  fi
}

show_no_signal() {
  if [[ "${splash_visible}" == "1" && -e "${SPLASH_ACTIVE_FILE}" ]]; then
    if [[ "${KILL_ACTIVE_VIEWER_ON_LOSS}" == "1" ]]; then
      stop_pixelpilot
    fi
    return 0
  fi
  log "showing no-signal splash"
  touch "${SPLASH_ACTIVE_FILE}"
  if [[ "${KILL_ACTIVE_VIEWER_ON_LOSS}" == "1" || "${stream_seen}" == "0" ]]; then
    stop_pixelpilot
  fi
  "${SPLASH_SCRIPT}" show || true
  splash_visible=1
}

restore_viewer() {
  if [[ -e "${SPLASH_ACTIVE_FILE}" ]]; then
    log "video stream detected; restoring PixelPilot"
    rm -f "${SPLASH_ACTIVE_FILE}"
    rm -f "${RECORD_STOPPED_FILE}"
  fi
  splash_visible=0
  systemctl start "${AUTO_LINK_SERVICE}" >/dev/null 2>&1 || true
}

cleanup() {
  rm -f "${RECORD_STOPPED_FILE}"
}

trap cleanup EXIT INT TERM

last_seen="$(now_s)"
# At boot, show a deterministic no-signal screen until real stream packets arrive.
show_no_signal

while true; do
  if has_stream_packet; then
    stream_seen=1
    last_seen="$(now_s)"
    restore_viewer
  else
    current="$(now_s)"
    if ((current - last_seen >= RECORD_LOSS_TIMEOUT_SEC)); then
      if pixelpilot_active && [[ "${KILL_ACTIVE_VIEWER_ON_LOSS}" != "1" ]]; then
        :
      else
        stop_recording_for_loss
      fi
    fi
    if ((current - last_seen >= SPLASH_LOSS_TIMEOUT_SEC)); then
      if pixelpilot_active && [[ "${KILL_ACTIVE_VIEWER_ON_LOSS}" != "1" ]]; then
        # Flight-safe default: after video has once started, do not kill an
        # active PixelPilot just because packet detection missed a window. The
        # decoder is more likely to recover by itself if we leave it running.
        log "video packets missing, but PixelPilot is active; keeping viewer alive"
      else
        show_no_signal
      fi
    fi
  fi
  sleep "${POLL_SEC}"
done
