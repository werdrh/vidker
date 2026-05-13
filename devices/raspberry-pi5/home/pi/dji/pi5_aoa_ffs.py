#!/usr/bin/env python3
"""
Minimal Android Open Accessory-like FunctionFS endpoint daemon.

This is a probing harness, not a complete Android implementation. It exposes
one vendor-specific interface with bulk OUT + bulk IN endpoints and logs all
traffic from the USB host. For DJI Goggles testing, run it through
pi5_start_aoa_gadget.sh after the Pi5 USB-C port is in peripheral mode.
"""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import time

FUNCTIONFS_DESCRIPTORS_MAGIC_V2 = 3
FUNCTIONFS_STRINGS_MAGIC = 2
FUNCTIONFS_HAS_FS_DESC = 1
FUNCTIONFS_HAS_HS_DESC = 2

USB_DT_INTERFACE = 0x04
USB_DT_ENDPOINT = 0x05
USB_ENDPOINT_XFER_BULK = 0x02

EVENT_NAMES = {
    0: "BIND",
    1: "UNBIND",
    2: "ENABLE",
    3: "DISABLE",
    4: "SETUP",
    5: "SUSPEND",
    6: "RESUME",
}

ANNEXB3 = b"\x00\x00\x01"
ANNEXB4 = b"\x00\x00\x00\x01"


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def interface_desc() -> bytes:
    # bInterfaceClass/SubClass/Protocol = 0xff is intentionally generic.
    return struct.pack(
        "<BBBBBBBBB",
        9, USB_DT_INTERFACE,
        0, 0, 2,
        0xFF, 0xFF, 0x00,
        1,
    )


def endpoint_desc(addr: int, max_packet: int) -> bytes:
    return struct.pack(
        "<BBBBHB",
        7, USB_DT_ENDPOINT,
        addr,
        USB_ENDPOINT_XFER_BULK,
        max_packet,
        0,
    )


def build_descriptors() -> bytes:
    fs = interface_desc() + endpoint_desc(0x01, 64) + endpoint_desc(0x81, 64)
    hs = interface_desc() + endpoint_desc(0x01, 512) + endpoint_desc(0x81, 512)
    flags = FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC
    body = struct.pack("<II", 3, 3) + fs + hs
    header = struct.pack("<III", FUNCTIONFS_DESCRIPTORS_MAGIC_V2, 12 + len(body), flags)
    return header + body


def build_strings() -> bytes:
    strings = [b"DJI AOA Probe\x00"]
    table = struct.pack("<H", 0x0409) + b"".join(strings)
    body = struct.pack("<II", len(strings), 1) + table
    return struct.pack("<II", FUNCTIONFS_STRINGS_MAGIC, 8 + len(body)) + body


def preview(data: bytes, limit: int = 96) -> str:
    h = data[:limit].hex()
    ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in data[:48])
    suffix = "" if len(data) <= limit else "..."
    return f"len={len(data)} hex={h}{suffix} ascii={ascii_part}"


def classify(data: bytes) -> str:
    tags = []
    if b"\x55\xcc" in data:
        tags.append("55CC")
    if ANNEXB3 in data or ANNEXB4 in data:
        tags.append("H264_ANNEXB")
    if data.startswith(b"\x55") and len(data) >= 13:
        tags.append("DUML_LIKE")
    return ",".join(tags) if tags else "raw"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mount", default="/dev/ffs-aoa")
    ap.add_argument("--reply-zeros", action="store_true", help="Write small zero replies on bulk IN after host OUT")
    args = ap.parse_args()

    ep0_path = os.path.join(args.mount, "ep0")
    log(f"opening {ep0_path}")
    ep0 = os.open(ep0_path, os.O_RDWR)
    os.write(ep0, build_descriptors())
    os.write(ep0, build_strings())
    log("descriptors written; waiting for host enable")

    ep_out = None
    ep_in = None
    enabled = False
    poller = select.poll()
    poller.register(ep0, select.POLLIN)

    while True:
        for fd, event in poller.poll(500):
            if fd == ep0:
                raw = os.read(ep0, 12)
                if len(raw) < 12:
                    continue
                bm_req, b_req, w_value, w_index, w_len, ev_type = struct.unpack("<BBHHHBxxx", raw)
                name = EVENT_NAMES.get(ev_type, f"UNKNOWN({ev_type})")
                if name == "SETUP":
                    log(
                        f"event SETUP bm=0x{bm_req:02x} req=0x{b_req:02x} "
                        f"value=0x{w_value:04x} index=0x{w_index:04x} len={w_len}"
                    )
                    # Stall/ack conservatively. FunctionFS expects setup data phase handling,
                    # but for this probe we only log unexpected control requests.
                    try:
                        os.read(ep0, w_len) if (bm_req & 0x80) == 0 and w_len else None
                    except OSError:
                        pass
                else:
                    log(f"event {name}")
                    if name == "ENABLE" and not enabled:
                        ep_out = os.open(os.path.join(args.mount, "ep1"), os.O_RDWR | os.O_NONBLOCK)
                        ep_in = os.open(os.path.join(args.mount, "ep2"), os.O_RDWR | os.O_NONBLOCK)
                        poller.register(ep_out, select.POLLIN)
                        enabled = True
                        log("bulk endpoints open: ep1=OUT ep2=IN")
                    elif name in ("DISABLE", "UNBIND"):
                        enabled = False
            elif ep_out is not None and fd == ep_out:
                try:
                    data = os.read(ep_out, 16384)
                except BlockingIOError:
                    continue
                if not data:
                    continue
                log(f"OUT {classify(data)} {preview(data)}")
                if args.reply_zeros and ep_in is not None:
                    try:
                        os.write(ep_in, b"\x00" * 16)
                        log("IN wrote 16 zero bytes")
                    except OSError as exc:
                        log(f"IN write failed: {exc}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        raise SystemExit(130)
