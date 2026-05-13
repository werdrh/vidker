#!/usr/bin/env python3
import argparse
import select
import socket
import time

import serial


CRSF_RC_CHANNELS_PACKED = 0x16
CRSF_ADDR_TX_MODULE = 0xEE


def crc8_dvb_s2(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0xD5) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc


def valid_crsf_frame(frame: bytes) -> bool:
    if len(frame) < 4:
        return False
    length = frame[1]
    if length < 2 or length > 64:
        return False
    if len(frame) != length + 2:
        return False
    return crc8_dvb_s2(frame[2:-1]) == frame[-1]


def rewrite_for_tx(frame: bytes, tx_addr: int) -> bytes:
    if len(frame) >= 4 and frame[2] == CRSF_RC_CHANNELS_PACKED:
        return bytes([tx_addr & 0xFF]) + frame[1:]
    return frame


def main() -> int:
    ap = argparse.ArgumentParser(description="Forward raw UDP CRSF frames from Radxa to ELRS TX UART")
    ap.add_argument("--listen-ip", default="0.0.0.0")
    ap.add_argument("--listen-port", type=int, default=5000)
    ap.add_argument("--serial", default="/dev/ttyAMA0")
    ap.add_argument("--baud", type=int, default=400000)
    ap.add_argument("--tx-addr", type=lambda x: int(x, 0), default=CRSF_ADDR_TX_MODULE)
    ap.add_argument("--allow-invalid", action="store_true", help="Forward invalid datagrams too")
    ap.add_argument("--hold-ms", type=int, default=0, help="Repeat the last valid RC frame for this many ms during short UDP gaps")
    ap.add_argument("--repeat-hz", type=float, default=100.0, help="UART repeat rate while hold mode is active")
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    ser = serial.Serial(args.serial, args.baud, timeout=0, write_timeout=0)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.listen_ip, args.listen_port))
    sock.setblocking(False)

    forwarded = 0
    bad = 0
    held = 0
    bytes_out = 0
    last_log = time.monotonic()
    last_rc_frame = None
    last_rc_time = 0.0
    last_write_time = 0.0
    hold_sec = max(0.0, args.hold_ms / 1000.0)
    repeat_interval = 1.0 / max(1.0, args.repeat_hz)

    if args.debug:
        print(
            f"udp-crsf-to-uart listen={args.listen_ip}:{args.listen_port} "
            f"serial={args.serial}@{args.baud} tx_addr=0x{args.tx_addr:02X}",
            flush=True,
        )

    def write_frame(out: bytes) -> bool:
        nonlocal forwarded, bytes_out, last_write_time
        try:
            ser.write(out)
            forwarded += 1
            bytes_out += len(out)
            last_write_time = time.monotonic()
            return True
        except serial.SerialTimeoutException:
            return False

    while True:
        timeout = 1.0
        if hold_sec > 0 and last_rc_frame is not None:
            timeout = max(0.0, repeat_interval - (time.monotonic() - last_write_time))
        r, _, _ = select.select([sock], [], [], timeout)
        if not r:
            now = time.monotonic()
            if (
                hold_sec > 0
                and last_rc_frame is not None
                and now - last_rc_time <= hold_sec
                and now - last_write_time >= repeat_interval
            ):
                if write_frame(last_rc_frame):
                    held += 1
                else:
                    bad += 1
            if args.debug and now - last_log >= 1.0:
                age_ms = int((now - last_rc_time) * 1000) if last_rc_frame is not None else -1
                print(
                    f"forwarded={forwarded} held={held} bytes={bytes_out} "
                    f"bad={bad} rc_age_ms={age_ms}",
                    flush=True,
                )
                last_log = now
            continue
        while True:
            try:
                data, addr = sock.recvfrom(2048)
            except BlockingIOError:
                break

            frame = bytes(data)
            ok = valid_crsf_frame(frame)
            if not ok and not args.allow_invalid:
                bad += 1
                continue

            out = rewrite_for_tx(frame, args.tx_addr)
            if frame[2] == CRSF_RC_CHANNELS_PACKED and ok:
                last_rc_frame = out
                last_rc_time = time.monotonic()

            if not write_frame(out):
                bad += 1

            now = time.monotonic()
            if args.debug and now - last_log >= 1.0:
                age_ms = int((now - last_rc_time) * 1000) if last_rc_frame is not None else -1
                print(
                    f"from={addr[0]}:{addr[1]} forwarded={forwarded} "
                    f"held={held} bytes={bytes_out} bad={bad} rc_age_ms={age_ms} last_len={len(frame)} "
                    f"addr=0x{frame[0]:02X} type=0x{frame[2] if len(frame) > 2 else 0:02X}",
                    flush=True,
                )
                last_log = now


if __name__ == "__main__":
    raise SystemExit(main())
