#!/usr/bin/env bash
set -euo pipefail

: "${LAN_IFACE:=eth0}"
: "${WAN_IFACE:=wlan0}"

if command -v sysctl >/dev/null 2>&1; then
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
else
  echo 1 > /proc/sys/net/ipv4/ip_forward
fi

if command -v nft >/dev/null 2>&1; then
  nft list table ip pi_lan_share >/dev/null 2>&1 || nft add table ip pi_lan_share
  nft list chain ip pi_lan_share postrouting >/dev/null 2>&1 || \
    nft add chain ip pi_lan_share postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
  nft list chain ip pi_lan_share forward >/dev/null 2>&1 || \
    nft add chain ip pi_lan_share forward '{ type filter hook forward priority filter; policy accept; }'
  nft list chain ip pi_lan_share postrouting | grep -q "oifname \"${WAN_IFACE}\" masquerade" || \
    nft add rule ip pi_lan_share postrouting oifname "${WAN_IFACE}" masquerade
  nft list chain ip pi_lan_share forward | grep -q "iifname \"${LAN_IFACE}\" oifname \"${WAN_IFACE}\" accept" || \
    nft add rule ip pi_lan_share forward iifname "${LAN_IFACE}" oifname "${WAN_IFACE}" accept
  nft list chain ip pi_lan_share forward | grep -q "iifname \"${WAN_IFACE}\" oifname \"${LAN_IFACE}\" ct state related,established accept" || \
    nft add rule ip pi_lan_share forward iifname "${WAN_IFACE}" oifname "${LAN_IFACE}" ct state related,established accept
else
  iptables -t nat -C POSTROUTING -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "${WAN_IFACE}" -j MASQUERADE
  iptables -C FORWARD -i "${LAN_IFACE}" -o "${WAN_IFACE}" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "${LAN_IFACE}" -o "${WAN_IFACE}" -j ACCEPT
  iptables -C FORWARD -i "${WAN_IFACE}" -o "${LAN_IFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "${WAN_IFACE}" -o "${LAN_IFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
