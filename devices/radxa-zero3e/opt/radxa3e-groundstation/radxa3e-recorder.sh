#!/usr/bin/env bash
set -euo pipefail

: "${UDP_PORT:=5602}"
: "${RECORD_STATE_FILE:=/run/radxa3e-record.state}"
: "${GS_ENV:=/etc/default/radxa3e-gs}"
: "${RECORD_DIR:=/media/recordings}"
: "${RECORD_BASENAME:=fpv}"
: "${RECORD_MOUNT_HELPER:=/opt/radxa3e-groundstation/radxa3e-record-mount.sh}"
: "${RECORDER_PID_FILE:=/run/radxa3e-recorder.pid}"
: "${RECORDER_CURRENT_FILE:=/run/radxa3e-recorder.current}"
: "${PIXELPILOT_STATUS_FILE:=/run/radxa3e-record-status}"
: "${RECORDER_NICE:=10}"
: "${RECORDER_IONICE_CLASS:=2}"
: "${RECORDER_IONICE_PRIO:=7}"
: "${RECORDER_BUFFER_SIZE:=4194304}"
: "${RECORDER_FRAGMENT_MS:=1000}"
: "${RECORDER_LOOP_SLEEP:=0.2}"

GST_PID=""
CURRENT_FILE=""

write_status_message() {
  local message="${1:-}"
  printf '%s' "${message}" > "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true
}

read_record_flag() {
  local current=""

  if [[ -f "${RECORD_STATE_FILE}" ]]; then
    current="$(sed -n 's/^RECORD=//p' "${RECORD_STATE_FILE}" | tail -n 1)"
  elif [[ -f "${GS_ENV}" ]]; then
    current="$(sed -n 's/^RECORD=//p' "${GS_ENV}" | tail -n 1)"
  fi

  [[ "${current}" == "1" ]] && echo 1 || echo 0
}

block_parent_device() {
  local source="$1"
  local parent

  parent="$(lsblk -ndo PKNAME "${source}" 2>/dev/null || true)"
  if [[ -n "${parent}" ]]; then
    printf '/dev/%s\n' "${parent}"
  else
    printf '%s\n' "${source}"
  fi
}

is_external_record_device() {
  local source="$1"
  local blockdev

  [[ -n "${source}" && -b "${source}" ]] || return 1
  blockdev="$(block_parent_device "${source}")"
  [[ -n "${blockdev}" && -b "${blockdev}" ]] || return 1

  case "$(basename "${blockdev}")" in
    mmcblk1|mmcblk1boot*|mmcblk1rpmb|zram*|loop*)
      return 1
      ;;
  esac

  return 0
}

record_target_ready() {
  local source

  if [[ -x "${RECORD_MOUNT_HELPER}" ]]; then
    "${RECORD_MOUNT_HELPER}" || true
  fi

  mkdir -p "${RECORD_DIR}" 2>/dev/null || true
  source="$(findmnt -n -o SOURCE -T "${RECORD_DIR}" 2>/dev/null || true)"
  is_external_record_device "${source}" || return 1
  [[ -w "${RECORD_DIR}" ]] || return 1
}

recorder_running() {
  [[ -n "${GST_PID}" ]] || return 1
  kill -0 "${GST_PID}" 2>/dev/null
}

start_recorder() {
  local timestamp
  local -a cmd

  if recorder_running; then
    return
  fi

  if ! record_target_ready; then
    write_status_message "NO USB"
    return
  fi

  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  CURRENT_FILE="${RECORD_DIR}/${RECORD_BASENAME}_${timestamp}.fmp4"
  printf '%s\n' "${CURRENT_FILE}" > "${RECORDER_CURRENT_FILE}"

  cmd=(gst-launch-1.0 -q -e
    udpsrc port="${UDP_PORT}" close-socket=false buffer-size="${RECORDER_BUFFER_SIZE}"
      caps=application/x-rtp,media=video,encoding-name=H264,payload=96,clock-rate=90000
    ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=1000000000 leaky=downstream
    ! rtph264depay
    ! h264parse config-interval=-1
    ! mp4mux fragment-duration="${RECORDER_FRAGMENT_MS}" streamable=true
    ! filesink location="${CURRENT_FILE}" sync=false async=false)

  if command -v ionice >/dev/null 2>&1; then
    cmd=(ionice -c "${RECORDER_IONICE_CLASS}" -n "${RECORDER_IONICE_PRIO}" "${cmd[@]}")
  fi
  if command -v nice >/dev/null 2>&1; then
    cmd=(nice -n "${RECORDER_NICE}" "${cmd[@]}")
  fi

  "${cmd[@]}" &
  GST_PID="$!"
  printf '%s\n' "${GST_PID}" > "${RECORDER_PID_FILE}"
}

stop_recorder() {
  if ! recorder_running; then
    rm -f "${RECORDER_PID_FILE}" >/dev/null 2>&1 || true
    return
  fi

  kill -INT "${GST_PID}" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! kill -0 "${GST_PID}" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if kill -0 "${GST_PID}" 2>/dev/null; then
    kill -TERM "${GST_PID}" 2>/dev/null || true
  fi
  wait "${GST_PID}" 2>/dev/null || true
  rm -f "${RECORDER_PID_FILE}" >/dev/null 2>&1 || true
  GST_PID=""
}

cleanup() {
  stop_recorder
}

trap cleanup EXIT INT TERM

while true; do
  if [[ "$(read_record_flag)" == "1" ]]; then
    start_recorder
  else
    stop_recorder
  fi
  sleep "${RECORDER_LOOP_SLEEP}"
done
