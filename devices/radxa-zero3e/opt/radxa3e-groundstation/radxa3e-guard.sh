#!/usr/bin/env bash
set -euo pipefail

: "${CHECK_INTERVAL:=2}"
: "${TTY_DEVICE:=/dev/tty1}"
: "${CAMERA_IP:=192.168.121.50}"
: "${RESTART_COOLDOWN:=8}"
: "${SPLASH_ACTIVE_FILE:=/run/radxa3e-splash-active}"
: "${RECORD_MOUNT_HELPER:=/opt/radxa3e-groundstation/radxa3e-record-mount.sh}"

: "${GS_SERVICE:=radxa3e-gs.service}"
: "${BRIDGE_SERVICE:=radxa3e-control-bridge.service}"
: "${AUTO_LINK_SERVICE:=radxa3e-auto-link.service}"
: "${RECORD_BUTTON_SERVICE:=radxa3e-record-button.service}"
: "${MODE_BUTTON_SERVICE:=radxa3e-mode-button.service}"
: "${POWER_BUTTON_SERVICE:=radxa3e-power-button.service}"
: "${EXTERNAL_OSD_SERVICE:=radxa3e-external-osd.service}"
: "${SIGNAL_LOSS_SERVICE:=radxa3e-signal-loss-watch.service}"
: "${DIRECT_LAN_KEEPALIVE_SERVICE:=radxa-direct-lan-keepalive.service}"
: "${TCP_RTP_TO_UDP_SERVICE:=tcp-rtp-to-udp.service}"

REQUIRED_SERVICES=(
  "${GS_SERVICE}"
  "${BRIDGE_SERVICE}"
  "${AUTO_LINK_SERVICE}"
  "${RECORD_BUTTON_SERVICE}"
  "${MODE_BUTTON_SERVICE}"
  "${POWER_BUTTON_SERVICE}"
  "${EXTERNAL_OSD_SERVICE}"
  "${SIGNAL_LOSS_SERVICE}"
  "${DIRECT_LAN_KEEPALIVE_SERVICE}"
  "${TCP_RTP_TO_UDP_SERVICE}"
)

REQUIRED_FILES=(
  /opt/radxa3e-groundstation/radxa3e-gs.sh
  /opt/radxa3e-groundstation/radxa3e-control-bridge-c
  /opt/radxa3e-groundstation/radxa3e-control-bridge.c
  /opt/radxa3e-groundstation/radxa3e-record-button.sh
  /opt/radxa3e-groundstation/radxa3e-osd-status.sh
  /opt/radxa3e-groundstation/radxa3e-signal-loss-watch.sh
  /opt/radxa3e-groundstation/radxa3e-record-status-sync.sh
  /opt/radxa3e-groundstation/pixelpilot-osd-minimal.json
)

declare -A LAST_RESTART=()

log_msg() {
  logger -t radxa3e-guard "$*"
}

print_tty() {
  local msg="$1"
  if [[ -w "${TTY_DEVICE}" ]]; then
    printf '\r\n[guard] %s\r\n' "${msg}" > "${TTY_DEVICE}" 2>/dev/null || true
  fi
}

restart_service() {
  local service="$1"
  local reason="$2"
  local now last

  now="$(date +%s)"
  last="${LAST_RESTART[${service}]:-0}"
  if (( now - last < RESTART_COOLDOWN )); then
    return 0
  fi

  LAST_RESTART["${service}"]="${now}"
  log_msg "restarting ${service}: ${reason}"
  print_tty "${service}: ${reason}"
  systemctl restart "${service}" || log_msg "failed to restart ${service}"
}

service_should_be_guarded() {
  local service="$1"
  local enabled

  enabled="$(systemctl is-enabled "${service}" 2>/dev/null || true)"
  [[ "${enabled}" == "enabled" || "${enabled}" == "static" ]]
}

check_required_files() {
  local missing=0
  local path

  for path in "${REQUIRED_FILES[@]}"; do
    if [[ ! -s "${path}" ]]; then
      log_msg "missing or empty required file: ${path}"
      missing=1
    fi
  done

  return "${missing}"
}

check_service_active() {
  local service="$1"
  local state

  if ! service_should_be_guarded "${service}"; then
    return 0
  fi

  # When signal-loss-watch intentionally shows the no-signal splash, it stops
  # PixelPilot so the framebuffer image is not overwritten. Do not fight it.
  if [[ "${service}" == "${GS_SERVICE}" && -e "${SPLASH_ACTIVE_FILE}" ]]; then
    return 0
  fi

  state="$(systemctl is-active "${service}" 2>/dev/null || true)"
  if [[ "${state}" != "active" ]]; then
    restart_service "${service}" "not active (${state:-unknown})"
  fi
}

check_processes_inside_services() {
  if [[ -e "${SPLASH_ACTIVE_FILE}" ]]; then
    return 0
  fi

  if systemctl is-active --quiet "${GS_SERVICE}" &&
     ! pgrep -x pixelpilot >/dev/null 2>&1 &&
     ! pgrep -x gst-launch-1.0 >/dev/null 2>&1; then
    restart_service "${GS_SERVICE}" "viewer process missing"
  fi

  if systemctl is-active --quiet "${BRIDGE_SERVICE}" && ! pgrep -f 'radxa3e-control-bridge.py' >/dev/null 2>&1; then
    if ! pgrep -f 'radxa3e-control-bridge-c' >/dev/null 2>&1; then
      restart_service "${BRIDGE_SERVICE}" "control bridge process missing"
    fi
  fi

  if systemctl is-active --quiet "${RECORD_BUTTON_SERVICE}" && ! pgrep -f 'gpiomon.*gpiochip3 18' >/dev/null 2>&1; then
    restart_service "${RECORD_BUTTON_SERVICE}" "record button gpiomon missing"
  fi

  if systemctl is-active --quiet "${MODE_BUTTON_SERVICE}" && ! pgrep -f 'radxa3e-mode-button.sh' >/dev/null 2>&1; then
    restart_service "${MODE_BUTTON_SERVICE}" "mode button watcher missing"
  fi

  if systemctl is-active --quiet "${POWER_BUTTON_SERVICE}" && ! pgrep -f 'radxa3e-power-button.sh' >/dev/null 2>&1; then
    restart_service "${POWER_BUTTON_SERVICE}" "power button watcher missing"
  fi
}

check_record_mount() {
  if [[ -x "${RECORD_MOUNT_HELPER}" ]]; then
    "${RECORD_MOUNT_HELPER}" >/dev/null 2>&1 || true
  fi
}

check_camera_reachable() {
  if ! ping -c 1 -W 1 "${CAMERA_IP}" >/dev/null 2>&1; then
    log_msg "camera ${CAMERA_IP} is not reachable"
  fi
}

log_msg "guard started"

while true; do
  if check_required_files; then
    for service in "${REQUIRED_SERVICES[@]}"; do
      check_service_active "${service}"
    done
    check_processes_inside_services
  else
    print_tty "required groundstation files missing; not restarting services"
  fi

  check_camera_reachable
  check_record_mount
  sleep "${CHECK_INTERVAL}"
done
