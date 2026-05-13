#!/usr/bin/env bash
set -euo pipefail

LOG=/home/pi/dji/gadgetfs_aoa_probe.log
DEST_IP="${DEST_IP:-100.97.231.5}"
DEST_PORT="${DEST_PORT:-5600}"
UDP_MTU="${UDP_MTU:-1200}"

sudo modprobe gadgetfs
sudo mkdir -p /dev/gadget
if ! mountpoint -q /dev/gadget; then
  sudo mount -t gadgetfs gadgetfs /dev/gadget
fi

ps -eo pid=,comm=,args= |
  awk '$2=="python3" && $4=="/home/pi/dji/pi5_gadgetfs_aoa_probe.py" {print $1}' |
  xargs -r sudo kill 2>/dev/null || true
: > "$LOG"

cd /home/pi/dji
sudo nohup python3 ./pi5_gadgetfs_aoa_probe.py \
  --dest-ip "$DEST_IP" --dest-port "$DEST_PORT" --udp-mtu "$UDP_MTU" >"$LOG" 2>&1 &
echo "[gadgetfs-aoa] pid=$! dest=$DEST_IP:$DEST_PORT mtu=$UDP_MTU log=$LOG"
