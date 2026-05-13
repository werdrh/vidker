#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path

import paramiko


FILES = [
    "/opt/radxa3e-groundstation/no-signal.jpg",
    "/opt/radxa3e-groundstation/pixelpilot-osd-minimal.json",
    "/opt/radxa3e-groundstation/radxa3e-auto-link.sh",
    "/opt/radxa3e-groundstation/radxa3e-control-bridge-c",
    "/opt/radxa3e-groundstation/radxa3e-control-bridge.c",
    "/opt/radxa3e-groundstation/radxa3e-control-bridge.py",
    "/opt/radxa3e-groundstation/radxa3e-external-osd.py",
    "/opt/radxa3e-groundstation/radxa3e-gs.sh",
    "/opt/radxa3e-groundstation/radxa3e-guard.sh",
    "/opt/radxa3e-groundstation/radxa3e-mode-button.sh",
    "/opt/radxa3e-groundstation/radxa3e-power-button.sh",
    "/opt/radxa3e-groundstation/radxa3e-record-button.sh",
    "/opt/radxa3e-groundstation/radxa3e-recorder.sh",
    "/opt/radxa3e-groundstation/radxa3e-record-mount.sh",
    "/opt/radxa3e-groundstation/radxa3e-record-status-sync.sh",
    "/opt/radxa3e-groundstation/radxa3e-signal-loss-watch.sh",
    "/opt/radxa3e-groundstation/radxa3e-splash.sh",
    "/opt/radxa3e-groundstation/radxa3e-sync-recording.sh",
    "/opt/radxa3e-groundstation/radxa-direct-lan-keepalive.sh",
    "/etc/systemd/system/radxa3e-auto-link.service",
    "/etc/systemd/system/radxa3e-control-bridge.service",
    "/etc/systemd/system/radxa3e-external-osd.service",
    "/etc/systemd/system/radxa3e-gs.service",
    "/etc/systemd/system/radxa3e-guard.service",
    "/etc/systemd/system/radxa3e-mode-button.service",
    "/etc/systemd/system/radxa3e-power-button.service",
    "/etc/systemd/system/radxa3e-record-button.service",
    "/etc/systemd/system/radxa3e-recorder.service",
    "/etc/systemd/system/radxa3e-record-mount.service",
    "/etc/systemd/system/radxa3e-record-mount-watch.service",
    "/etc/systemd/system/radxa3e-record-mount-watch.timer",
    "/etc/systemd/system/radxa3e-remux-scan.service",
    "/etc/systemd/system/radxa3e-remux-scan.timer",
    "/etc/systemd/system/radxa3e-signal-loss-watch.service",
    "/etc/systemd/system/radxa-direct-lan-keepalive.service",
    "/etc/systemd/system/rtp-reorder-proxy.service",
    "/etc/systemd/system/tcp-rtp-to-udp.service",
    "/etc/default/radxa3e-control-bridge",
    "/etc/default/radxa3e-gs",
    "/etc/default/radxa3e-guard",
    "/etc/default/radxa3e-mode-button",
    "/etc/default/radxa3e-osd-status",
    "/etc/default/radxa3e-power-button",
    "/etc/default/radxa3e-record-button",
    "/etc/default/radxa3e-signal-loss-watch",
    "/etc/default/radxa3e-source-mode",
    "/etc/default/u-boot",
    "/boot/dtbo/rk3568-uart4-m1.dtbo",
    "/boot/dtbo/rk3568-i2c4-m0.dtbo",
    "/boot/dtbo/managed.list",
    "/etc/systemd/logind.conf.d/99-radxa-ignore-power-key.conf",
    "/etc/ssh/sshd_config.d/99-radxa-password-login.conf",
    "/etc/udev/rules.d/99-radxa-record-usb-power.rules",
    "/etc/sysctl.d/99-radxa3e-quiet-console.conf",
    "/usr/local/bin/tcp_rtp_to_udp",
    "/usr/local/bin/rtp_reorder_proxy",
]

