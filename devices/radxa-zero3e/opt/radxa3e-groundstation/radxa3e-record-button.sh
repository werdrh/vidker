#!/usr/bin/env bash
set -euo pipefail

: "${BUTTON_LINE:=PIN_32}"
: "${BUTTON_BIAS:=pull-down}"
: "${BUTTON_EDGE:=rising}"
: "${BUTTON_ACTIVE_LOW:=0}"
: "${DEBOUNCE_MS:=300}"
: "${BUTTON_LOCKOUT_MS:=2500}"
: "${GS_ENV:=/etc/default/radxa3e-gs}"
: "${RECORD_STATE_FILE:=/run/radxa3e-record.state}"
: "${GS_SERVICE:=radxa3e-gs.service}"
: "${PIXELPILOT_STATUS_FILE:=/run/radxa3e-record-status}"
: "${RECORD_DIR:=/media/recordings}"
: "${RECORD_MOUNT_HELPER:=/opt/radxa3e-groundstation/radxa3e-record-mount.sh}"
: "${CLEAR_MESSAGE:=}"
: "${REMUX_ENABLED:=1}"
: "${REMUX_TOOL:=/usr/bin/ffmpeg}"
: "${REMUX_TIMEOUT_SEC:=3600}"
: "${REMUX_FASTSTART:=0}"
: "${REMUX_NICE:=19}"
: "${REMUX_IONICE_CLASS:=3}"
: "${REMUX_MESSAGE:=SAVING...}"
: "${REMUX_SCAN_MESSAGE:=REMUX...}"
: "${REMUX_DONE_MESSAGE:=SAVED}"
: "${REMUX_ERROR_MESSAGE:=MP4 ERR}"
: "${REMUX_NO_SPACE_MESSAGE:=NO SPACE}"
: "${REMUX_RAW_DONE_MESSAGE:=RAW SAVED}"
: "${REMUX_DONE_HOLD_SEC:=3}"
: "${STOP_TAIL_DELAY_SEC:=1}"
: "${REMUX_LOCK_FILE:=/run/radxa3e-record-remux.lock}"
: "${REMUX_JOBS_DIR:=/run/radxa3e-record-remux.jobs}"
: "${REMUX_LOG_DIR:=/run/radxa3e-record-remux.logs}"
: "${REMUX_ACTIVE_PID_FILE:=/run/radxa3e-record-remux.pid}"
: "${MIN_SAVED_RAW_SIZE:=1048576}"
: "${DVR_GROWTH_SAMPLE_SEC:=1}"
: "${EXTERNAL_RECORDER:=0}"
: "${RECORDER_PID_FILE:=/run/radxa3e-recorder.pid}"
: "${RECORDER_CURRENT_FILE:=/run/radxa3e-recorder.current}"
: "${RECORDER_STOP_TIMEOUT_SEC:=8}"
: "${VIDEO_PACKET_CHECK:=1}"
: "${VIDEO_PACKET_PORT:=5600}"
: "${VIDEO_PACKET_TIMEOUT:=0.7}"

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

is_record_target_writable() {
  local target="${1:-$RECORD_DIR}"
  local options=""

  options="$(findmnt -n -o OPTIONS -T "${target}" 2>/dev/null || true)"
  [[ -n "${options}" ]] || return 1
  case ",${options}," in
    *,ro,*)
      return 1
      ;;
  esac

  [[ -w "${target}" ]] || return 1
  return 0
}

write_status_message() {
  local message="${1:-}"
  local last=""

  if [[ -f "${PIXELPILOT_STATUS_FILE}" ]]; then
    last="$(cat "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true)"
  fi

  if [[ "${message}" == "${last}" ]]; then
    return
  fi

  printf '%s' "${message}" > "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true
}

