#!/usr/bin/env bash
set -euo pipefail

: "${IFACE:=eth0}"
: "${CONNECTION:=DJI-Radxa-Direct}"
: "${PEER_IP:=192.168.121.51}"
: "${LOCAL_IPS:=192.168.121.60/24 192.168.121.50/24}"
: "${CHECK_INTERVAL:=1}"
: "${REACTIVATE_INTERVAL:=10}"

last_reactivate=0

log() {
  echo "[direct-lan-keepalive] $*"
}

carrier_up() {
  [[ "$(cat "/sys/class/net/${IFACE}/carrier" 2>/dev/null || echo 0)" == "1" ]]
}

has_local_ip() {
  local ip
  for ip in ${LOCAL_IPS}; do
    ip -4 addr show dev "${IFACE}" | grep -q "${ip%/*}/" || return 1
  done
}

reactivate_if_needed() {
  local now
  now="$(date +%s)"
  (( now - last_reactivate >= REACTIVATE_INTERVAL )) || return 0
  last_reactivate="${now}"

  log "reactivating ${CONNECTION} on ${IFACE}"
  nmcli con up "${CONNECTION}" ifname "${IFACE}" >/dev/null 2>&1 || true
}

while true; do
  if carrier_up; then
    has_local_ip || reactivate_if_needed
    # A tiny ICMP probe prevents idle direct links from going quiet and also
    # gives NetworkManager/ARP something real to refresh.
    ping -I "${IFACE}" -c 1 -W 1 "${PEER_IP}" >/dev/null 2>&1 || true
  else
    # No carrier means physical link is down; repeatedly bouncing the NM
    # profile cannot fix that and can make recovery noisier. Keep the interface
    # administratively up and wait for the peer/cable to return.
    ip link set dev "${IFACE}" up >/dev/null 2>&1 || true
  fi
  sleep "${CHECK_INTERVAL}"
done
