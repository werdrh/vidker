#!/usr/bin/env python3
"""
MVP userspace bridge for:

    DJI Goggles 3 --USB--> Radxa Rock 3E --UDP--> Raspberry Pi 5

This is intentionally a low-level skeleton:
- It does not assume UVC.
- It expects an outer 55 CC transport wrapper.
- It auto-detects a likely H.264 channel by scanning payloads for Annex B start codes.
- It forwards raw Annex B bytes over UDP without transcoding.

Before first real use, fill in the actual USB VID/PID/interface/endpoints discovered on the target system.
"""

from __future__ import annotations

import argparse
import collections
import dataclasses
import logging
import socket
import struct
import sys
import time
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

try:
    import usb.core
    import usb.util
except ImportError:  # pragma: no cover - environment may not have pyusb installed yet
    usb = None


LOG = logging.getLogger("goggles-bridge")

FRAME_MAGIC = b"\x55\xCC"
ANNEXB3 = b"\x00\x00\x01"
ANNEXB4 = b"\x00\x00\x00\x01"
DJI_TRIGGER_FRAME_1 = bytes.fromhex(
    "55cc49572d000000552d04f20228f3fe40009902020000d507000000000013000d0063616d6361705f636f6d6d6f6e00000000d093923a"
)
DJI_TRIGGER_FRAME_2 = bytes.fromhex(
    "55cc49571b000000551b0475023cf4fe400088170000230041505000000000000258a63418"
)


def find_annexb_positions(payload: bytes) -> List[int]:
    positions: List[int] = []
    idx = 0
    while idx < len(payload) - 3:
        if payload[idx:idx + 4] == ANNEXB4:
            positions.append(idx)
            idx += 4
            continue
        if payload[idx:idx + 3] == ANNEXB3:
            positions.append(idx)
            idx += 3
            continue
        idx += 1
    return positions


def nal_type_from_annexb(payload: bytes, start: int) -> Optional[int]:
    if payload[start:start + 4] == ANNEXB4:
        off = start + 4
    elif payload[start:start + 3] == ANNEXB3:
        off = start + 3
    else:
        return None
    if off >= len(payload):
        return None
    return payload[off] & 0x1F


@dataclasses.dataclass
class Frame55CC:
    channel: int
    payload: bytes


@dataclasses.dataclass
class DumlPacket:
    src: int
    dst: int
    seq: int
    cmd_type: int
    cmd_set: int
    cmd_id: int
    payload: bytes
    version: int

    @property
    def global_cmd_id(self) -> int:
        """SquirrelCast's command-name table uses cmdSet * 256 + wire cmdId."""
        return (self.cmd_set << 8) | self.cmd_id


@dataclasses.dataclass(frozen=True)
class UsbInEndpoint:
    interface: int
    endpoint: int

    @property
    def label(self) -> str:
        return f"if{self.interface}:0x{self.endpoint:02x}"


class Frame55CCParser:
    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, chunk: bytes) -> List[Frame55CC]:
        self._buf.extend(chunk)
        out: List[Frame55CC] = []

        while True:
            magic_idx = self._buf.find(FRAME_MAGIC)
            if magic_idx < 0:
                if len(self._buf) > 2:
                    del self._buf[:-2]
                break

            if magic_idx > 0:
                del self._buf[:magic_idx]

            if len(self._buf) < 8:
                break

            channel = self._buf[2] | (self._buf[3] << 8)
            length = self._buf[4] | (self._buf[5] << 8)

            if self._buf[6] != 0 or self._buf[7] != 0:
                del self._buf[:2]
                continue

            total = 8 + length
            if len(self._buf) < total:
                break

            payload = bytes(self._buf[8:total])
            out.append(Frame55CC(channel=channel, payload=payload))
            del self._buf[:total]

        return out


@dataclasses.dataclass
class ChannelStats:
    frames: int = 0
    bytes: int = 0
    annexb_hits: int = 0
    nal_types: collections.Counter = dataclasses.field(default_factory=collections.Counter)
    last_seen: float = 0.0

    def score(self) -> float:
        if self.frames == 0:
            return 0.0
        nal_bonus = sum(self.nal_types.get(t, 0) for t in (1, 5, 6, 7, 8))
        return (self.annexb_hits * 10.0) + nal_bonus + (self.bytes / max(self.frames, 1) / 1024.0)