find_external_partition() {
  local best_name="" best_mount="" best_size=0
  local line name type rm size fstype mountpoint pkname

  while IFS= read -r line; do
    eval "${line}"
    [[ "${type}" == "part" ]] || continue
    [[ -n "${fstype}" ]] || continue
    case "$(basename "${pkname}")" in
      mmcblk1|mmcblk1boot*|mmcblk1rpmb|zram*|loop*)
        continue
        ;;
    esac

    if (( size > best_size )); then
      best_name="${name}"
      best_mount="${mountpoint}"
      best_size="${size}"
    fi
  done < <(lsblk -P -bpn -o NAME,TYPE,RM,SIZE,FSTYPE,MOUNTPOINT,PKNAME | sed 's/NAME=/name=/; s/TYPE=/type=/; s/RM=/rm=/; s/SIZE=/size=/; s/FSTYPE=/fstype=/; s/MOUNTPOINT=/mountpoint=/; s/PKNAME=/pkname=/')

  if [[ -n "${best_name}" ]]; then
    printf '%s|%s\n' "${best_name}" "${best_mount}"
  fi
}

build_gpiomon_cmd() {
  local line_ref chip offset
  line_ref="$(gpiofind "${BUTTON_LINE}")"

  if [[ -z "${line_ref}" ]]; then
    echo "GPIO line ${BUTTON_LINE} not found" >&2
    exit 1
  fi

  read -r chip offset <<< "${line_ref}"
  if [[ -z "${chip:-}" || -z "${offset:-}" ]]; then
    echo "Failed to parse gpiofind output: ${line_ref}" >&2
    exit 1
  fi

  local -a cmd=(gpiomon -b -B "${BUTTON_BIAS}")

  if [[ "${BUTTON_ACTIVE_LOW}" == "1" ]]; then
    cmd+=(-l)
  fi

  case "${BUTTON_EDGE}" in
    rising) cmd+=(-r) ;;
    falling) cmd+=(-f) ;;
    both) ;;
    *)
      echo "Unsupported BUTTON_EDGE=${BUTTON_EDGE}" >&2
      exit 1
      ;;
  esac

  cmd+=("${chip}" "${offset}")
  printf '%s\n' "${cmd[@]}"
}

read_record_flag() {
  local current

  if [[ -f "${RECORD_STATE_FILE}" ]]; then
    current="$(sed -n 's/^RECORD=//p' "${RECORD_STATE_FILE}" | tail -n 1)"
  else
    current="$(sed -n 's/^RECORD=//p' "${GS_ENV}" 2>/dev/null | tail -n 1)"
  fi

  if [[ "${current}" == "1" ]]; then
    echo 1
  else
    echo 0
  fi
}

set_record_flag() {
  local next="$1"

  printf 'RECORD=%s\n' "${next}" > "${RECORD_STATE_FILE}"
  if [[ -f "${GS_ENV}" ]]; then
    if grep -q '^RECORD=' "${GS_ENV}" 2>/dev/null; then
      sed -i "s/^RECORD=.*/RECORD=${next}/" "${GS_ENV}" 2>/dev/null || true
    else
      printf 'RECORD=%s\n' "${next}" >> "${GS_ENV}" 2>/dev/null || true
    fi
  fi
}

record_target_ready() {
  local source candidate device mountpoint

  if [[ -x "${RECORD_MOUNT_HELPER}" ]]; then
    "${RECORD_MOUNT_HELPER}" || true
  fi
  ls "${RECORD_DIR}" >/dev/null 2>&1 || true
  source="$(findmnt -n -o SOURCE -T "${RECORD_DIR}" 2>/dev/null || true)"
  if is_external_record_device "${source}" && is_record_target_writable "${RECORD_DIR}"; then
    return 0
  elif [[ -n "${source}" ]]; then
    umount "${RECORD_DIR}" >/dev/null 2>&1 || true
  fi

  candidate="$(find_external_partition)"
  [[ -n "${candidate}" ]] || return 1

  IFS='|' read -r device mountpoint <<< "${candidate}"
  if [[ -z "${mountpoint}" ]]; then
    mkdir -p "${RECORD_DIR}"
    mount "${device}" "${RECORD_DIR}" >/dev/null 2>&1 || return 1
    return 0
  fi

  is_external_record_device "${device}"
}

