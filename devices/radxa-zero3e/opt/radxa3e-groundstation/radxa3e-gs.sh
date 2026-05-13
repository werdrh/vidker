#!/usr/bin/env bash
set -euo pipefail

: "${UDP_PORT:=5600}"
: "${INPUT_MODE:=rtp-h264}"
: "${RECORD:=1}"
: "${RECORD_DIR:=/media/recordings}"
: "${RECORD_BASENAME:=fpv}"
: "${DISPLAY_SINK:=kmssink sync=false}"
: "${UDP_BUFFER_SIZE:=262144}"
: "${DISPLAY_QUEUE_BUFFERS:=1}"
: "${RECORD_QUEUE_BUFFERS:=4}"
: "${CPU_GOVERNOR:=performance}"

: "${USE_PIXELPILOT:=auto}"
: "${PIXELPILOT_CODEC:=auto}"
: "${PIXELPILOT_SCREEN_MODE:=1920x1080@60}"
: "${PIXELPILOT_OSD:=1}"
: "${PIXELPILOT_OSD_ELEMENTS:=0}"
: "${PIXELPILOT_OSD_REFRESH:=100}"
: "${PIXELPILOT_OSD_CONFIG:=}"
: "${PIXELPILOT_CUSTOM_MESSAGE:=0}"
: "${PIXELPILOT_WFB_API_PORT:=0}"
: "${PIXELPILOT_DISABLE_GREGIDR:=0}"
: "${PIXELPILOT_DISABLE_VSYNC:=0}"
: "${PIXELPILOT_DVR:=0}"
: "${PIXELPILOT_DVR_FRAMERATE:=auto}"
: "${SOURCE_MODE_FILE:=/etc/default/radxa3e-source-mode}"
: "${RECORD_MOUNT_HELPER:=/opt/radxa3e-groundstation/radxa3e-record-mount.sh}"

ACTUAL_RECORD_DIR=""
PIXELPILOT_STATUS_FILE="/run/radxa3e-record-status"

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

update_record_status() {
  if [[ -z "${ACTUAL_RECORD_DIR}" ]]; then
    write_status_message "NO USB"
    return
  fi

  write_status_message ""
}

set_governor() {
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    if [[ -w "${gov_file}" ]]; then
      echo "${CPU_GOVERNOR}" > "${gov_file}" 2>/dev/null || true
    fi
  done
}

pick_codec() {
  if [[ "${PIXELPILOT_CODEC}" != "auto" ]]; then
    echo "${PIXELPILOT_CODEC}"
    return
  fi

  case "${INPUT_MODE}" in
    *h265) echo "h265" ;;
    *h264) echo "h264" ;;
    *) echo "h265" ;;
  esac
}

pick_decoder() {
  local codec="$1"

  if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    if gst-inspect-1.0 mppvideodec >/dev/null 2>&1; then
      echo "mppvideodec"
      return
    fi
  fi

  if [[ "${codec}" == "h265" ]]; then
    echo "avdec_h265 max-threads=4"
  else
    echo "avdec_h264 max-threads=4"
  fi
}

current_source_mode() {
  local mode
  mode="$(sed -n 's/^RADXA3E_SOURCE_MODE=//p' "${SOURCE_MODE_FILE}" 2>/dev/null | tail -n 1)"
  printf '%s\n' "${mode:-camera}"
}

pick_dvr_framerate() {
  if [[ "${PIXELPILOT_DVR_FRAMERATE}" != "auto" ]]; then
    echo "${PIXELPILOT_DVR_FRAMERATE}"
    return
  fi

  case "$(current_source_mode)" in
    pi-easycap) echo "25" ;;
    *) echo "60" ;;
  esac
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

prepare_record_target() {
  local candidate device mountpoint source target

  ACTUAL_RECORD_DIR="${RECORD_DIR}"

  if [[ -x "${RECORD_MOUNT_HELPER}" ]]; then
    "${RECORD_MOUNT_HELPER}" || true
  fi

  if command -v findmnt >/dev/null 2>&1; then
    source="$(findmnt -n -o SOURCE -T "${RECORD_DIR}" 2>/dev/null || true)"
    target="$(findmnt -n -o TARGET -T "${RECORD_DIR}" 2>/dev/null || true)"
    if is_external_record_device "${source}"; then
      ACTUAL_RECORD_DIR="${target:-${RECORD_DIR}}"
      mkdir -p "${ACTUAL_RECORD_DIR}"
      update_record_status
      return
    elif [[ -n "${source}" ]]; then
      umount "${RECORD_DIR}" >/dev/null 2>&1 || true
    fi
  fi

  candidate="$(find_external_partition)"
  if [[ -z "${candidate}" ]]; then
    echo "Recording disabled: external flash drive not found." >&2
    ACTUAL_RECORD_DIR=""
    RECORD=0
    update_record_status
    return
  fi

  IFS='|' read -r device mountpoint <<< "${candidate}"

  if [[ -z "${mountpoint}" ]]; then
    mkdir -p "${RECORD_DIR}"
    if mount "${device}" "${RECORD_DIR}" >/dev/null 2>&1; then
      ACTUAL_RECORD_DIR="${RECORD_DIR}"
      update_record_status
      return
    fi

    write_status_message "USB ERR"
    echo "Recording disabled: failed to mount ${device} on ${RECORD_DIR}." >&2
    RECORD=0
    return
  fi

  if [[ "${mountpoint}" == "${RECORD_DIR}" ]]; then
    ACTUAL_RECORD_DIR="${mountpoint}"
  else
    ACTUAL_RECORD_DIR="${mountpoint}/recordings"
  fi
  mkdir -p "${ACTUAL_RECORD_DIR}"
  update_record_status
}

