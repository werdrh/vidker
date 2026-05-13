#!/usr/bin/env bash
set -euo pipefail

: "${RECORD_DIR:=/media/recordings}"
: "${RECORD_MOUNT_OPTS:=rw,noatime,nosuid,nodev,nofail,x-systemd.device-timeout=2s}"

is_external_device() {
  local dev="$1" pkname base
  [[ -n "${dev}" ]] || return 1
  base="$(basename "${dev}")"
  case "${base}" in
    mmcblk*|zram*|loop*) return 1 ;;
  esac
  pkname="$(lsblk -no PKNAME "${dev}" 2>/dev/null | head -n 1 || true)"
  case "${pkname}" in
    mmcblk*|zram*|loop*) return 1 ;;
  esac
  return 0
}

target_writable() {
  local dir="$1"
  local probe="${dir}/.radxa3e-write-test"
  [[ -d "${dir}" ]] || return 1
  touch "${probe}" 2>/dev/null || return 1
  rm -f "${probe}" 2>/dev/null || true
}

find_candidate() {
  local line name type size fstype mountpoint pkname best_name="" best_mount="" best_size=0
  while IFS= read -r line; do
    eval "${line}"
    [[ "${type}" == "part" ]] || continue
    [[ -n "${fstype}" ]] || continue
    is_external_device "${name}" || continue
    case "${fstype}" in
      exfat|vfat|fat|fat32|ntfs|ext2|ext3|ext4) ;;
      *) continue ;;
    esac
    if (( size > best_size )); then
      best_name="${name}"
      best_mount="${mountpoint}"
      best_size="${size}"
    fi
  done < <(lsblk -P -bpn -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,PKNAME | sed 's/NAME=/name=/; s/TYPE=/type=/; s/SIZE=/size=/; s/FSTYPE=/fstype=/; s/MOUNTPOINT=/mountpoint=/; s/PKNAME=/pkname=/')

  [[ -n "${best_name}" ]] || return 1
  printf '%s|%s\n' "${best_name}" "${best_mount}"
}

mkdir -p "${RECORD_DIR}"

current="$(findmnt -n -o SOURCE -T "${RECORD_DIR}" 2>/dev/null || true)"
if is_external_device "${current}" && target_writable "${RECORD_DIR}"; then
  exit 0
fi

if [[ -n "${current}" ]]; then
  umount -l "${RECORD_DIR}" >/dev/null 2>&1 || true
fi

candidate="$(find_candidate || true)"
[[ -n "${candidate}" ]] || exit 1
IFS='|' read -r device mountpoint <<< "${candidate}"

if [[ -n "${mountpoint}" && "${mountpoint}" != "${RECORD_DIR}" ]]; then
  umount -l "${mountpoint}" >/dev/null 2>&1 || true
fi

for _ in 1 2 3; do
  if mount -o "${RECORD_MOUNT_OPTS}" "${device}" "${RECORD_DIR}" >/dev/null 2>&1; then
    target_writable "${RECORD_DIR}" && exit 0
  fi
  sleep 1
done

exit 1
