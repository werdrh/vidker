#!/usr/bin/env bash
set -euo pipefail

DEST_IP="${DEST_IP:-100.97.231.5}"
DEST_PORT="${DEST_PORT:-5600}"
UDP_MTU="${UDP_MTU:-1200}"
REPEAT_PARAMS="${REPEAT_PARAMS:-keyframe}"
TRANSPORT="${TRANSPORT:-udp}"
UDP_FRAMED="${UDP_FRAMED:-0}"
LOG=/home/pi/dji/dji_gadgetfs_watchdog.log

ps -eo pid=,comm=,args= |
  awk '$2=="python3" && $4=="/home/pi/dji/pi5_dji_gadgetfs_watchdog.py" {print $1}' |
  xargs -r sudo kill 2>/dev/null || true
ps -eo pid=,comm=,args= |
  awk '$2=="python3" && $4=="/home/pi/dji/pi5_gadgetfs_aoa_probe.py" {print $1}' |
  xargs -r sudo kill 2>/dev/null || true

FRAMED_ARG=""
if [ "$UDP_FRAMED" = "1" ] || [ "$UDP_FRAMED" = "true" ]; then
  FRAMED_ARG="--udp-framed"
fi

sudo nohup python3 /home/pi/dji/pi5_dji_gadgetfs_watchdog.py \
  --dest-ip "$DEST_IP" --dest-port "$DEST_PORT" --udp-mtu "$UDP_MTU" \
  --repeat-params "$REPEAT_PARAMS" --transport "$TRANSPORT" $FRAMED_ARG >"$LOG" 2>&1 &
echo "[dji-watchdog] started pid=$! dest=$DEST_IP:$DEST_PORT transport=$TRANSPORT framed=$UDP_FRAMED mtu=$UDP_MTU repeat=$REPEAT_PARAMS log=$LOG"