class VideoChannelDetector:
    def __init__(self) -> None:
        self.stats: Dict[int, ChannelStats] = collections.defaultdict(ChannelStats)
        self.locked_channel: Optional[int] = None

    def observe(self, frame: Frame55CC) -> None:
        st = self.stats[frame.channel]
        st.frames += 1
        st.bytes += len(frame.payload)
        st.last_seen = time.time()

        positions = find_annexb_positions(frame.payload)
        if positions:
            st.annexb_hits += len(positions)
            for pos in positions[:4]:
                nal = nal_type_from_annexb(frame.payload, pos)
                if nal is not None:
                    st.nal_types[nal] += 1

        best_channel, best_score = self.best_channel()
        if best_score >= 20.0:
            self.locked_channel = best_channel

    def best_channel(self) -> Tuple[Optional[int], float]:
        best_channel: Optional[int] = None
        best_score = -1.0
        for channel, stats in self.stats.items():
            score = stats.score()
            if score > best_score:
                best_channel = channel
                best_score = score
        return best_channel, best_score

    def dump_summary(self) -> str:
        items = []
        for channel, st in sorted(self.stats.items()):
            items.append(
                f"chan=0x{channel:04x} frames={st.frames} bytes={st.bytes} "
                f"annexb={st.annexb_hits} nal={dict(st.nal_types)} score={st.score():.1f}"
            )
        return "\n".join(items)


class DumlHelper:
    def __init__(self, tx_channel: int = 0x5749) -> None:
        self.tx_channel = tx_channel
        self.seq = 1

    @staticmethod
    def crc16_dji(data: bytes, initial: int = 13970) -> int:
        value = initial & 0xFFFF
        for byte in data:
            value ^= byte & 0xFF
            for _ in range(8):
                if value & 1:
                    value = (value >> 1) ^ 33800
                else:
                    value >>= 1
        return value & 0xFFFF

    @staticmethod
    def crc8_dji(data: bytes, initial: int = 119) -> int:
        value = initial & 0xFF
        for byte in data:
            value ^= byte & 0xFF
            for _ in range(8):
                if value & 1:
                    value = (value >> 1) ^ 140
                else:
                    value >>= 1
        return value & 0xFF

    @staticmethod
    def normalize_wire_cmd_id(cmd_set: int, cmd_id: int) -> int:
        """Accept either wire cmdId (0..255) or SquirrelCast global cmd id.

        SquirrelCast labels commands as cmdSet * 256 + wireCmdId. For example:
        - cmdSet=2, global 651  -> wire 139
        - cmdSet=9, global 2356 -> wire 52
        - cmdSet=9, global 2360 -> wire 56
        - cmdSet=9, global 2361 -> wire 57
        """
        if 0 <= cmd_id <= 0xFF:
            return cmd_id
        expected_base = (cmd_set & 0xFF) << 8
        wire = cmd_id - expected_base
        if 0 <= wire <= 0xFF:
            return wire
        raise ValueError(
            f"cmd_id {cmd_id} is neither a wire cmdId nor global id for cmdSet={cmd_set}"
        )

    def wrap_55cc(self, payload: bytes, channel: Optional[int] = None) -> bytes:
        chan = self.tx_channel if channel is None else channel
        return FRAME_MAGIC + struct.pack("<HH", chan, len(payload)) + b"\x00\x00" + payload

    def build_duml_payload(
        self,
        cmd_type: int,
        cmd_set: int,
        cmd_id: int,
        payload: bytes = b"",
        src: int = 2,
        dst: int = 27,
        seq: Optional[int] = None,
        version: int = 1,
        prepend_len: bool = False,
    ) -> bytes:
        if seq is None:
            self.seq = (self.seq + 1) & 0xFFFF
            seq = self.seq

        if prepend_len:
            if len(payload) > 0xFF:
                raise ValueError("prepend_len only supports payload <= 255 bytes")
            payload = bytes([len(payload) & 0xFF]) + payload

        total_len = len(payload) + 13
        if total_len > 1023:
            raise ValueError(f"DUML length {total_len} exceeds 10-bit max")

        header0 = 0x55
        header1 = total_len & 0xFF
        header2 = (((total_len >> 8) & 0x03) | ((version & 0x3F) << 2)) & 0xFF
        header_crc = self.crc8_dji(bytes([header0, header1, header2]))

        packet = bytearray(total_len)
        packet[0] = header0
        packet[1] = header1
        packet[2] = header2
        packet[3] = header_crc
        packet[4] = src & 0xFF
        packet[5] = dst & 0xFF
        packet[6] = (seq >> 8) & 0xFF
        packet[7] = seq & 0xFF
        packet[8] = cmd_type & 0xFF
        packet[9] = cmd_set & 0xFF
        packet[10] = self.normalize_wire_cmd_id(cmd_set, cmd_id)
        packet[11:11 + len(payload)] = payload

        crc = self.crc16_dji(packet[:-2])
        packet[-2] = crc & 0xFF
        packet[-1] = (crc >> 8) & 0xFF
        return bytes(packet)

    def build_and_wrap(self, **kwargs) -> bytes:
        return self.wrap_55cc(self.build_duml_payload(**kwargs))

    @classmethod
    def try_parse_duml(cls, packet: bytes) -> Optional[DumlPacket]:
        if len(packet) < 13 or packet[0] != 0x55:
            return None
        total_len = packet[1] | ((packet[2] & 0x03) << 8)
        version = (packet[2] >> 2) & 0x3F
        if total_len != len(packet):
            return None
        if cls.crc8_dji(packet[:3]) != packet[3]:
            return None
        crc_expected = cls.crc16_dji(packet[:-2])
        crc_packet = packet[-2] | (packet[-1] << 8)
        if crc_expected != crc_packet:
            return None
        return DumlPacket(
            src=packet[4],
            dst=packet[5],
            seq=(packet[6] << 8) | packet[7],
            cmd_type=packet[8],
            cmd_set=packet[9],
            cmd_id=packet[10],
            payload=packet[11:-2],
            version=version,
        )