run_pixelpilot() {
  local codec dvr_template dvr_framerate
  local -a cmd

  codec="$(pick_codec)"

  cmd=(pixelpilot -p "${UDP_PORT}" --codec "${codec}" --screen-mode "${PIXELPILOT_SCREEN_MODE}")

  if [[ -n "${PIXELPILOT_WFB_API_PORT}" ]]; then
    cmd+=(--wfb-api-port "${PIXELPILOT_WFB_API_PORT}")
  fi

  if [[ "${PIXELPILOT_OSD}" == "1" ]]; then
    cmd+=(--osd --osd-elements "${PIXELPILOT_OSD_ELEMENTS}" --osd-refresh "${PIXELPILOT_OSD_REFRESH}")
  fi

  if [[ "${PIXELPILOT_CUSTOM_MESSAGE}" == "1" ]]; then
    cmd+=(--osd-custom-message)
  fi

  if [[ -n "${PIXELPILOT_OSD_CONFIG}" ]]; then
    cmd+=(--osd-config "${PIXELPILOT_OSD_CONFIG}")
  fi

  if [[ "${PIXELPILOT_DISABLE_GREGIDR}" == "1" ]]; then
    cmd+=(--disable-gregidr)
  fi

  if [[ "${PIXELPILOT_DISABLE_VSYNC}" == "1" ]]; then
    cmd+=(--disable-vsync)
  fi

  if [[ "${PIXELPILOT_DVR}" == "1" && -n "${ACTUAL_RECORD_DIR}" ]]; then
    dvr_template="${ACTUAL_RECORD_DIR}/${RECORD_BASENAME}_%Y-%m-%d_%H-%M-%S.fmp4"
    dvr_framerate="$(pick_dvr_framerate)"
    cmd+=(--dvr-framerate "${dvr_framerate}" --dvr-fmp4 --dvr-sequenced-files --dvr-template "${dvr_template}")

    if [[ "${RECORD}" == "1" ]]; then
      cmd+=(--dvr-start)
    fi
  fi

  exec "${cmd[@]}"
}

run_gst_pipeline() {
  local codec parser parser_elem depay caps decoder display_branch record_branch

  case "${INPUT_MODE}" in
    rtp-h264)
      codec="h264"
      parser="h264parse config-interval=-1"
      parser_elem="h264parse"
      depay="rtph264depay"
      caps='application/x-rtp,media=video,encoding-name=H264,payload=96'
      ;;
    raw-h264)
      codec="h264"
      parser="h264parse config-interval=-1"
      parser_elem="h264parse"
      depay=""
      caps=""
      ;;
    rtp-h265)
      codec="h265"
      parser="h265parse config-interval=-1"
      parser_elem="h265parse"
      depay="rtph265depay"
      caps='application/x-rtp,media=video,encoding-name=H265,payload=96'
      ;;
    raw-h265)
      codec="h265"
      parser="h265parse config-interval=-1"
      parser_elem="h265parse"
      depay=""
      caps=""
      ;;
    *)
      echo "Unsupported INPUT_MODE=${INPUT_MODE}" >&2
      exit 2
      ;;
  esac

  decoder="$(pick_decoder "${codec}")"

  display_branch="t. ! queue max-size-buffers=${DISPLAY_QUEUE_BUFFERS} max-size-bytes=0 max-size-time=0 leaky=downstream ! ${parser} ! ${decoder} ! ${DISPLAY_SINK}"

  if [[ "${RECORD}" == "1" ]]; then
    local timestamp record_file
    timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
    record_file="${ACTUAL_RECORD_DIR}/${RECORD_BASENAME}_${timestamp}.mkv"
    record_branch="t. ! queue max-size-buffers=${RECORD_QUEUE_BUFFERS} max-size-bytes=0 max-size-time=0 leaky=downstream ! ${parser_elem} ! matroskamux ! filesink location=${record_file} sync=false async=false"
  else
    record_branch=""
  fi

  if [[ -n "${depay}" ]]; then
    exec gst-launch-1.0 -e \
      udpsrc port="${UDP_PORT}" close-socket=false buffer-size="${UDP_BUFFER_SIZE}" caps="${caps}" ! \
      ${depay} ! tee name=t \
      ${display_branch} \
      ${record_branch}
  else
    exec gst-launch-1.0 -e \
      udpsrc port="${UDP_PORT}" close-socket=false buffer-size="${UDP_BUFFER_SIZE}" ! \
      tee name=t \
      ${display_branch} \
      ${record_branch}
  fi
}

main() {
  set_governor
  prepare_record_target

  if [[ "${USE_PIXELPILOT}" == "1" ]] || { [[ "${USE_PIXELPILOT}" == "auto" ]] && command -v pixelpilot >/dev/null 2>&1; }; then
    run_pixelpilot
  fi

  run_gst_pipeline
}

main "$@"
