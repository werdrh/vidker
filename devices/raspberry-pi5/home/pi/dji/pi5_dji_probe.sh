#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "[dji] USB devices:"
lsusb
echo
echo "[dji] Detailed endpoint discovery:"
python3 ./dji_usb_discover.py
