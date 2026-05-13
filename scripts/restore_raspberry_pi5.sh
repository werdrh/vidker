#!/bin/sh
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$REPO_DIR/devices/raspberry-pi5"
BACKUP="/root/vidker-pi5-restore-backup-$(date +%Y%m%d-%H%M%S)"
APPLY_NOW=0

if [ "$(id -u)" != "0" ]; then
  echo "Run as root: sudo $0 [--apply-now]" >&2
  exit 1
fi

for arg in "$@"; do
  case "$arg" in
    --apply-now) APPLY_NOW=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ ! -d "$SRC" ]; then
  echo "Missing snapshot directory: $SRC" >&2
  exit 1
fi

backup_one() {
  target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "$BACKUP$(dirname "$target")"
    cp -a "$target" "$BACKUP$target"
  fi
}

copy_tree() {
  rel="$1"
  [ -d "$SRC/$rel" ] || return 0
  find "$SRC/$rel" -type f | while IFS= read -r file; do
    target="/${file#"$SRC/"}"
    backup_one "$target"
    mkdir -p "$(dirname "$target")"
    cp -a "$file" "$target"
  done
}

echo "Backing up replaced files to: $BACKUP"

copy_tree home
copy_tree opt
copy_tree etc
copy_tree boot

chown -R pi:pi /home/pi/dji 2>/dev/null || true
chmod 755 /home/pi/dji/*.sh /opt/easycap-rc/*.sh 2>/dev/null || true
chmod 755 /home/pi/dji/pi5_gadgetfs_aoa_bridge_c 2>/dev/null || true

systemctl daemon-reload

systemctl enable ssh.service tailscaled.service 2>/dev/null || true
systemctl enable \
  pi-direct-lan-keepalive.service \
  pi-dji-crsf-uart.service \
  pi-dji-goggles-rtp.service \
  pi-lan-internet-share.service \
  easycap-udp.service

if [ "$APPLY_NOW" = "1" ]; then
  systemctl restart pi-direct-lan-keepalive.service || true
  systemctl restart pi-dji-crsf-uart.service pi-dji-goggles-rtp.service || true
  systemctl restart pi-lan-internet-share.service easycap-udp.service || true
fi

echo "Pi 5 restore complete."
echo "Backup: $BACKUP"
echo "Recommended next step: sudo reboot"
