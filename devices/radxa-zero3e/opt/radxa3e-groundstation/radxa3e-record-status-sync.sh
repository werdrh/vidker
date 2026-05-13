#!/usr/bin/env bash
set -euo pipefail

: "${RECORD_DIR:=/media/recordings}"
: "${PIXELPILOT_STATUS_FILE:=/run/radxa3e-record-status}"

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

main() {
  local source message

  source="$(findmnt -n -o SOURCE -T "${RECORD_DIR}" 2>/dev/null || true)"
  if is_external_record_device "${source}" && is_record_target_writable "${RECORD_DIR}"; then
    message=""
  else
    message="NO USB"
  fi

  printf '%s' "${message}" > "${PIXELPILOT_STATUS_FILE}" 2>/dev/null || true
}

main "$@"
