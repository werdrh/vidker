#!/bin/sh
set -eu

LOCAL_RADXA_IP="${LOCAL_RADXA_IP:-192.168.121.51}"
TAILSCALE_RADXA_HOST="${TAILSCALE_RADXA_HOST:-radxa-ground}"
TAILSCALE_RADXA_FALLBACK_IP="${TAILSCALE_RADXA_FALLBACK_IP:-100.80.47.96}"
DEST_PORT="${DEST_PORT:-5600}"
TAILSCALE_DEST_PORT="${TAILSCALE_DEST_PORT:-5604}"
UDP_MTU="${UDP_MTU:-1200}"
SEND_PACING_US="${SEND_PACING_US:-0}"
RTP_FPS="${RTP_FPS:-60}"
SOURCE_SIGNAL_PORT="${SOURCE_SIGNAL_PORT:-5512}"
BRIDGE_BIN="${BRIDGE_BIN:-/home/pi/dji/pi5_gadgetfs_aoa_bridge_c}"
MODE_FILE="${MODE_FILE:-/run/pi-dji-bridge-mode}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
SWITCH_CONFIRMATIONS="${SWITCH_CONFIRMATIONS:-3}"

tailscale_ok() {
  target="$1"
  if command -v tailscale >/dev/null 2>&1; then
    tailscale ping --timeout=3s --c 1 "$target" >/dev/null 2>&1 && return 0
  fi
  ping -c 1 -W 1 "$target" >/dev/null 2>&1
}

choose_dest() {
  if ping -I eth0 -c 1 -W 1 "$LOCAL_RADXA_IP" >/dev/null 2>&1; then
    printf '%s local\n' "$LOCAL_RADXA_IP"
    return
  fi

  tailscale_ip="$(getent ahostsv4 "$TAILSCALE_RADXA_HOST" 2>/dev/null | awk '{print $1; exit}')"
  tailscale_ip="${tailscale_ip:-$TAILSCALE_RADXA_FALLBACK_IP}"
  if tailscale_ok "$TAILSCALE_RADXA_HOST" || tailscale_ok "$tailscale_ip"; then
    printf '%s tailscale\n' "$tailscale_ip"
    return
  fi

  # Keep trying Tailscale; it is the route most likely to appear later.
  printf '%s waiting\n' "$tailscale_ip"
}

mkdir -p /run

while true; do
  set -- $(choose_dest)
  dest_ip="$1"
  mode="$2"
  dest_port="$DEST_PORT"
  if [ "$mode" != "local" ]; then
    dest_port="$TAILSCALE_DEST_PORT"
    transport_arg="--tcp"
  else
    transport_arg=""
  fi
  pacing_us="$SEND_PACING_US"
  printf '%s %s %s %s\n' "$mode" "$dest_ip" "$dest_port" "${transport_arg:-udp}" > "$MODE_FILE"
  echo "pi-dji-auto-bridge: starting mode=$mode dest=$dest_ip:$dest_port transport=${transport_arg:---udp} pacing_us=$pacing_us"

  "$BRIDGE_BIN" \
    --dest-ip "$dest_ip" \
    --dest-port "$dest_port" \
    --udp-mtu "$UDP_MTU" \
    --send-pacing-us "$pacing_us" \
    $transport_arg \
    --rtp \
    --rtp-fps "$RTP_FPS" \
    --source-signal-port "$SOURCE_SIGNAL_PORT" &
  child="$!"
  switch_candidate=""
  switch_count=0

  while kill -0 "$child" 2>/dev/null; do
    sleep "$CHECK_INTERVAL"
    set -- $(choose_dest)
    next_ip="$1"
    next_mode="$2"
    next_port="$DEST_PORT"
    if [ "$next_mode" != "local" ]; then
      next_port="$TAILSCALE_DEST_PORT"
      next_transport_arg="--tcp"
    else
      next_transport_arg=""
    fi
    if [ "$next_ip" != "$dest_ip" ] || [ "$next_mode" != "$mode" ] || [ "$next_port" != "$dest_port" ] || [ "${next_transport_arg:-udp}" != "${transport_arg:-udp}" ]; then
      # Avoid short control/video drops from a single missed LAN ping. Switching
      # back to local is immediate, but leaving local requires repeated proof.
      if [ "$mode" = "local" ] && [ "$next_mode" != "local" ]; then
        candidate="${next_mode} ${next_ip}"
        if [ "$candidate" = "$switch_candidate" ]; then
          switch_count=$((switch_count + 1))
        else
          switch_candidate="$candidate"
          switch_count=1
        fi
        if [ "$switch_count" -lt "$SWITCH_CONFIRMATIONS" ]; then
          printf '%s %s %s %s\n' "$mode" "$dest_ip" "$dest_port" "${transport_arg:-udp}" > "$MODE_FILE"
          continue
        fi
      fi
      echo "pi-dji-auto-bridge: switching $mode/$dest_ip:$dest_port/${transport_arg:-udp} -> $next_mode/$next_ip:$next_port/${next_transport_arg:-udp}"
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      break
    else
      switch_candidate=""
      switch_count=0
      if [ "$next_mode" != "$mode" ]; then
        mode="$next_mode"
      fi
      printf '%s %s %s %s\n' "$mode" "$dest_ip" "$dest_port" "${transport_arg:-udp}" > "$MODE_FILE"
    fi
  done

  wait "$child" 2>/dev/null || true
  sleep 1
done