pixelpilot_pid() {
  local pid
  pid="$(pgrep -n -x pixelpilot 2>/dev/null || true)"
  if [[ -z "${pid}" ]]; then
    pid="$(pidof pixelpilot 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "${pid}" ]] || return 1
  printf '%s\n' "${pid}"
}

toggle_dvr_signal() {
  local pid
  pid="$(pixelpilot_pid)" || return 1
  kill -USR1 "${pid}"
}

pixelpilot_has_dvr_template() {
  local pid
  pid="$(pixelpilot_pid)" || return 1
  tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q -- '--dvr-template'
}

video_stream_active() {
  [[ "${VIDEO_PACKET_CHECK}" == "1" ]] || return 0
  timeout "${VIDEO_PACKET_TIMEOUT}" tcpdump -p -ni any -c 1 "udp dst port ${VIDEO_PACKET_PORT}" >/dev/null 2>&1
}

external_recorder_pid() {
  local pid=""

  if [[ -f "${RECORDER_PID_FILE}" ]]; then
    pid="$(cat "${RECORDER_PID_FILE}" 2>/dev/null || true)"
  fi

  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    printf '%s\n' "${pid}"
    return 0
  fi

  return 1
}

external_recorder_is_recording() {
  external_recorder_pid >/dev/null
}

external_recorder_current_file() {
  if [[ -f "${RECORDER_CURRENT_FILE}" ]]; then
    cat "${RECORDER_CURRENT_FILE}" 2>/dev/null || true
  fi
}

wait_external_recorder_stopped() {
  local start now

  start="$(date +%s)"
  while external_recorder_is_recording; do
    now="$(date +%s)"
    if (( now - start >= RECORDER_STOP_TIMEOUT_SEC )); then
      break
    fi
    sleep 0.2
  done
}

latest_raw_recording() {
  find "${RECORD_DIR}" -maxdepth 1 -type f -name '*.fmp4' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 1 | cut -d' ' -f2-
}

file_size() {
  stat -c '%s' "$1" 2>/dev/null || echo 0
}

dvr_is_actually_recording() {
  local latest size1 size2

  latest="$(latest_raw_recording)"
  [[ -n "${latest}" && -f "${latest}" ]] || return 1

  size1="$(file_size "${latest}")"
  sleep "${DVR_GROWTH_SAMPLE_SEC}"
  size2="$(file_size "${latest}")"

  (( size2 > size1 ))
}

wait_for_file_stable() {
  local file="$1"
  local last_size="-1"
  local same_count=0
  local current_size

  for _ in $(seq 1 20); do
    [[ -f "${file}" ]] || return 1
    current_size="$(stat -c '%s' "${file}" 2>/dev/null || echo -1)"
    if [[ "${current_size}" == "${last_size}" && "${current_size}" != "-1" ]]; then
      same_count=$((same_count + 1))
      if (( same_count >= 2 )); then
        return 0
      fi
    else
      same_count=0
      last_size="${current_size}"
    fi
    sleep 1
  done

  return 1
}

raw_recording_ok() {
  local file="$1"
  local size=0

  [[ -f "${file}" ]] || return 1
  size="$(stat -c '%s' "${file}" 2>/dev/null || echo 0)"
  (( size >= MIN_SAVED_RAW_SIZE ))
}

