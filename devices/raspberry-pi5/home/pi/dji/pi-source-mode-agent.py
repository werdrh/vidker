#!/usr/bin/env python3
import argparse
import os
import socket
import subprocess
import time


MODE_FILE = "/run/pi-source-mode"
EASYCAP_ENV = "/run/pi-easycap.env"


def run(cmd):
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def write_file(path, text):
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def service_active(name):
    result = subprocess.run(
        ["systemctl", "is-active", "--quiet", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def current_mode_tuple():
    try:
        parts = open(MODE_FILE, encoding="utf-8", errors="ignore").read().strip().split()
    except OSError:
        return None
    if len(parts) < 4:
        return None
    return tuple(parts[:4])


def set_mode(mode, dest_ip="", dest_port="5600", transport="udp"):
    desired = (mode, dest_ip, dest_port, transport)
    current = current_mode_tuple()
    if current == desired:
        if mode == "easycap" and service_active("easycap-udp.service") and not service_active("pi-dji-goggles-rtp.service"):
            return False
        if mode == "dji" and service_active("pi-dji-goggles-rtp.service") and not service_active("easycap-udp.service"):
            return False
        if mode == "camera" and not service_active("easycap-udp.service") and not service_active("pi-dji-goggles-rtp.service"):
            return False

    now = int(time.time())
    write_file(MODE_FILE, f"{mode} {dest_ip} {dest_port} {transport} {now}\n")

    if mode == "easycap":
        write_file(EASYCAP_ENV, f"DEST_IP={dest_ip}\nDEST_PORT={dest_port}\nTRANSPORT={transport}\n")
        run(["systemctl", "stop", "pi-dji-goggles-rtp.service"])
        run(["systemctl", "restart", "easycap-udp.service"])
    elif mode == "dji":
        run(["systemctl", "stop", "easycap-udp.service"])
        run(["systemctl", "restart", "pi-dji-goggles-rtp.service"])
    elif mode == "camera":
        run(["systemctl", "stop", "easycap-udp.service"])
        run(["systemctl", "stop", "pi-dji-goggles-rtp.service"])
    return True


def parse_message(data):
    parts = data.decode("ascii", "ignore").strip().split()
    if not parts:
        return None
    mode = parts[0].lower()
    if mode == "camera":
        return ("camera", "", "0", "udp")
    if mode in ("dji", "easycap"):
        dest_ip = parts[1] if len(parts) > 1 else "192.168.121.51"
        dest_port = parts[2] if len(parts) > 2 else "5600"
        transport = parts[3] if len(parts) > 3 else "udp"
        return (mode, dest_ip, dest_port, transport)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5513)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.listen, args.port))
    print(f"pi-source-mode-agent listening {args.listen}:{args.port}", flush=True)

    while True:
        data, addr = sock.recvfrom(256)
        parsed = parse_message(data)
        if not parsed:
            print(f"ignored from {addr}: {data!r}", flush=True)
            continue
        if set_mode(*parsed):
            print(f"mode applied from {addr}: {parsed}", flush=True)


if __name__ == "__main__":
    main()
