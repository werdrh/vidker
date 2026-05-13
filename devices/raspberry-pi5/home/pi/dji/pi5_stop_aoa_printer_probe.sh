#!/usr/bin/env bash
set -euo pipefail

G=/sys/kernel/config/usb_gadget/dji_aoa_prn

set +e
pkill -f 'dd if=/dev/g_printer' 2>/dev/null
if [[ -d "$G" ]]; then
  echo "" | sudo tee "$G/UDC" >/dev/null
  sudo rm -f "$G/configs/c.1/printer.usb0"
  sudo rmdir "$G/functions/printer.usb0"
  sudo rmdir "$G/configs/c.1/strings/0x409"
  sudo rmdir "$G/configs/c.1"
  sudo rmdir "$G/strings/0x409"
  sudo rmdir "$G"
fi
echo "[aoa-printer] stopped"