remux_has_space() {
  local input="$1"
  local input_size avail_bytes reserve_bytes required_bytes

  input_size="$(stat -c '%s' "${input}" 2>/dev/null || echo 0)"
  avail_bytes="$(df -PB1 "${RECORD_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')"
  reserve_bytes=$((128 * 1024 * 1024))
  required_bytes=$((input_size + reserve_bytes))

  [[ -n "${avail_bytes}" ]] || return 1
  (( avail_bytes >= required_bytes ))
}

recording_requested() {
  [[ "$(read_record_flag 2>/dev/null || echo 0)" == "1" ]]
}

wait_for_remux_idle_slot() {
  while recording_requested; do
    sleep 1
  done
}

stop_active_remux() {
  local pid=""

  if [[ -f "${REMUX_ACTIVE_PID_FILE}" ]]; then
    pid="$(cat "${REMUX_ACTIVE_PID_FILE}" 2>/dev/null || true)"
  fi

  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    pkill -TERM -P "${pid}" 2>/dev/null || true
    kill -TERM "${pid}" 2>/dev/null || true
    sleep 0.3
    if kill -0 "${pid}" 2>/dev/null; then
      pkill -KILL -P "${pid}" 2>/dev/null || true
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  fi

  rm -f "${REMUX_ACTIVE_PID_FILE}" >/dev/null 2>&1 || true
}

remux_recording() {
  local input output temp_output log_file log_base remux_pid remux_status
  local -a ffmpeg_cmd remux_cmd timeout_cmd

  [[ -d "${RECORD_DIR}" ]] || return 0
  is_record_target_writable "${RECORD_DIR}" || return 1

  input="${1:-}"
  [[ -n "${input}" && -f "${input}" ]] || return 0
  wait_for_file_stable "${input}" || raw_recording_ok "${input}" || return 1
  raw_recording_ok "${input}" || return 1

  [[ "${REMUX_ENABLED}" == "1" ]] || return 0
  [[ -x "${REMUX_TOOL}" ]] || return 0

  output="${input%.fmp4}.mp4"
  temp_output="${output%.mp4}.tmp.mp4"
  mkdir -p "${REMUX_LOG_DIR}" >/dev/null 2>&1 || true
  log_base="$(basename "${output%.mp4}.remux.log")"
  log_file="${REMUX_LOG_DIR}/${log_base}"

  [[ -f "${output}" ]] && return 0
  rm -f "${temp_output}" >/dev/null 2>&1 || true

  if ! remux_has_space "${input}"; then
    printf 'remux skipped: %s\nreason: no space\ninput: %s\ninput_size: %s\navailable: %s\n' \
      "$(date -Is)" "${input}" "$(stat -c '%s' "${input}" 2>/dev/null || echo 0)" \
      "$(df -PB1 "${RECORD_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')" > "${log_file}" 2>/dev/null || true
    write_status_message "${REMUX_NO_SPACE_MESSAGE}"
    return 2
  fi

  ffmpeg_cmd=("${REMUX_TOOL}" -hide_banner -loglevel info -y -i "${input}" -c copy)
  if [[ "${REMUX_FASTSTART}" == "1" ]]; then
    ffmpeg_cmd+=(-movflags +faststart)
  fi
  ffmpeg_cmd+=("${temp_output}")

  remux_cmd=()
  if command -v ionice >/dev/null 2>&1; then
    remux_cmd+=(ionice -c "${REMUX_IONICE_CLASS}")
  fi
  if command -v nice >/dev/null 2>&1; then
    remux_cmd+=(nice -n "${REMUX_NICE}")
  fi
  remux_cmd+=("${ffmpeg_cmd[@]}")

  printf 'remux start: %s\ninput: %s\noutput: %s\nfaststart: %s\ntimeout: %s\nnice: %s\nionice_class: %s\n' \
    "$(date -Is)" "${input}" "${temp_output}" "${REMUX_FASTSTART}" "${REMUX_TIMEOUT_SEC}" \
    "${REMUX_NICE}" "${REMUX_IONICE_CLASS}" > "${log_file}" 2>/dev/null || true

  if [[ "${REMUX_TIMEOUT_SEC}" == "0" ]]; then
    timeout_cmd=("${remux_cmd[@]}")
  else
    timeout_cmd=(timeout -k 10s "${REMUX_TIMEOUT_SEC}s" "${remux_cmd[@]}")
  fi

  "${timeout_cmd[@]}" >> "${log_file}" 2>&1 &
  remux_pid="$!"
  printf '%s\n' "${remux_pid}" > "${REMUX_ACTIVE_PID_FILE}" 2>/dev/null || true

  remux_status=0
  wait "${remux_pid}" || remux_status="$?"
  rm -f "${REMUX_ACTIVE_PID_FILE}" >/dev/null 2>&1 || true

  if [[ "${remux_status}" == "0" ]]; then
    mv -f "${temp_output}" "${output}"
    printf 'remux done: %s\n' "$(date -Is)" >> "${log_file}" 2>/dev/null || true
    return 0
  fi

  printf 'remux failed: %s status=%s\n' "$(date -Is)" "${remux_status}" >> "${log_file}" 2>/dev/null || true
  rm -f "${temp_output}" >/dev/null 2>&1 || true
  return 1
}

remux_jobs_active() {
  find "${REMUX_JOBS_DIR}" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .
}

finish_remux_job() {
  local job_file="$1"

  rm -f "${job_file}" >/dev/null 2>&1 || true
  if remux_jobs_active; then
    : > "${REMUX_LOCK_FILE}"
  else
    rm -f "${REMUX_LOCK_FILE}" >/dev/null 2>&1 || true
  fi
}

schedule_remux_after_stop() {
  local input="$1"
  local job_file

  # If PixelPilot was armed without valid incoming video, it can create a 0-byte
  # fMP4. Treat that as no saved clip instead of leaving an MP4 ERR indicator.
  if [[ -z "${input}" || ! -f "${input}" ]] || ! raw_recording_ok "${input}"; then
    write_status_message "${CLEAR_MESSAGE}"
    return 0
  fi

  mkdir -p "${REMUX_JOBS_DIR}"
  job_file="${REMUX_JOBS_DIR}/$(date +%s)-$$-${RANDOM}.job"
  printf '%s\n' "${input}" > "${job_file}"
  : > "${REMUX_LOCK_FILE}"
  (
    while true; do
      wait_for_remux_idle_slot
      write_status_message "${REMUX_MESSAGE}"
      if remux_recording "${input}"; then
        write_status_message "${REMUX_DONE_MESSAGE}"
        finish_remux_job "${job_file}"
        sleep "${REMUX_DONE_HOLD_SEC}"
        if ! remux_jobs_active; then
          write_status_message "${CLEAR_MESSAGE}"
        fi
        break
      fi

      if recording_requested; then
        write_status_message "${CLEAR_MESSAGE}"
        sleep 1
        continue
      fi

      if raw_recording_ok "${input}"; then
        if [[ "$(cat "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true)" != "${REMUX_NO_SPACE_MESSAGE}" ]]; then
          write_status_message "${REMUX_RAW_DONE_MESSAGE}"
        fi
        finish_remux_job "${job_file}"
        sleep "${REMUX_DONE_HOLD_SEC}"
        if ! remux_jobs_active; then
          write_status_message "${CLEAR_MESSAGE}"
        fi
      else
        finish_remux_job "${job_file}"
        write_status_message "${REMUX_ERROR_MESSAGE}"
      fi
      break
    done
  ) >/dev/null 2>&1 &
}

remux_job_exists_for() {
  local input="$1"
  local job

  [[ -d "${REMUX_JOBS_DIR}" ]] || return 1
  for job in "${REMUX_JOBS_DIR}"/*.job; do
    [[ -f "${job}" ]] || continue
    raw="$(cat "${job}" 2>/dev/null || true)"
    raw="${raw//$'\r'/}"
    if [[ "${raw}" == "${input}" ]]; then
      return 0
    fi
  done

  return 1
}

scan_unremuxed_recordings() {
  local raw output newest status_message

  # Remux is safe while the no-signal splash is shown. Only block it when the
  # user/system is actively requesting recording; stale DVR state can otherwise
  # prevent recovery remux after signal loss.
  if recording_requested; then
    return 0
  fi

  record_target_ready || return 0
  [[ -d "${RECORD_DIR}" ]] || return 0

  # Drop stale scanner jobs left by older versions when the MP4 already exists.
  if [[ -d "${REMUX_JOBS_DIR}" ]]; then
    for job in "${REMUX_JOBS_DIR}"/*.job; do
      [[ -f "${job}" ]] || continue
      raw="$(cat "${job}" 2>/dev/null || true)"
      raw="${raw//$'\r'/}"
      output="${raw%.fmp4}.mp4"
      if [[ -n "${raw}" && -f "${output}" ]]; then
        rm -f "${job}" >/dev/null 2>&1 || true
      fi
    done
  fi

  newest="$(latest_raw_recording)"

  find "${RECORD_DIR}" -maxdepth 1 -type f -name '*.fmp4' -print 2>/dev/null | sort | while IFS= read -r raw; do
    [[ -n "${raw}" && -f "${raw}" ]] || continue
    output="${raw%.fmp4}.mp4"
    [[ -f "${output}" ]] && continue
    if recording_requested; then
      break
    fi
    if [[ "${raw}" == "${newest}" ]] && ! wait_for_file_stable "${raw}"; then
      continue
    fi
    raw_recording_ok "${raw}" || continue

    write_status_message "${REMUX_SCAN_MESSAGE}"
    if remux_recording "${raw}"; then
      write_status_message "${REMUX_DONE_MESSAGE}"
      sleep "${REMUX_DONE_HOLD_SEC}"
      status_message="$(cat "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true)"
      if [[ "${status_message}" == "${REMUX_DONE_MESSAGE}" ]]; then
        write_status_message "${CLEAR_MESSAGE}"
      fi
    else
      if recording_requested; then
        write_status_message "${CLEAR_MESSAGE}"
        break
      fi
      if raw_recording_ok "${raw}"; then
        status_message="$(cat "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true)"
        if [[ "${status_message}" != "${REMUX_NO_SPACE_MESSAGE}" ]]; then
          write_status_message "${REMUX_RAW_DONE_MESSAGE}"
          sleep "${REMUX_DONE_HOLD_SEC}"
          if [[ "$(cat "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true)" == "${REMUX_RAW_DONE_MESSAGE}" ]]; then
            write_status_message "${CLEAR_MESSAGE}"
          fi
        fi
      else
        write_status_message "${REMUX_ERROR_MESSAGE}"
      fi
    fi

    # One file per timer tick keeps idle maintenance gentle.
    break
  done

  return 0
}
toggle_recording() {
  local actual stopped_file

  if ! record_target_ready; then
    write_status_message "NO USB"
    set_record_flag 0
    echo "Button press ignored: no external recording target." >&2
    return
  fi

  if [[ "${EXTERNAL_RECORDER}" == "1" ]]; then
    if external_recorder_is_recording; then
      actual=1
    else
      actual=0
    fi
    set_record_flag "${actual}"

    if [[ "${actual}" == "1" ]]; then
      echo "Button press: stopping external recorder." >&2
      stopped_file="$(external_recorder_current_file)"
      set_record_flag 0
      write_status_message "${REMUX_MESSAGE}"
      wait_external_recorder_stopped
      [[ -n "${stopped_file}" ]] || stopped_file="$(latest_raw_recording)"
      schedule_remux_after_stop "${stopped_file}"
      return
    fi

    echo "Button press: starting external recorder." >&2
    set_record_flag 1
    stop_active_remux
    write_status_message "${CLEAR_MESSAGE}"
    return
  fi

  if dvr_is_actually_recording || recording_requested; then
    actual=1
  else
    actual=0
  fi
  set_record_flag "${actual}"

  if [[ "${actual}" == "1" ]]; then
    echo "Button press: stopping DVR." >&2
    set_record_flag 0
    write_status_message "${REMUX_MESSAGE}"
    toggle_dvr_signal || true
    if [[ "${STOP_TAIL_DELAY_SEC}" != "0" ]]; then
      sleep "${STOP_TAIL_DELAY_SEC}"
    fi
    stopped_file="$(latest_raw_recording)"
    schedule_remux_after_stop "${stopped_file}"
    return
  fi

  echo "Button press: starting DVR." >&2
  if ! video_stream_active; then
    write_status_message "NO VIDEO"
    set_record_flag 0
    echo "Button press ignored: no live video packets on UDP ${VIDEO_PACKET_PORT}." >&2
    return
  fi
  set_record_flag 1
  stop_active_remux
  write_status_message "${CLEAR_MESSAGE}"
  if ! pixelpilot_has_dvr_template; then
    echo "PixelPilot DVR template missing, restarting ${GS_SERVICE} with --dvr-start." >&2
    systemctl restart "${GS_SERVICE}"
    sleep "${STOP_TAIL_DELAY_SEC}"
  elif ! toggle_dvr_signal; then
    echo "DVR start signal failed, starting ${GS_SERVICE} with --dvr-start." >&2
    systemctl restart "${GS_SERVICE}"
    sleep "${STOP_TAIL_DELAY_SEC}"
  fi
}

stop_recording_for_signal_loss() {
  local actual requested stopped_file

  if [[ -e "${REMUX_LOCK_FILE}" ]]; then
    echo "Signal-loss stop: remux already in progress, keeping current recording state." >&2
  fi

  requested="$(read_record_flag)"
  if [[ "${EXTERNAL_RECORDER}" == "1" ]]; then
    if external_recorder_is_recording; then
      actual=1
    else
      actual="${requested}"
    fi
    set_record_flag "${actual}"

    if [[ "${actual}" != "1" ]]; then
      echo "Signal-loss stop ignored: RECORD is already off." >&2
      return 0
    fi

    if ! record_target_ready; then
      write_status_message "NO USB"
      set_record_flag 0
      echo "Signal-loss stop: no external recording target." >&2
      return 0
    fi

    echo "Signal-loss stop: stopping external recorder." >&2
    stopped_file="$(external_recorder_current_file)"
    set_record_flag 0
    write_status_message "${REMUX_MESSAGE}"
    wait_external_recorder_stopped
    [[ -n "${stopped_file}" ]] || stopped_file="$(latest_raw_recording)"
    schedule_remux_after_stop "${stopped_file}"
    return 0
  fi

  if dvr_is_actually_recording; then
    actual=1
  else
    # When video is lost, the DVR file may stop growing before PixelPilot has
    # received the stop signal. Trust the requested RECORD state in that case.
    actual="${requested}"
  fi
  set_record_flag "${actual}"

  if [[ "${actual}" != "1" ]]; then
    echo "Signal-loss stop ignored: RECORD is already off." >&2
    return 0
  fi

  if ! record_target_ready; then
    write_status_message "NO USB"
    set_record_flag 0
    echo "Signal-loss stop: no external recording target." >&2
    return 0
  fi

  echo "Signal-loss stop: switching RECORD=0" >&2
  set_record_flag 0
  write_status_message "${REMUX_MESSAGE}"

  toggle_dvr_signal || true

  if [[ "${STOP_TAIL_DELAY_SEC}" != "0" ]]; then
    sleep "${STOP_TAIL_DELAY_SEC}"
  fi

  stopped_file="$(latest_raw_recording)"
  schedule_remux_after_stop "${stopped_file}"
}

main() {
  local -a monitor_cmd=()
  local last_ms=0
  local now_ms
  local lockout_ms

  mapfile -t monitor_cmd < <(build_gpiomon_cmd)

  "${monitor_cmd[@]}" | while IFS= read -r _line; do
    now_ms="$(date +%s%3N)"
    lockout_ms="${BUTTON_LOCKOUT_MS}"
    if (( lockout_ms < DEBOUNCE_MS )); then
      lockout_ms="${DEBOUNCE_MS}"
    fi
    if (( now_ms - last_ms < lockout_ms )); then
      continue
    fi

    last_ms="${now_ms}"
    toggle_recording
  done
}

if [[ "${1:-}" == "--stop-for-signal-loss" ]]; then
  stop_recording_for_signal_loss
  exit 0
fi

if [[ "${1:-}" == "--toggle-once" ]]; then
  toggle_recording
  exit 0
fi

if [[ "${1:-}" == "--scan-remux" ]]; then
  scan_unremuxed_recordings
  exit 0
fi

main "$@"