COMMANDS = {
    "system-state.txt": r"""set -u
printf 'Collected: '; date -Is
printf 'Host: '; hostname
printf 'Arch: '; uname -m
printf 'Kernel: '; uname -a
printf '\n== failed units ==\n'; systemctl --failed --no-pager || true
printf '\n== enabled radxa/tcp services ==\n'; systemctl list-unit-files --no-pager | grep -E 'radxa|tcp-rtp|rtp-reorder|tailscale|ssh' || true
printf '\n== active units ==\n'; systemctl --no-pager --type=service --state=running | grep -E 'radxa|tcp-rtp|tailscale|ssh|NetworkManager' || true
printf '\n== timers ==\n'; systemctl list-timers --all --no-pager | grep -E 'radxa|remux|record' || true
printf '\n== links ==\n'; ip -brief addr || true
printf '\n== routes ==\n'; ip route || true
printf '\n== source mode ==\n'; cat /etc/default/radxa3e-source-mode 2>/dev/null || true
printf '\n== runtime link mode ==\n'; cat /run/radxa3e-link-mode 2>/dev/null || true
printf '\n== gpio chips ==\n'; gpioinfo 2>/dev/null | sed -n '1,120p' || true
printf '\n== serial/i2c ==\n'; ls -l /dev/ttyS4 /dev/i2c-4 2>/dev/null || true
printf '\n== pixelpilot ==\n'; pgrep -a pixelpilot || true
printf '\n== recording mount ==\n'; findmnt /media/recordings || true; df -h /media/recordings 2>/dev/null || true
""",
    "packages.txt": "dpkg-query -W -f='${Package} ${Version}\\n' | sort | grep -E 'pixelpilot|gstreamer|ffmpeg|wireguard|tailscale|network-manager|python|gpio|libgpiod|i2c|v4l|exfat|ntfs|ssh|curl' || true",
    "journal-recent.txt": "journalctl -u radxa3e-gs -u radxa3e-control-bridge -u radxa3e-auto-link -u radxa3e-record-button -u radxa3e-mode-button -u radxa3e-power-button -u radxa3e-guard -u tcp-rtp-to-udp -n 250 --no-pager || true",
}


def run(ssh, command, timeout=30):
    _, stdout, stderr = ssh.exec_command(command, timeout=timeout)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    return out + (("\nSTDERR:\n" + err) if err else "")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="100.80.47.96")
    parser.add_argument("--user", default="rock")
    parser.add_argument("--password", default=os.environ.get("RADXA_PASSWORD"))
    parser.add_argument("--key")
    parser.add_argument("--out", default=Path(__file__).resolve().parents[1] / "devices" / "radxa-zero3e", type=Path)
    args = parser.parse_args()

    if not args.password and not args.key:
        raise SystemExit("Provide --password or --key, or set RADXA_PASSWORD.")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kwargs = {"hostname": args.host, "username": args.user, "timeout": 10}
    if args.key:
        kwargs["key_filename"] = args.key
    else:
        kwargs["password"] = args.password
    ssh.connect(**kwargs)
    sftp = ssh.open_sftp()

    args.out.mkdir(parents=True, exist_ok=True)
    manifest = []
    for remote in FILES:
        local = args.out / remote.lstrip("/")
        try:
            st = sftp.stat(remote)
        except FileNotFoundError:
            manifest.append({"path": remote, "status": "missing"})
            continue
        local.parent.mkdir(parents=True, exist_ok=True)
        sftp.get(remote, str(local))
        os.chmod(local, st.st_mode & 0o777)
        digest = hashlib.sha256(local.read_bytes()).hexdigest()
        manifest.append({
            "path": remote,
            "status": "ok",
            "mode": oct(st.st_mode & 0o777),
            "size": st.st_size,
            "sha256": digest,
        })

    for name, command in COMMANDS.items():
        (args.out / name).write_text(run(ssh, command), encoding="utf-8")

    (args.out / "manifest.json").write_text(json.dumps({
        "host": args.host,
        "user": args.user,
        "collected_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "files": manifest,
    }, indent=2), encoding="utf-8")

    sftp.close()
    ssh.close()
    print(f"Collected {sum(1 for item in manifest if item['status'] == 'ok')} files into {args.out}")


if __name__ == "__main__":
    main()
