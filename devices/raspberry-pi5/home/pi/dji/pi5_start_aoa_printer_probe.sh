#!/usr/bin/env bash
set -euo pipefail

G=/sys/kernel/config/usb_gadget/dji_aoa_prn
LOG=/home/pi/dji/aoa_printer_probe.log

sudo modprobe libcomposite
sudo modprobe usb_f_printer

UDC="$(ls /sys/class/udc | head -n1 || true)"
if [[ -z "$UDC" ]]; then
  echo "No UDC found. Need Pi5 USB-C peripheral mode." >&2
  exit 1
fi

sudo mkdir -p "$G"
echo 0x18d1 | sudo tee "$G/idVendor" >/dev/null
echo 0x2d00 | sudo tee "$G/idProduct" >/dev/null
echo 0x0200 | sudo tee "$G/bcdUSB" >/dev/null
echo 0x0100 | sudo tee "$G/bcdDevice" >/dev/null

sudo mkdir -p "$G/strings/0x409"
echo "codex-pi5-aoa-printer-probe" | sudo tee "$G/strings/0x409/serialnumber" >/dev/null
echo "Google" | sudo tee "$G/strings/0x409/manufacturer" >/dev/null
echo "Android Accessory" | sudo tee "$G/strings/0x409/product" >/dev/null

sudo mkdir -p "$G/configs/c.1/strings/0x409"
echo "AOA printer probe" | sudo tee "$G/configs/c.1/strings/0x409/configuration" >/dev/null
echo 250 | sudo tee "$G/configs/c.1/MaxPower" >/dev/null

sudo mkdir -p "$G/functions/printer.usb0"
if [[ ! -e "$G/configs/c.1/printer.usb0" ]]; then
  sudo ln -s "$G/functions/printer.usb0" "$G/configs/c.1/printer.usb0"
fi

pkill -f 'dd if=/dev/g_printer' 2>/dev/null || true
: > "$LOG"
echo "$UDC" | sudo tee "$G/UDC" >/dev/null

# Log any bytes written by the USB host to the bulk OUT endpoint.
PRN_DEV="/dev/g_printer0"
for _ in $(seq 1 20); do
  [[ -e "$PRN_DEV" ]] && break
  sleep 0.1
done
sudo chmod 666 "$PRN_DEV" 2>/dev/null || true
nohup sh -c "stdbuf -o0 dd if=$PRN_DEV bs=512 2>/dev/null | od -Ax -tx1 -v" >> "$LOG" 2>&1 &

echo "[aoa-printer] started UDC=$UDC"
echo "[aoa-printer] log=$LOG"
