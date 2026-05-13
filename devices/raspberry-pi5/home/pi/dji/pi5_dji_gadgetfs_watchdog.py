#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import subprocess
import time


def sh(cmd: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, shell=True, text=True, capture_output=True, check=check)


def read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def bridge_running() -> bool:
    out = sh("ps -eo comm=,args= | awk '$1==\"python3\" && $3==\"/home/pi/dji/pi5_gadgetfs_aoa_probe.py\" {print $0}'").stdout
    return bool(out.strip())


def kill_bridge() -> None:
    pids = sh("ps -eo pid=,comm=,args= | awk '$2==\"python3\" && $4==\"/home/pi/dji/pi5_gadgetfs_aoa_probe.py\" {print $1}'").stdout.split()
    for pid in pids:
        sh(f"kill {pid} 2>/dev/null || true")


def start_bridge(dest_ip: str, dest_port: int, udp_mtu: int, repeat_params: str, transport: str, udp_framed: bool) -> None:
    os.makedirs("/home/pi/dji", exist_ok=True)
    sh("modprobe gadgetfs || true")
    sh("mkdir -p /dev/gadget")
    sh("mountpoint -q /dev/gadget || mount -t gadgetfs gadgetfs /dev/gadget")
    sh(": > /home/pi/dji/gadgetfs_aoa_probe.log")
    framed_arg = "--udp-framed " if udp_framed else ""
    cmd = (
        "nohup python3 /home/pi/dji/pi5_gadgetfs_aoa_probe.py "
        f"--dest-ip {dest_ip} --dest-port {dest_port} --udp-mtu {udp_mtu} "
        f"--repeat-params {repeat_params} --transport {transport} {framed_arg}"
        ">/home/pi/dji/gadgetfs_aoa_probe.log 2>&1 &"
    )
    sh(cmd)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest-ip", default="100.97.231.5")
    ap.add_argument("--dest-port", type=int, default=5600)
    ap.add_argument("--udp-mtu", type=int, default=1200)
    ap.add_argument("--repeat-params", choices=("none", "keyframe", "everyframe"), default="keyframe")
    ap.add_argument("--transport", choices=("udp", "tcp"), default="udp")
    ap.add_argument("--udp-framed", action="store_true")
    ap.add_argument("--interval", type=float, default=2.0)
    args = ap.parse_args()

    last_restart = 0.0
    while True:
        state = read("/sys/class/udc/1000480000.usb/state")
        running = bridge_running()
        stale = running and state == "not attached"
        missing = not running
        if (stale or missing) and time.time() - last_restart > 5.0:
            print(f"{time.strftime('%H:%M:%S')} restart stale={stale} missing={missing} state={state}", flush=True)
            kill_bridge()
            time.sleep(0.5)
            start_bridge(args.dest_ip, args.dest_port, args.udp_mtu, args.repeat_params, args.transport, args.udp_framed)
            last_restart = time.time()
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
