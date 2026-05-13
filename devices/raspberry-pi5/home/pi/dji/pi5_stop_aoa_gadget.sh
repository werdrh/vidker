#!/usr/bin/env bash
set -euo pipefail

G=/sys/kernel/config/usb_gadget/dji_aoa
FFS=/dev/ffs-aoa

set +e
if [[ -d "$G" ]]; then
  echo "" | sudo tee "$G/UDC" >/dev/null
fi
pkill -f 'pi5_aoa_ffs.py' 2>/dev/null
if [[ -e "$G/configs/c.1/ffs.aoa" ]]; then
  sudo rm -f "$G/configs/c.1/ffs.aoa"
fi
if [[ -d "$G/functions/ffs.aoa" ]]; then
  sudo rmdir "$G/functions/ffs.aoa"
fi
if [[ -d "$G/configs/c.1/strings/0x409" ]]; then
  sudo rmdir "$G/configs/c.1/strings/0x409"
fi
if [[ -d "$G/configs/c.1" ]]; then
  sudo rmdir "$G/configs/c.1"
fi
if [[ -d "$G/strings/0x409" ]]; then
  sudo rmdir "$G/strings/0x409"
fi
if [[ -d "$G" ]]; then
  sudo rmdir "$G"
fi
if mountpoint -q "$FFS"; then
  sudo umount "$FFS"
fi
echo "[aoa] stopped"
