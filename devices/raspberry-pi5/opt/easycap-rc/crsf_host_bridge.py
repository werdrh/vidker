#!/usr/bin/env python3
import argparse
import socket
import struct
import time
import sys

import serial


CRSF_FRAMETYPE_RC_CHANNELS_PACKED = 0x16
CRSF_ADDR_TX_MODULE = 0xEE
CHANNEL_COUNT = 16
UDP_STRUCT = struct.Struct("<16H")


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


def us_to_crsf(us: int) -> int:
    us = max(988, min(2012, us))
    return int(round((us - 988) * 1639 / (2012 - 988) + 172))


def pack_channels(channels_us: list[int]) -> bytes:
    packed = 0
    bitpos = 0
    for us in channels_us[:CHANNEL_COUNT]:
        value = us_to_crsf(us) & 0x7FF
        packed |= value << bitpos
        bitpos += 11
    return packed.to_bytes(22, "little")


def build_crsf_rc_frame(channels_us: list[int], addr: int) -> bytes:
    payload = pack_channels(channels_us)
    body = bytes([CRSF_FRAMETYPE_RC_CHANNELS_PACKED]) + payload
    length = len(body) + 1
    crc = crc8_dvb_s2(body)
    return bytes([addr, length]) + body + bytes([crc])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True, help="e.g. /dev/ttyS5")
    ap.add_argument("--baud", type=int, default=400000)
    ap.add_argument("--udp-port", type=int, default=5700)
    ap.add_argument("--addr", type=lambda x: int(x, 0), default=CRSF_ADDR_TX_MODULE)
    ap.add_argument("--rate-hz", type=int, default=150)
    ap.add_argument("--failsafe-ms", type=int, default=300)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    ser = serial.Serial(args.serial, args.baud, timeout=0)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", args.udp_port))
    sock.settimeout(0.01)

    channels = [1500] * CHANNEL_COUNT
    channels[2] = 1000
    channels[3] = 1500
    last_rx = 0.0
    period = 1.0 / args.rate_hz
    next_tx = time.monotonic()
    sent = 0
    last_debug = 0.0

    if args.debug:
        print(
            f"crsf bridge start serial={args.serial} baud={args.baud} udp={args.udp_port} addr=0x{args.addr:02X}",
            flush=True,
        )

    while True:
        try:
            data, _ = sock.recvfrom(1024)
            if len(data) == UDP_STRUCT.size:
                channels = list(UDP_STRUCT.unpack(data))
                last_rx = time.monotonic()
                if args.debug:
                    now = time.monotonic()
                    if now - last_debug > 1.0:
                        print(
                            "udp-rx ch1-8=" + ",".join(str(v) for v in channels[:8]),
                            flush=True,
                        )
                        last_debug = now
        except socket.timeout:
            pass

        now = time.monotonic()
        if now - last_rx > args.failsafe_ms / 1000.0:
            channels[2] = 1000

        if now >= next_tx:
            frame = build_crsf_rc_frame(channels, args.addr)
            ser.write(frame)
            sent += 1
            if args.debug and (sent <= 5 or sent % 200 == 0):
                print(
                    f"tx-frame sent={sent} len={len(frame)} hex={frame.hex()}",
                    flush=True,
                )
            next_tx += period
            if next_tx < now:
                next_tx = now + period


if __name__ == "__main__":
    main()
