#!/usr/bin/env python3
import argparse
import math
import os
import socket
import struct
import subprocess
import time

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402


MAGIC = b"EJPG"
HEADER = struct.Struct("!4sIHHI")
MAX_PAYLOAD = 1200


def set_controls(device: str) -> None:
    subprocess.run(
        [
            "v4l2-ctl",
            "-d",
            device,
            "--set-ctrl=brightness=26,contrast=140,saturation=150,hue=0,backlight_compensation=0",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def usb_authorized_path(device: str) -> str | None:
    video = os.path.basename(device)
    path = f"/sys/class/video4linux/{video}/device/../../../authorized"
    real = os.path.realpath(path)
    return real if os.path.exists(real) else None


def usb_device_name(device: str) -> str | None:
    video = os.path.basename(device)
    path = f"/sys/class/video4linux/{video}/device/../../.."
    real = os.path.realpath(path)
    return os.path.basename(real) if os.path.exists(real) else None


def pulse_usb(device: str) -> None:
    auth = usb_authorized_path(device)
    devname = usb_device_name(device)
    if not auth:
        print("usb-pulse-skip no-authorized-path", flush=True)
    else:
        try:
            with open(auth, "w", encoding="ascii") as f:
                f.write("0\n")
            time.sleep(1.0)
            with open(auth, "w", encoding="ascii") as f:
                f.write("1\n")
            print(f"usb-pulse {auth}", flush=True)
            time.sleep(2.0)
        except Exception as e:
            print(f"usb-pulse-failed: {e}", flush=True)

    if not devname:
        print("usb-rebind-skip no-device-name", flush=True)
        return

    try:
        with open("/sys/bus/usb/drivers/usb/unbind", "w", encoding="ascii") as f:
            f.write(f"{devname}\n")
        time.sleep(1.0)
        with open("/sys/bus/usb/drivers/usb/bind", "w", encoding="ascii") as f:
            f.write(f"{devname}\n")
        print(f"usb-rebind {devname}", flush=True)
        time.sleep(3.0)
    except Exception as e:
        print(f"usb-rebind-failed: {e}", flush=True)


def build_pipeline(device: str, width: int, height: int, fps: int):
    desc = (
        f"v4l2src device={device} io-mode=mmap do-timestamp=true ! "
        f"image/jpeg,width={width},height={height},framerate={fps}/1 ! "
        "appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
    )
    pipeline = Gst.parse_launch(desc)
    sink = pipeline.get_by_name("sink")
    return pipeline, sink


def sample_to_bytes(sample):
    buf = sample.get_buffer()
    ok, map_info = buf.map(Gst.MapFlags.READ)
    if not ok:
        return None
    try:
        return bytes(map_info.data)
    finally:
        buf.unmap(map_info)


class Sender:
    def __init__(self, dest_ip: str, port: int):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
        self.dest = (dest_ip, port)
        self.frame_id = 0
        self.sent_frames = 0

    def push_frame(self, frame: bytes) -> None:
        total = math.ceil(len(frame) / MAX_PAYLOAD)
        for chunk_idx in range(total):
            off = chunk_idx * MAX_PAYLOAD
            payload = frame[off : off + MAX_PAYLOAD]
            packet = HEADER.pack(MAGIC, self.frame_id, chunk_idx, total, len(frame)) + payload
            self.sock.sendto(packet, self.dest)
        self.frame_id = (self.frame_id + 1) & 0xFFFFFFFF
        self.sent_frames += 1
        if self.sent_frames == 1 or self.sent_frames % 100 == 0:
            print(f"sent-frame={self.sent_frames} bytes={len(frame)}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/video0")
    ap.add_argument("--dest-ip", required=True)
    ap.add_argument("--port", type=int, default=5600)
    ap.add_argument("--width", type=int, default=720)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--fps", type=int, default=25)
    ap.add_argument("--restart-gap-sec", type=float, default=2.0)
    ap.add_argument("--usb-pulse-on-gap", action="store_true")
    args = ap.parse_args()

    Gst.init(None)
    set_controls(args.device)
    print("sender-start", flush=True)
    sender = Sender(args.dest_ip, args.port)

    try:
        while True:
            last_frame_time = time.monotonic()
            pipeline, sink = build_pipeline(args.device, args.width, args.height, args.fps)
            loop = GLib.MainLoop()

            def on_new_sample(appsink):
                nonlocal last_frame_time
                sample = appsink.emit("pull-sample")
                if sample is None:
                    return Gst.FlowReturn.OK
                frame = sample_to_bytes(sample)
                if frame:
                    last_frame_time = time.monotonic()
                    sender.push_frame(frame)
                return Gst.FlowReturn.OK

            def on_bus_message(_, message):
                if message.type == Gst.MessageType.ERROR:
                    err, dbg = message.parse_error()
                    print(f"gst-error: {err}; debug={dbg}", flush=True)
                    loop.quit()
                elif message.type == Gst.MessageType.EOS:
                    print("gst-eos", flush=True)
                    loop.quit()

            def watchdog():
                gap = time.monotonic() - last_frame_time
                if gap > args.restart_gap_sec:
                    print(f"frame-gap={gap:.2f}s restart", flush=True)
                    loop.quit()
                    return False
                return True

            sink.connect("new-sample", on_new_sample)
            bus = pipeline.get_bus()
            bus.add_signal_watch()
            bus.connect("message", on_bus_message)
            GLib.timeout_add(500, watchdog)

            ret = pipeline.set_state(Gst.State.PLAYING)
            print(f"pipeline-state={ret.value_nick}", flush=True)
            loop.run()

            bus.remove_signal_watch()
            pipeline.set_state(Gst.State.NULL)
            if args.usb_pulse_on_gap:
                pulse_usb(args.device)
                set_controls(args.device)
            print("pipeline-restart", flush=True)
            time.sleep(0.5)
    finally:
        print("sender-stop", flush=True)


if __name__ == "__main__":
    main()
