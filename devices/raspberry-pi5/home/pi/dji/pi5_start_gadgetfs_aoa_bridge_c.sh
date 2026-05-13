#!/usr/bin/env bash
set -euo pipefail

DEST_IP="${DEST_IP:-100.97.231.5}"
DEST_PORT="${DEST_PORT:-5600}"
UDP_MTU="${UDP_MTU:-1200}"
BRIDGE_MODE="${BRIDGE_MODE:-framed}"
RTP_FPS="${RTP_FPS:-60}"
SOURCE_SIGNAL_PORT="${SOURCE_SIGNAL_PORT:-5512}"
LOG=/home/pi/dji/gadgetfs_aoa_bridge_c.log

sudo modprobe gadgetfs
sudo mkdir -p /dev/gadget
if ! mountpoint -q /dev/gadget; then
  sudo mount -t gadgetfs gadgetfs /dev/gadget
fi

ps -eo pid=,comm=,args= |
  awk '$2=="python3" && $4=="/home/pi/dji/pi5_dji_gadgetfs_watchdog.py" {print $1}' |
  xargs -r sudo kill 2>/dev/null || true
ps -eo pid=,comm=,args= |
  awk '$2=="python3" && $4=="/home/pi/dji/pi5_gadgetfs_aoa_probe.py" {print $1}' |
  xargs -r sudo kill 2>/dev/null || true
ps -eo pid=,args= |
  awk 'index($0, "pi5_gadgetfs_aoa_bridge_c --dest-ip") {print $1}' |
  xargs -r sudo kill 2>/dev/null || true
sleep 0.3
ps -eo pid=,args= |
  awk 'index($0, "pi5_gadgetfs_aoa_bridge_c --dest-ip") {print $1}' |
  xargs -r sudo kill -9 2>/dev/null || true

if [ ! -x /home/pi/dji/pi5_gadgetfs_aoa_bridge_c ]; then
  gcc -O3 -Wall -Wextra -pthread /home/pi/dji/pi5_gadgetfs_aoa_bridge.c -o /home/pi/dji/pi5_gadgetfs_aoa_bridge_c
fi

: > "$LOG"
cd /home/pi/dji
if [ "$BRIDGE_MODE" = "rtp" ]; then
  MODE_ARGS="--rtp --rtp-fps $RTP_FPS --source-signal-port $SOURCE_SIGNAL_PORT"
else
  MODE_ARGS="--udp-framed"
fi
sudo nohup ./pi5_gadgetfs_aoa_bridge_c \
  --dest-ip "$DEST_IP" --dest-port "$DEST_PORT" --udp-mtu "$UDP_MTU" $MODE_ARGS >"$LOG" 2>&1 &
echo "[gadgetfs-c] pid=$! dest=$DEST_IP:$DEST_PORT mtu=$UDP_MTU log=$LOG"
