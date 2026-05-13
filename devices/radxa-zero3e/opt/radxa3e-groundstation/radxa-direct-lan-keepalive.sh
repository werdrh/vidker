#!/usr/bin/env bash
set -euo pipefail

: "${IFACE:=end1}"
: "${PEER_IP:=192.168.121.60}"
: "${LOCAL_IP:=192.168.121.51/24}"
: "${ENABLE_PEER_INTERNET:=1}"
: "${PEER_GATEWAY:=192.168.121.60}"
: "${CHECK_INTERVAL:=1}"

log() {
  echo "[direct-lan-keepalive] $*"
}

carrier_up() {
  [[ "$(cat "/sys/class/net/${IFACE}/carrier" 2>/dev/null || echo 0)" == "1" ]]
}

has_local_ip() {
  ip -4 addr show dev "${IFACE}" | grep -q "${LOCAL_IP%/*}/"
}

ensure_local_ip() {
  has_local_ip || ip addr add "${LOCAL_IP}" dev "${IFACE}" >/dev/null 2>&1 || true
}

ensure_peer_internet() {
  [[ "${ENABLE_PEER_INTERNET}" == "1" ]] || return 0
  if ping -I "${IFACE}" -c 1 -W 1 "${PEER_IP}" >/dev/null 2>&1; then
    # Direct Pi cable mode: Pi may be sharing internet over the same LAN.
    # Use a low-metric default via Pi only while the Pi is actually reachable.
    ip route replace default via "${PEER_GATEWAY}" dev "${IFACE}" metric 50 >/dev/null 2>&1 || true
  else
    # Router/internet-cable mode: never leave a stale default route via the Pi,
    # because it breaks DHCP-provided internet and Tailscale.
    ip route del default via "${PEER_GATEWAY}" dev "${IFACE}" >/dev/null 2>&1 || true
  fi
}

while true; do
  ip link set dev "${IFACE}" up >/dev/null 2>&1 || true
  if carrier_up; then
    ensure_local_ip
    ensure_peer_internet
    ping -I "${IFACE}" -c 1 -W 1 "${PEER_IP}" >/dev/null 2>&1 || true
  fi
  sleep "${CHECK_INTERVAL}"
done