class TriggerReplay:
    def __init__(self, transport: "UsbTransport", period_s: float = 1.0) -> None:
        self.transport = transport
        self.period_s = period_s
        self.frames = [DJI_TRIGGER_FRAME_1, DJI_TRIGGER_FRAME_2]
        self.next_deadline = 0.0

    def maybe_send(self, now: float) -> None:
        if now < self.next_deadline:
            return
        for frame in self.frames:
            written = self.transport.write(frame)
            if written:
                LOG.debug("Replayed trigger frame bytes=%d hex=%s", written, frame.hex())
        self.next_deadline = now + self.period_s


class PeriodicDumlSender:
    def __init__(
        self,
        transport: "UsbTransport",
        helper: DumlHelper,
        packet_kwargs: Dict[str, object],
        period_s: float,
        wrap_55cc: bool = False,
    ) -> None:
        self.transport = transport
        self.helper = helper
        self.packet_kwargs = dict(packet_kwargs)
        self.period_s = period_s
        self.wrap_55cc = wrap_55cc
        self.next_deadline = 0.0

    def maybe_send(self, now: float) -> None:
        if now < self.next_deadline:
            return
        packet = self.helper.build_duml_payload(**self.packet_kwargs)
        if self.wrap_55cc:
            packet = self.helper.wrap_55cc(packet)
        written = self.transport.write(packet)
        wire_cmd_id = DumlHelper.normalize_wire_cmd_id(
            int(self.packet_kwargs["cmd_set"]),
            int(self.packet_kwargs["cmd_id"]),
        )
        LOG.info(
            "probe_tx bytes=%d wrap_55cc=%s cmd_type=0x%02x cmd_set=0x%02x cmd_id=%d wire_cmd_id=0x%02x src=%d dst=%d payload=%s",
            written,
            self.wrap_55cc,
            int(self.packet_kwargs["cmd_type"]),
            int(self.packet_kwargs["cmd_set"]),
            int(self.packet_kwargs["cmd_id"]),
            wire_cmd_id,
            int(self.packet_kwargs["src"]),
            int(self.packet_kwargs["dst"]),
            bytes(self.packet_kwargs["payload"]).hex(),
        )
        self.next_deadline = now + self.period_s


class UdpAnnexBSender:
    def __init__(self, host: str, port: int, mtu_payload: int = 1300) -> None:
        self.addr = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
        self.mtu_payload = mtu_payload

    def send_annexb(self, payload: bytes) -> None:
        if len(payload) <= self.mtu_payload:
            self.sock.sendto(payload, self.addr)
            return

        start_positions = find_annexb_positions(payload)
        if not start_positions:
            for off in range(0, len(payload), self.mtu_payload):
                self.sock.sendto(payload[off:off + self.mtu_payload], self.addr)
            return

        boundaries = start_positions + [len(payload)]
        for i in range(len(start_positions)):
            start = boundaries[i]
            end = boundaries[i + 1]
            nal = payload[start:end]
            if len(nal) <= self.mtu_payload:
                self.sock.sendto(nal, self.addr)
                continue
            for off in range(0, len(nal), self.mtu_payload):
                self.sock.sendto(nal[off:off + self.mtu_payload], self.addr)


