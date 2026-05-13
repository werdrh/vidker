#!/usr/bin/env bash
set -euo pipefail

# Restore the Goggles 3 RNDIS interface after a libusb probe detached it.
# This does not start liveview; it only gets usb0 back for diagnostics.

IFACE="${IFACE:-1-1:1.0}"

sudo modprobe rndis_host cdc_ether usbnet || true

if [[ -e /sys/bus/usb/drivers/rndis_host/bind ]]; then
  echo "$IFACE" | sudo tee /sys/bus/usb/drivers/rndis_host/bind >/dev/null || true
fi

sudo ip link set usb0 up 2>/dev/null || true

echo "[dji] network state:"
ip -br addr show usb0 2>/dev/null || echo "usb0 not present"

echo "[dji] recent RNDIS log:"
dmesg -T | tail -n 80 | grep -Ei 'rndis|cdc|usb0|2ca3|goggles|dji' || true
