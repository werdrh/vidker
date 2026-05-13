#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import select
import socket
import struct
import sys
import threading
import time

GADGETFS_CONNECT = 1
GADGETFS_DISCONNECT = 2
GADGETFS_SETUP = 3
GADGETFS_SUSPEND = 4

USB_REQ_SET_CONFIGURATION = 9
USB_REQ_SET_INTERFACE = 11
DJI_TRIGGER_FRAME_1 = bytes.fromhex(
    "55cc49572d000000552d04f20228f3fe40009902020000d507000000000013000d0063616d6361705f636f6d6d6f6e00000000d093923a"
)
DJI_TRIGGER_FRAME_2 = bytes.fromhex(
    "55cc49571b000000551b0475023cf4fe400088170000230041505000000000000258a63418"
)
UDP_FRAME_MAGIC = b"DJI0"
UDP_FRAME_HEADER = struct.Struct("!4sIHH")


def log(s: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {s}", flush=True)


def ep(addr: int, maxpkt: int) -> bytes:
    return struct.pack("<BBBBHB", 7, 5, addr, 2, maxpkt, 0)


def ep_disabled(addr: int) -> bytes:
    return struct.pack("<BBBBHB", 7, 5, addr, 0, 0, 0)


def iface() -> bytes:
    return struct.pack("<BBBBBBBBB", 9, 4, 0, 0, 2, 0xFF, 0xFF, 0, 0)


def config(maxpkt: int) -> bytes:
    body = iface() + ep(0x01, maxpkt) + ep(0x81, maxpkt)
    total = 9 + len(body)
    cfg = struct.pack("<BBHBBBBB", 9, 2, total, 1, 1, 0, 0x80, 250)
    return cfg + body


def device() -> bytes:
    return struct.pack(
        "<BBHBBBBHHHBBBB",
        18,
        1,
        0x0200,
        0,
        0,
        0,
        64,
        0x18D1,
        0x2D00,
        0x0100,
        0,
        0,
        0,
        1,
    )


ANNEXB3 = b"\x00\x00\x01"
ANNEXB4 = b"\x00\x00\x00\x01"


def annexb_nals(data: bytes) -> list[bytes]:
    starts: list[int] = []
    i = 0
    while i < len(data) - 3:
        if data.startswith(ANNEXB4, i):
            starts.append(i)
            i += 4
        elif data.startswith(ANNEXB3, i):
            starts.append(i)
            i += 3
        else:
            i += 1
    return [data[start:(starts[idx + 1] if idx + 1 < len(starts) else len(data))] for idx, start in enumerate(starts)]


def nal_type(nal: bytes) -> int | None:
    if nal.startswith(ANNEXB4):
        pos = 4
    elif nal.startswith(ANNEXB3):
        pos = 3
    else:
        return None
    return None if pos >= len(nal) else nal[pos] & 0x1F


def preview(data: bytes, limit: int = 96) -> str:
    ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in data[:48])
    suffix = "" if len(data) <= limit else "..."
    return f"len={len(data)} hex={data[:limit].hex()}{suffix} ascii={ascii_part}"


def classify(data: bytes) -> str:
    tags = []
    if b"\x55\xcc" in data:
        tags.append("55CC")
    if b"\x00\x00\x01" in data or b"\x00\x00\x00\x01" in data:
        tags.append("H264")
    if data.startswith(b"\x55"):
        tags.append("DUML?")
    return ",".join(tags) if tags else "raw"