class UsbTransport:
    def __init__(
        self,
        vid: int,
        pid: int,
        interface: int,
        ep_in: Optional[int],
        ep_out: Optional[int],
        extra_inputs: Optional[Sequence[UsbInEndpoint]] = None,
        read_size: int = 16384,
        timeout_ms: int = 100,
    ) -> None:
        self.vid = vid
        self.pid = pid
        self.interface = interface
        self.ep_in = ep_in
        self.ep_out = ep_out
        self.extra_inputs = list(extra_inputs or [])
        self.read_size = read_size
        self.timeout_ms = timeout_ms
        self.dev = None
        self.inputs: List[UsbInEndpoint] = []

    def open(self) -> None:
        if usb is None:
            raise RuntimeError("pyusb is not installed")

        dev = usb.core.find(idVendor=self.vid, idProduct=self.pid)
        if dev is None:
            raise RuntimeError(f"USB device {self.vid:04x}:{self.pid:04x} not found")

        self.dev = dev
        try:
            if dev.is_kernel_driver_active(self.interface):
                dev.detach_kernel_driver(self.interface)
        except (NotImplementedError, usb.core.USBError):
            pass

        try:
            active = dev.get_active_configuration()
        except usb.core.USBError:
            active = None

        try:
            if active is None:
                dev.set_configuration()
        except usb.core.USBError as exc:
            # Composite gadgets may already be configured and reject a second set_configuration().
            if getattr(exc, "errno", None) != 16:
                raise
            LOG.info("USB device already configured; continuing without set_configuration()")
        interfaces_to_claim = {self.interface}
        if self.ep_in is not None:
            self.inputs.append(UsbInEndpoint(self.interface, self.ep_in))
        self.inputs.extend(self.extra_inputs)
        interfaces_to_claim.update(item.interface for item in self.inputs)

        for interface in sorted(interfaces_to_claim):
            usb.util.claim_interface(dev, interface)
        LOG.info(
            "Opened USB device %04x:%04x tx_if=%d ep_out=%s inputs=%s",
            self.vid,
            self.pid,
            self.interface,
            f"0x{self.ep_out:02x}" if self.ep_out is not None else "none",
            [item.label for item in self.inputs],
        )

    def read_from(self, endpoint: int) -> bytes:
        assert self.dev is not None
        try:
            data = self.dev.read(endpoint, self.read_size, timeout=self.timeout_ms)
            return bytes(data)
        except usb.core.USBTimeoutError:
            return b""

    def poll_inputs(self) -> List[Tuple[UsbInEndpoint, bytes]]:
        out: List[Tuple[UsbInEndpoint, bytes]] = []
        for item in self.inputs:
            chunk = self.read_from(item.endpoint)
            if chunk:
                out.append((item, chunk))
        return out

    def write(self, data: bytes) -> int:
        assert self.dev is not None
        if self.ep_out is None:
            raise RuntimeError("No OUT endpoint configured")
        try:
            return int(self.dev.write(self.ep_out, data, timeout=self.timeout_ms))
        except usb.core.USBTimeoutError:
            LOG.warning(
                "USB write timed out ep_out=0x%02x len=%d timeout_ms=%d",
                self.ep_out,
                len(data),
                self.timeout_ms,
            )
            return 0


def parse_hex_int(value: str) -> int:
    return int(value, 0)


def parse_input_spec(value: str) -> UsbInEndpoint:
    try:
        interface_str, endpoint_str = value.split(":", 1)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("expected IFACE:ENDPOINT, e.g. 4:0x85") from exc
    return UsbInEndpoint(interface=int(interface_str, 0), endpoint=parse_hex_int(endpoint_str))


def parse_hex_bytes(value: str) -> bytes:
    text = value.strip().replace(" ", "")
    if not text:
        return b""
    return bytes.fromhex(text)


