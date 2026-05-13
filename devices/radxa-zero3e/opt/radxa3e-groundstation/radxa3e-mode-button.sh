#!/usr/bin/env bash
set -euo pipefail

: "${BUTTON_LINE:=PIN_36}"
: "${BUTTON_BIAS:=pull-up}"
: "${BUTTON_ACTIVE_LEVEL:=0}"
: "${BUTTON_CONFIRM_MS:=1200}"
: "${BUTTON_POLL_MS:=100}"
: "${BUTTON_RELEASE_MS:=500}"
: "${BUTTON_LOCKOUT_MS:=5000}"
: "${SOURCE_MODE_FILE:=/etc/default/radxa3e-source-mode}"
: "${STATUS_FILE:=/run/radxa3e-source-status}"
: "${SPLASH_ACTIVE_FILE:=/run/radxa3e-splash-active}"
: "${SPLASH_SCRIPT:=/opt/radxa3e-groundstation/radxa3e-splash.sh}"
: "${AUTO_LINK_SERVICE:=radxa3e-auto-link.service}"
: "${MODE_SEQUENCE:=camera pi-local pi-internet pi-easycap}"

mode_label() {
  case "$1" in
    camera) echo "Оптика" ;;
    pi-local) echo "PI Lan" ;;
    pi-internet) echo "Internet" ;;
    pi-easycap) echo "PI CAP" ;;
    *) echo "MODE $1" ;;
  esac
}

read_mode() {
  local mode
  mode="$(sed -n 's/^RADXA3E_SOURCE_MODE=//p' "${SOURCE_MODE_FILE}" 2>/dev/null | tail -n 1)"
  [[ -n "${mode}" ]] || mode="camera"
  echo "${mode}"
}

write_mode() {
  local mode="$1"
  mkdir -p "$(dirname "${SOURCE_MODE_FILE}")"
  if [[ -f "${SOURCE_MODE_FILE}" ]] && grep -q '^RADXA3E_SOURCE_MODE=' "${SOURCE_MODE_FILE}"; then
    sed -i "s/^RADXA3E_SOURCE_MODE=.*/RADXA3E_SOURCE_MODE=${mode}/" "${SOURCE_MODE_FILE}"
  else
    printf 'RADXA3E_SOURCE_MODE=%s\n' "${mode}" >> "${SOURCE_MODE_FILE}"
  fi
  printf '%s' "$(mode_label "${mode}")" > "${STATUS_FILE}" 2>/dev/null || true
  if [[ -e "${SPLASH_ACTIVE_FILE}" && -x "${SPLASH_SCRIPT}" ]]; then
    "${SPLASH_SCRIPT}" show >/dev/null 2>&1 || true
  fi
  systemctl restart "${AUTO_LINK_SERVICE}" >/dev/null 2>&1 || true
}

next_mode() {
  local current="$1"
  local first="" previous="" mode
  for mode in ${MODE_SEQUENCE}; do
    [[ -n "${first}" ]] || first="${mode}"
    if [[ "${previous}" == "${current}" ]]; then
      echo "${mode}"
      return
    fi
    previous="${mode}"
  done
  echo "${first:-camera}"
}

toggle_once() {
  local current next
  current="$(read_mode)"
  next="$(next_mode "${current}")"
  write_mode "${next}"
  echo "mode switched: ${current} -> ${next}"
}

find_gpio_line() {
  local line_ref chip offset
  line_ref="$(gpiofind "${BUTTON_LINE}")"
  if [[ -z "${line_ref}" ]]; then
    echo "GPIO line ${BUTTON_LINE} not found" >&2
    exit 1
  fi
  read -r chip offset <<< "${line_ref}"
  printf '%s %s\n' "${chip}" "${offset}"
}

read_level() {
  local chip="$1" offset="$2"
  gpioget -B "${BUTTON_BIAS}" "${chip}" "${offset}" 2>/dev/null || echo 1
}

sleep_ms() {
  awk -v ms="$1" 'BEGIN { printf "%.3f\n", ms / 1000 }' | xargs sleep
}

ticks_for_ms() {
  local ms="$1"
  echo $(( (ms + BUTTON_POLL_MS - 1) / BUTTON_POLL_MS ))
}

if [[ "${1:-}" == "--toggle-once" ]]; then
  toggle_once
  exit 0
fi

if [[ "${1:-}" == "--set" ]]; then
  [[ -n "${2:-}" ]] || { echo "missing mode" >&2; exit 2; }
  write_mode "$2"
  exit 0
fi

read -r chip offset <<< "$(find_gpio_line)"
confirm_ticks="$(ticks_for_ms "${BUTTON_CONFIRM_MS}")"
release_ticks="$(ticks_for_ms "${BUTTON_RELEASE_MS}")"
active_ticks=0
inactive_ticks=0
# Start disarmed. A noisy/held-low line must first become inactive for
# BUTTON_RELEASE_MS before it can change the source mode.
armed=0
last_ms="$(date +%s%3N)"

while true; do
  level="$(read_level "${chip}" "${offset}")"
  now_ms="$(date +%s%3N)"

  if [[ "${level}" == "${BUTTON_ACTIVE_LEVEL}" ]]; then
    active_ticks=$((active_ticks + 1))
    inactive_ticks=0
  else
    inactive_ticks=$((inactive_ticks + 1))
    active_ticks=0
    if (( inactive_ticks >= release_ticks )); then
      armed=1
    fi
  fi

  if (( armed == 1 && active_ticks >= confirm_ticks && now_ms - last_ms >= BUTTON_LOCKOUT_MS )); then
    toggle_once
    last_ms="${now_ms}"
    armed=0
    active_ticks=0
  fi

  sleep_ms "${BUTTON_POLL_MS}"
done
