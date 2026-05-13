#!/usr/bin/env bash
set -euo pipefail

: "${POWER_BUTTON_LINE:=PIN_18}"
: "${POWER_BUTTON_BIAS:=pull-up}"
: "${POWER_BUTTON_ACTIVE_LEVEL:=0}"
: "${POWER_BUTTON_HOLD_SEC:=3}"
: "${POWER_BUTTON_POLL_SEC:=0.1}"
: "${POWER_BUTTON_LOCKOUT_SEC:=5}"
: "${POWER_MESSAGE_FILE:=/run/radxa3e-record-status}"
: "${PIXELPILOT_MSG_FILE:=/run/pixelpilot.msg}"
: "${POWER_WARN_MESSAGE:=Безпечне вимкнення...}"
: "${POWER_ACTION:=halt}"
: "${POWER_DISPLAY_SEC:=0.35}"
: "${POWER_STOP_SERVICES:=radxa3e-signal-loss-watch.service radxa3e-guard.service radxa3e-record-button.service radxa3e-osd-status.service radxa3e-gs.service radxa3e-control-bridge.service}"
: "${SPLASH_IMAGE:=/opt/radxa3e-groundstation/no-signal.jpg}"
: "${FB_DEVICE:=/dev/fb0}"
: "${FB_WIDTH:=1920}"
: "${FB_HEIGHT:=1080}"
: "${FFMPEG_BIN:=/usr/bin/ffmpeg}"

find_gpio_line() {
  local line_ref chip offset
  line_ref="$(gpiofind "${POWER_BUTTON_LINE}")"
  if [[ -z "${line_ref}" ]]; then
    echo "GPIO line ${POWER_BUTTON_LINE} not found" >&2
    exit 1
  fi

  read -r chip offset <<< "${line_ref}"
  if [[ -z "${chip:-}" || -z "${offset:-}" ]]; then
    echo "Failed to parse gpiofind output: ${line_ref}" >&2
    exit 1
  fi

  printf '%s %s\n' "${chip}" "${offset}"
}

read_button_level() {
  local chip="$1"
  local offset="$2"
  gpioget -B "${POWER_BUTTON_BIAS}" "${chip}" "${offset}" 2>/dev/null || echo 1
}

write_status() {
  local message="${1:-}"
  printf '%s' "${message}" > "${POWER_MESSAGE_FILE}" 2>/dev/null || true
  if [[ -p "${PIXELPILOT_MSG_FILE}" ]]; then
    timeout 0.2s bash -lc "printf '%s\n' \"\$1\" > \"\$2\"" _ "${message}" "${PIXELPILOT_MSG_FILE}" >/dev/null 2>&1 || true
  fi
}

show_power_splash() {
  local message="${1:-${POWER_WARN_MESSAGE}}"
  local percent="${2:-0}"
  local detail="${3:-}"
  local vf
  local bar_x=460
  local bar_y=620
  local bar_w=1000
  local bar_h=42
  local fill_w

  [[ -x "${FFMPEG_BIN}" && -r "${SPLASH_IMAGE}" && -w "${FB_DEVICE}" ]] || return 0
  if (( percent < 0 )); then percent=0; fi
  if (( percent > 100 )); then percent=100; fi
  fill_w=$((bar_w * percent / 100))

  vf="scale=${FB_WIDTH}:${FB_HEIGHT}:force_original_aspect_ratio=decrease"
  vf+=",pad=${FB_WIDTH}:${FB_HEIGHT}:(ow-iw)/2:(oh-ih)/2:black"
  vf+=",drawbox=x=0:y=430:w=iw:h=330:color=black@0.78:t=fill"
  vf+=",drawtext=text='${message}':x=(w-text_w)/2:y=470:fontsize=76:fontcolor=white:box=1:boxcolor=red@0.85:boxborderw=24"
  if [[ -n "${detail}" ]]; then
    vf+=",drawtext=text='${detail}':x=(w-text_w)/2:y=570:fontsize=42:fontcolor=white"
  fi
  vf+=",drawbox=x=${bar_x}:y=${bar_y}:w=${bar_w}:h=${bar_h}:color=white@0.85:t=4"
  vf+=",drawbox=x=$((bar_x + 6)):y=$((bar_y + 6)):w=${fill_w}:h=$((bar_h - 12)):color=red@0.95:t=fill"
  vf+=",drawtext=text='${percent}%':x=(w-text_w)/2:y=$((bar_y + 62)):fontsize=42:fontcolor=white"
  vf+=",format=bgra"

  "${FFMPEG_BIN}" -v error -y \
    -i "${SPLASH_IMAGE}" \
    -vf "${vf}" \
    -frames:v 1 \
    -f rawvideo "${FB_DEVICE}" >/dev/null 2>&1 || true
}

show_power_progress() {
  local percent="$1"
  local detail="$2"

  show_power_splash "${POWER_WARN_MESSAGE}" "${percent}" "${detail}"
  sleep "${POWER_DISPLAY_SEC}"
}

stop_services_fast() {
  local service

  for service in ${POWER_STOP_SERVICES}; do
    systemctl kill --signal=TERM "${service}" >/dev/null 2>&1 || true
    timeout 2s systemctl stop "${service}" >/dev/null 2>&1 || systemctl kill --signal=KILL "${service}" >/dev/null 2>&1 || true
  done
}

shutdown_now() {
  echo "Power button held for ${POWER_BUTTON_HOLD_SEC}s, action=${POWER_ACTION}." >&2
  write_status "${POWER_WARN_MESSAGE}"
  show_power_progress 10 "Підготовка..."
  show_power_progress 30 "Зупинка відео..."
  stop_services_fast
  show_power_progress 75 "Синхронізація..."
  sync || true
  show_power_progress 100 "Можна вимикати живлення"
  case "${POWER_ACTION}" in
    halt)
      systemctl halt --force
      ;;
    poweroff)
      systemctl poweroff --force
      ;;
    *)
      echo "Unsupported POWER_ACTION=${POWER_ACTION}" >&2
      exit 1
      ;;
  esac
}

main() {
  local chip offset level held_ticks=0 required_ticks last_poweroff=0 now
  read -r chip offset <<< "$(find_gpio_line)"

  required_ticks="$(awk -v hold="${POWER_BUTTON_HOLD_SEC}" -v poll="${POWER_BUTTON_POLL_SEC}" 'BEGIN { ticks = int((hold / poll) + 0.999); if (ticks < 1) ticks = 1; print ticks }')"

  while true; do
    level="$(read_button_level "${chip}" "${offset}")"

    if [[ "${level}" == "${POWER_BUTTON_ACTIVE_LEVEL}" ]]; then
      held_ticks=$((held_ticks + 1))
    else
      held_ticks=0
    fi

    if (( held_ticks >= required_ticks )); then
      now="$(date +%s)"
      if (( now - last_poweroff >= POWER_BUTTON_LOCKOUT_SEC )); then
        last_poweroff="${now}"
        shutdown_now
      fi
      held_ticks=0
    fi

    sleep "${POWER_BUTTON_POLL_SEC}"
  done
}

main "$@"