def main(argv: Optional[Iterable[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="DJI Goggles 3 USB -> UDP H.264 bridge")
    ap.add_argument("--vid", type=parse_hex_int, required=True, help="USB VID, e.g. 0x2ca3")
    ap.add_argument("--pid", type=parse_hex_int, required=True, help="USB PID")
    ap.add_argument("--interface", type=int, required=True, help="USB interface number")
    ap.add_argument("--ep-in", type=parse_hex_int, default=None, help="Primary bulk IN endpoint, e.g. 0x81")
    ap.add_argument("--ep-out", type=parse_hex_int, default=None, help="Bulk OUT endpoint, e.g. 0x02")
    ap.add_argument(
        "--extra-in",
        action="append",
        type=parse_input_spec,
        default=[],
        help="Additional IN endpoint as IFACE:ENDPOINT, e.g. 5:0x86. Repeat for multi-sniff.",
    )
    ap.add_argument("--dest-ip", default="192.168.2.2", help="Pi 5 IP address")
    ap.add_argument("--dest-port", type=int, default=5600, help="UDP destination port")
    ap.add_argument("--usb-timeout-ms", type=int, default=100, help="USB read/write timeout in milliseconds")
    ap.add_argument("--send-format-cmd", action="store_true", help="Send Camera Video Format Set [10,6,0]")
    ap.add_argument(
        "--camera-dst",
        type=parse_hex_int,
        default=1,
        help="DUML dst for Camera cmdSet=2 helpers; APK builder uses dst=1",
    )
    ap.add_argument("--replay-trigger", action="store_true", help="Replay the two APK startup frames every second")
    ap.add_argument("--trigger-period", type=float, default=1.0, help="Replay period for --replay-trigger")
    ap.add_argument("--probe-cmd-set", type=parse_hex_int, help="Arbitrary DUML cmdSet to send")
    ap.add_argument(
        "--probe-cmd-id",
        type=parse_hex_int,
        help="DUML cmdId; accepts wire id 0..255 or SquirrelCast global id, e.g. 2360 with cmdSet=9",
    )
    ap.add_argument("--probe-cmd-type", type=parse_hex_int, default=0x40, help="Arbitrary DUML cmdType")
    ap.add_argument("--probe-src", type=parse_hex_int, default=2, help="DUML src for probe command")
    ap.add_argument("--probe-dst", type=parse_hex_int, default=27, help="DUML dst for probe command")
    ap.add_argument("--probe-version", type=parse_hex_int, default=1, help="DUML version for probe command")
    ap.add_argument("--probe-seq", type=parse_hex_int, default=None, help="Optional fixed DUML seq")
    ap.add_argument("--probe-payload-hex", type=parse_hex_bytes, default=b"", help="Probe payload as hex")
    ap.add_argument("--probe-prepend-len", action="store_true", help="Prepend 1-byte payload length in probe command")
    ap.add_argument("--probe-period", type=float, default=0.0, help="Seconds between probe sends; 0 disables")
    ap.add_argument("--probe-wrap-55cc", action="store_true", help="Wrap probe DUML inside outer 55CC transport")
    ap.add_argument("--log-every", type=float, default=2.0, help="Seconds between channel summaries")
    ap.add_argument("--dump-raw", action="store_true", help="Log non-55CC raw input chunks for endpoint discovery")
    ap.add_argument("--raw-hex-limit", type=int, default=64, help="Max raw bytes to hex-dump per chunk")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    transport = UsbTransport(
        vid=args.vid,
        pid=args.pid,
        interface=args.interface,
        ep_in=args.ep_in,
        ep_out=args.ep_out,
        extra_inputs=args.extra_in,
        timeout_ms=args.usb_timeout_ms,
    )
    parsers: Dict[str, Frame55CCParser] = {}
    detector = VideoChannelDetector()
    sender = UdpAnnexBSender(args.dest_ip, args.dest_port)
    duml = DumlHelper()
    trigger = None
    probe_sender = None

    transport.open()
    for item in transport.inputs:
        parsers[item.label] = Frame55CCParser()

    if args.replay_trigger:
        if args.ep_out is None:
            raise RuntimeError("--replay-trigger requires --ep-out")
        trigger = TriggerReplay(transport, period_s=args.trigger_period)
        LOG.info(
            "Trigger replay enabled: channel=0x5749 period=%.3fs frame_lengths=%s",
            args.trigger_period,
            [len(DJI_TRIGGER_FRAME_1), len(DJI_TRIGGER_FRAME_2)],
        )

    if (args.probe_cmd_set is None) != (args.probe_cmd_id is None):
        raise RuntimeError("--probe-cmd-set and --probe-cmd-id must be used together")
    if args.probe_period > 0.0 and args.probe_cmd_set is None:
        raise RuntimeError("--probe-period requires --probe-cmd-set and --probe-cmd-id")
    if args.probe_cmd_set is not None:
        wire_probe_cmd_id = DumlHelper.normalize_wire_cmd_id(args.probe_cmd_set, args.probe_cmd_id)
        packet_kwargs: Dict[str, object] = {
            "cmd_type": args.probe_cmd_type,
            "cmd_set": args.probe_cmd_set,
            "cmd_id": args.probe_cmd_id,
            "payload": args.probe_payload_hex,
            "src": args.probe_src,
            "dst": args.probe_dst,
            "seq": args.probe_seq,
            "version": args.probe_version,
            "prepend_len": args.probe_prepend_len,
        }
        if args.probe_period > 0.0:
            probe_sender = PeriodicDumlSender(
                transport=transport,
                helper=duml,
                packet_kwargs=packet_kwargs,
                period_s=args.probe_period,
                wrap_55cc=args.probe_wrap_55cc,
            )
            LOG.info(
                "Probe sender enabled: period=%.3fs cmd_type=0x%02x cmd_set=0x%02x cmd_id=%d wire_cmd_id=0x%02x src=%d dst=%d payload=%s wrap_55cc=%s",
                args.probe_period,
                args.probe_cmd_type,
                args.probe_cmd_set,
                args.probe_cmd_id,
                wire_probe_cmd_id,
                args.probe_src,
                args.probe_dst,
                args.probe_payload_hex.hex(),
                args.probe_wrap_55cc,
            )
        else:
            packet = duml.build_duml_payload(**packet_kwargs)
            if args.probe_wrap_55cc:
                packet = duml.wrap_55cc(packet)
            written = transport.write(packet)
            LOG.info(
                "Sent one-shot probe bytes=%d cmd_set=0x%02x cmd_id=%d wire_cmd_id=0x%02x payload=%s",
                written,
                args.probe_cmd_set,
                args.probe_cmd_id,
                wire_probe_cmd_id,
                args.probe_payload_hex.hex(),
            )

    if args.send_format_cmd:
        if args.ep_out is None:
            raise RuntimeError("--send-format-cmd requires --ep-out")
        known_payload = bytes([10, 6, 0])
        frame = duml.build_and_wrap(
            cmd_type=64,
            cmd_set=2,
            cmd_id=24,
            payload=known_payload,
            src=2,
            dst=args.camera_dst,
            version=0,
            prepend_len=False,
        )
        written = transport.write(frame)
        LOG.info(
            "Sent Camera Video Format Set, bytes=%d dst=%d payload=%s",
            written,
            args.camera_dst,
            known_payload.hex(),
        )

    last_log = time.time()
    while True:
        now = time.time()
        if trigger is not None:
            trigger.maybe_send(now)
        if probe_sender is not None:
            probe_sender.maybe_send(now)

        reads = transport.poll_inputs()
        if not reads:
            if now - last_log >= args.log_every:
                best_channel, best_score = detector.best_channel()
                LOG.info("best_channel=%s best_score=%.1f\n%s", f"0x{best_channel:04x}" if best_channel else None, best_score, detector.dump_summary())
                last_log = now
            continue

        for input_ep, chunk in reads:
            parser = parsers[input_ep.label]
            frames = parser.feed(chunk)
            if not frames and args.dump_raw:
                duml = DumlHelper.try_parse_duml(chunk)
                if duml is not None:
                    payload_preview = duml.payload[: args.raw_hex_limit].hex()
                    ascii_preview = "".join(chr(b) if 32 <= b < 127 else "." for b in duml.payload[:32])
                    LOG.info(
                        "duml endpoint=%s src=%d dst=%d seq=%d type=0x%02x set=0x%02x id=0x%02x global_id=%d ver=%d payload_len=%d payload_hex=%s payload_ascii=%s",
                        input_ep.label,
                        duml.src,
                        duml.dst,
                        duml.seq,
                        duml.cmd_type,
                        duml.cmd_set,
                        duml.cmd_id,
                        duml.global_cmd_id,
                        duml.version,
                        len(duml.payload),
                        payload_preview,
                        ascii_preview,
                    )
                else:
                    LOG.info(
                        "raw_chunk endpoint=%s len=%d hex=%s",
                        input_ep.label,
                        len(chunk),
                        chunk[: args.raw_hex_limit].hex(),
                    )
            for frame in frames:
                LOG.debug(
                    "55cc endpoint=%s channel=0x%04x payload_len=%d",
                    input_ep.label,
                    frame.channel,
                    len(frame.payload),
                )
                detector.observe(frame)
                if detector.locked_channel == frame.channel:
                    if find_annexb_positions(frame.payload):
                        sender.send_annexb(frame.payload)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        raise SystemExit(130)
