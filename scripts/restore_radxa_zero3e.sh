#!/bin/sh
set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$REPO_DIR/devices/radxa-zero3e"
BACKUP="/root/vidker-restore-backup-$(date +%Y%m%d-%H%M%S)"
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

copy_tree opt
copy_tree etc
copy_tree boot
copy_tree usr

chmod 755 /opt/radxa3e-groundstation/*.sh 2>/dev/null || true
chmod 755 /opt/radxa3e-groundstation/radxa3e-control-bridge-c 2>/dev/null || true
chmod 755 /usr/local/bin/tcp_rtp_to_udp 2>/dev/null || true
chmod 755 /usr/local/bin/rtp_reorder_proxy 2>/dev/null || true

systemctl daemon-reload

systemctl enable ssh.service NetworkManager.service tailscaled.service 2>/dev/null || true
systemctl enable \
  radxa3e-gs.service \
  radxa3e-control-bridge.service \
  radxa3e-auto-link.service \
  radxa3e-external-osd.service \
  radxa3e-signal-loss-watch.service \
  radxa3e-record-button.service \
  radxa3e-mode-button.service \
  radxa3e-power-button.service \
  radxa-direct-lan-keepalive.service \
  tcp-rtp-to-udp.service \
  radxa3e-record-mount.service \
  radxa3e-guard.service

systemctl enable radxa3e-record-mount-watch.timer radxa3e-remux-scan.timer

# These are kept in the snapshot for reference, but should not autostart in the current setup.
systemctl disable rtp-reorder-proxy.service radxa3e-osd-status.service radxa3e-recorder.service radxa3e-udp-splitter.service 2>/dev/null || true

if command -v u-boot-update >/dev/null 2>&1; then
  u-boot-update || true
fi

if [ "$APPLY_NOW" = "1" ]; then
  systemctl restart ssh.service NetworkManager.service 2>/dev/null || true
  systemctl restart radxa3e-record-mount.service || true
  systemctl restart radxa3e-gs.service radxa3e-control-bridge.service radxa3e-auto-link.service || true
  systemctl restart radxa3e-external-osd.service radxa3e-signal-loss-watch.service || true
  systemctl restart radxa3e-record-button.service radxa3e-mode-button.service radxa3e-power-button.service || true
  systemctl restart radxa-direct-lan-keepalive.service tcp-rtp-to-udp.service radxa3e-guard.service || true
fi

echo "Restore complete."
echo "Backup: $BACKUP"
echo "Recommended next step: sudo reboot"