class BulkEndpoints:
    def __init__(
        self,
        mount: str,
        dest_ip: str,
        dest_port: int,
        udp_mtu: int,
        repeat_params: str,
        transport: str,
        udp_framed: bool,
    ) -> None:
        self.mount = mount
        self.dest = (dest_ip, dest_port)
        self.udp_mtu = udp_mtu
        self.repeat_params = repeat_params
        self.transport = transport
        self.udp_framed = udp_framed
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM) if transport == "udp" else None
        self.tcp: socket.socket | None = None
        self.last_tcp_attempt = 0.0
        self.udp_frame_id = 0
        self.out_fd: int | None = None
        self.in_fd: int | None = None
        self.started = False
        self.stop = False
        self.video_channel: int | None = None
        self.sps: bytes | None = None
        self.pps: bytes | None = None
        self.stream_ready = False
        self.last_stats = time.time()
        self.pkts = 0
        self.video_pkts = 0
        self.video_bytes = 0

    def start(self) -> None:
        if self.started:
            return
        self.stop = False
        self.out_fd = os.open(os.path.join(self.mount, "ep1out"), os.O_RDWR)
        self.in_fd = os.open(os.path.join(self.mount, "ep1in"), os.O_RDWR)
        # GadgetFS wants a marker plus FS and HS endpoint descriptors.
        os.write(self.out_fd, struct.pack("=I", 1) + ep_disabled(0x01) + ep(0x01, 512))
        os.write(self.in_fd, struct.pack("=I", 1) + ep_disabled(0x81) + ep(0x81, 512))
        self.started = True
        log("bulk endpoints started ep1out/ep1in")
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._trigger_writer, daemon=True).start()

    def reset(self) -> None:
        self.stop = True
        for fd in (self.out_fd, self.in_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        self.out_fd = None
        self.in_fd = None
        self.started = False
        self.video_channel = None
        self.sps = None
        self.pps = None
        self.stream_ready = False
        self._close_tcp()
        log("bulk endpoints reset")

    def _reader(self) -> None:
        assert self.out_fd is not None
        while not self.stop:
            try:
                data = os.read(self.out_fd, 16384)
            except OSError as exc:
                log(f"OUT read error: {exc}")
                time.sleep(0.2)
                continue
            if data:
                self.pkts += 1
                self._handle_out(data)
                now = time.time()
                if now - self.last_stats >= 1.0:
                    chan = f"0x{self.video_channel:04x}" if self.video_channel is not None else None
                    log(
                        f"stats pkts={self.pkts} video_channel={chan} "
                        f"video_pkts={self.video_pkts} video_bytes={self.video_bytes}"
                    )
                    self.last_stats = now

    def _handle_out(self, data: bytes) -> None:
        if not data.startswith(b"\x55\xcc") or len(data) < 8:
            if self.pkts < 10:
                log(f"OUT {classify(data)} {preview(data)}")
            return
        channel = data[2] | (data[3] << 8)
        length = data[4] | (data[5] << 8)
        payload = data[8:8 + length]
        # 0x5749 carries control/DUML and can contain 00 00 01-like values.
        # Real video has been observed on 0x574a with larger Annex B chunks.
        has_h264 = (ANNEXB3 in payload or ANNEXB4 in payload) and len(payload) >= 256
        if has_h264 and self.video_channel is None:
            if channel != 0x5749:
                self.video_channel = channel
                log(f"locked video channel=0x{channel:04x} first={preview(payload)}")
        if self.video_channel == channel:
            nals = annexb_nals(payload)
            types = {t for t in (nal_type(nal) for nal in nals) if t is not None}
            for nal in nals:
                t = nal_type(nal)
                if t == 7:
                    self.sps = nal
                elif t == 8:
                    self.pps = nal
            if not self.stream_ready:
                if self.sps and self.pps:
                    self.stream_ready = True
                    log("H264 parameter sets ready; UDP stream enabled")
                else:
                    return
            should_repeat = (
                self.repeat_params == "everyframe" and (1 in types or 5 in types)
            ) or (
                self.repeat_params == "keyframe" and 5 in types
            )
            if should_repeat and 7 not in types and self.sps and self.pps:
                self._send_udp(self.sps + self.pps)
            self.video_pkts += 1
            self.video_bytes += len(payload)
            self._send_udp(payload)

    def _send_udp(self, payload: bytes) -> None:
        if self.transport == "tcp":
            self._send_tcp(payload)
            return
        if self.udp_framed:
            self._send_udp_framed(payload)
            return
        # ffmpeg's UDP reader treats datagrams as a byte stream for raw H.264.
        # Slicing avoids IP fragmentation over Tailscale/Wi-Fi without adding
        # codec latency or a container.
        for offset in range(0, len(payload), self.udp_mtu):
            assert self.sock is not None
            self.sock.sendto(payload[offset:offset + self.udp_mtu], self.dest)

    def _send_udp_framed(self, payload: bytes) -> None:
        assert self.sock is not None
        frame_id = self.udp_frame_id & 0xFFFFFFFF
        self.udp_frame_id = (self.udp_frame_id + 1) & 0xFFFFFFFF
        chunk_size = max(256, self.udp_mtu - UDP_FRAME_HEADER.size)
        total = (len(payload) + chunk_size - 1) // chunk_size
        for idx in range(total):
            offset = idx * chunk_size
            chunk = payload[offset:offset + chunk_size]
            header = UDP_FRAME_HEADER.pack(UDP_FRAME_MAGIC, frame_id, idx, total)
            self.sock.sendto(header + chunk, self.dest)

    def _connect_tcp(self) -> socket.socket | None:
        if self.tcp is not None:
            return self.tcp
        now = time.time()
        if now - self.last_tcp_attempt < 1.0:
            return None
        self.last_tcp_attempt = now
        try:
            sock = socket.create_connection(self.dest, timeout=1.0)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
            self.tcp = sock
            log(f"TCP connected {self.dest[0]}:{self.dest[1]}")
        except OSError as exc:
            log(f"TCP connect failed: {exc}")
            self.tcp = None
        return self.tcp

    def _close_tcp(self) -> None:
        if self.tcp is None:
            return
        try:
            self.tcp.close()
        except OSError:
            pass
        self.tcp = None

    def _send_tcp(self, payload: bytes) -> None:
        sock = self._connect_tcp()
        if sock is None:
            return
        try:
            sock.sendall(payload)
        except OSError as exc:
            log(f"TCP send failed: {exc}")
            self._close_tcp()

    def _trigger_writer(self) -> None:
        assert self.in_fd is not None
        frames = [DJI_TRIGGER_FRAME_1, DJI_TRIGGER_FRAME_2]
        while not self.stop:
            for frame in frames:
                try:
                    n = os.write(self.in_fd, frame)
                    log(f"IN trigger wrote {n} bytes")
                except OSError as exc:
                    log(f"IN write error: {exc}")
                    time.sleep(0.5)
                    break
            time.sleep(1.0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mount", default="/dev/gadget")
    ap.add_argument("--chip", default="1000480000.usb")
    ap.add_argument("--dest-ip", default="127.0.0.1")
    ap.add_argument("--dest-port", type=int, default=5600)
    ap.add_argument("--udp-mtu", type=int, default=1200)
    ap.add_argument("--repeat-params", choices=("none", "keyframe", "everyframe"), default="keyframe")
    ap.add_argument("--transport", choices=("udp", "tcp"), default="udp")
    ap.add_argument("--udp-framed", action="store_true")
    args = ap.parse_args()

    ep0_path = os.path.join(args.mount, args.chip)
    log(f"open ep0 {ep0_path}")
    fd = os.open(ep0_path, os.O_RDWR)

    blob = struct.pack("=I", 0) + config(64) + config(512) + device()
    log(f"write descriptors len={len(blob)}")
    os.write(fd, blob)
    log(f"after descriptor write: {os.listdir(args.mount)}")
    bulk = BulkEndpoints(
        args.mount,
        args.dest_ip,
        args.dest_port,
        args.udp_mtu,
        args.repeat_params,
        args.transport,
        args.udp_framed,
    )

    poll = select.poll()
    poll.register(fd, select.POLLIN)
    while True:
        for _fd, _ev in poll.poll(1000):
            raw = os.read(fd, 12)
            if len(raw) != 12:
                log(f"short event len={len(raw)} {raw.hex()}")
                continue
            ev_type = struct.unpack_from("=I", raw, 8)[0]
            if ev_type == GADGETFS_CONNECT:
                speed = struct.unpack_from("=I", raw, 0)[0]
                log(f"CONNECT speed={speed} files={os.listdir(args.mount)}")
            elif ev_type == GADGETFS_DISCONNECT:
                log("DISCONNECT")
                bulk.reset()
            elif ev_type == GADGETFS_SUSPEND:
                log("SUSPEND")
                bulk.reset()
            elif ev_type == GADGETFS_SETUP:
                bm, req, value, index, length = struct.unpack("<BBHHH", raw[:8])
                log(
                    f"SETUP bm=0x{bm:02x} req=0x{req:02x} "
                    f"value=0x{value:04x} index=0x{index:04x} len={length}"
                )
                if bm & 0x80:
                    log("STALL IN setup")
                    try:
                        os.read(fd, 0)
                    except OSError as exc:
                        log(f"stall read0: {exc}")
                else:
                    if length:
                        data = os.read(fd, length)
                        log(f"OUT setup data {data.hex()}")
                    if req in (USB_REQ_SET_CONFIGURATION, USB_REQ_SET_INTERFACE):
                        try:
                            os.read(fd, 0)
                            log(f"ACK req=0x{req:02x}; files={os.listdir(args.mount)}")
                            if req == USB_REQ_SET_CONFIGURATION and value:
                                bulk.start()
                        except OSError as exc:
                            log(f"ACK failed: {exc}")
                    else:
                        log("STALL OUT setup")
                        try:
                            os.write(fd, b"")
                        except OSError as exc:
                            log(f"stall write0: {exc}")
            else:
                log(f"EVENT type={ev_type} raw={raw.hex()}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        raise SystemExit(130)
