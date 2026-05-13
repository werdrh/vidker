#!/usr/bin/env bash
set -euo pipefail

G=/sys/kernel/config/usb_gadget/dji_aoa
FFS=/dev/ffs-aoa
LOG=/home/pi/dji/aoa_ffs.log

sudo modprobe libcomposite
sudo modprobe usb_f_fs || true

UDC="$(ls /sys/class/udc | head -n1 || true)"
if [[ -z "$UDC" ]]; then
  echo "No UDC found. Pi5 must be in USB-C peripheral mode: dtoverlay=dwc2,dr_mode=peripheral" >&2
  exit 1
fi

sudo mkdir -p "$FFS"
if ! mountpoint -q "$FFS"; then
  sudo mount -t functionfs aoa "$FFS"
fi
sudo chown -R "$USER:$USER" "$FFS"

sudo mkdir -p "$G"
echo 0x18d1 | sudo tee "$G/idVendor" >/dev/null
echo 0x2d00 | sudo tee "$G/idProduct" >/dev/null
echo 0x0200 | sudo tee "$G/bcdUSB" >/dev/null
echo 0x0100 | sudo tee "$G/bcdDevice" >/dev/null

sudo mkdir -p "$G/strings/0x409"
echo "codex-pi5-aoa-probe" | sudo tee "$G/strings/0x409/serialnumber" >/dev/null
echo "Google" | sudo tee "$G/strings/0x409/manufacturer" >/dev/null
echo "Android Accessory" | sudo tee "$G/strings/0x409/product" >/dev/null

sudo mkdir -p "$G/configs/c.1/strings/0x409"
echo "AOA probe config" | sudo tee "$G/configs/c.1/strings/0x409/configuration" >/dev/null
echo 250 | sudo tee "$G/configs/c.1/MaxPower" >/dev/null

sudo mkdir -p "$G/functions/ffs.aoa"
if [[ ! -e "$G/configs/c.1/ffs.aoa" ]]; then
  sudo ln -s "$G/functions/ffs.aoa" "$G/configs/c.1/ffs.aoa"
fi

pkill -f 'pi5_aoa_ffs.py' 2>/dev/null || true
cd /home/pi/dji
nohup python3 ./pi5_aoa_ffs.py --mount "$FFS" >"$LOG" 2>&1 &
DAEMON_PID=$!
echo "$DAEMON_PID" > /tmp/pi5_aoa_ffs.pid
sleep 1

echo "$UDC" | sudo tee "$G/UDC" >/dev/null

echo "[aoa] started UDC=$UDC daemon_pid=$DAEMON_PID"
echo "[aoa] log: $LOG"
echo "[aoa] connect Goggles to the Pi5 USB-C data/power port, with Pi powered separately if needed."
