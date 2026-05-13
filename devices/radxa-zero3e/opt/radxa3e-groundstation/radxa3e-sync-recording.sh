#!/usr/bin/env bash
set -euo pipefail
install -m 0755 /tmp/radxa3e-gs.sh /opt/radxa3e-groundstation/radxa3e-gs.sh
install -m 0755 /tmp/radxa3e-record-button.sh /opt/radxa3e-groundstation/radxa3e-record-button.sh
install -m 0644 /tmp/pixelpilot-osd-minimal.json /opt/radxa3e-groundstation/pixelpilot-osd-minimal.json
source="$(findmnt -n -o SOURCE -T /media/recordings 2>/dev/null || true)"
if [[ -n "$source" ]]; then
  parent="$(lsblk -ndo PKNAME "$source" 2>/dev/null || true)"
  blockdev="$source"
  if [[ -n "$parent" ]]; then
    blockdev="/dev/$parent"
  fi
  if [[ ! -b "$blockdev" ]]; then
    umount /media/recordings || true
  fi
fi
candidate="$(lsblk -bpnro NAME,TYPE,RM,SIZE,FSTYPE,MOUNTPOINT,PKNAME | awk '$2=="part" && $5!="" && $7!="mmcblk1" {print $1"|"$6"|"$4}' | sort -t'|' -k3,3nr | head -n1)"
if [[ -n "$candidate" ]]; then
  device="$(printf '%s' "$candidate" | cut -d'|' -f1)"
  mountpoint="$(printf '%s' "$candidate" | cut -d'|' -f2)"
  mkdir -p /media/recordings
  if [[ -z "$mountpoint" ]]; then
    mount "$device" /media/recordings || true
  elif [[ "$mountpoint" != "/media/recordings" ]]; then
    mount --bind "$mountpoint" /media/recordings || true
  fi
fi
systemctl restart radxa3e-record-button.service
systemctl restart radxa3e-gs.service
systemctl is-active radxa3e-record-button.service radxa3e-gs.service
findmnt /media/recordings || true
lsblk -o NAME,PKNAME,RM,TRAN,SIZE,FSTYPE,MOUNTPOINT | sed -n '1,20p'