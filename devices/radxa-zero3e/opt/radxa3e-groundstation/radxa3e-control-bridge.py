#!/usr/bin/env python3
import logging
import os
import select
import socket
import time

import serial


SERIAL_PORT = os.getenv("SERIAL_PORT", "/dev/ttyS0")
BAUDRATE = int(os.getenv("BAUDRATE", "420000"))
CAMERA_IP = os.getenv("CAMERA_IP", "192.168.1.50")
CAMERA_PORT = int(os.getenv("CAMERA_PORT", "5000"))
LISTEN_IP = os.getenv("LISTEN_IP", "0.0.0.0")
LISTEN_PORT = int(os.getenv("LISTEN_PORT", "5000"))
READ_CHUNK = int(os.getenv("READ_CHUNK", "64"))
SELECT_TIMEOUT = float(os.getenv("SELECT_TIMEOUT", "0.001"))
UDP_READ_CHUNK = int(os.getenv("UDP_READ_CHUNK", "1024"))
FORWARD_UDP_TO_SERIAL = os.getenv("FORWARD_UDP_TO_SERIAL", "0").strip().lower() in ("1", "true", "yes", "on")


logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("radxa3e_control_bridge")


def init_serial() -> serial.Serial:
    while True:
        try:
            ser = serial.Serial(
                port=SERIAL_PORT,
                baudrate=BAUDRATE,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.001,
            )
            log.info("Serial ready on %s @ %d", SERIAL_PORT, BAUDRATE)
            return ser
        except Exception as exc:
            log.error("Serial init failed: %s", exc)
            time.sleep(1.0)


def init_udp() -> socket.socket:
    while True:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((LISTEN_IP, LISTEN_PORT))
            sock.setblocking(False)
            bound_ip, bound_port = sock.getsockname()
            log.info("UDP ready on %s:%d", bound_ip, bound_port)
            return sock
        except Exception as exc:
            log.error("UDP init failed: %s", exc)
            time.sleep(1.0)


def main() -> int:
    ser = init_serial()
    udp = init_udp()
    serial_write_buffer = bytearray()

    while True:
        try:
            readable = [udp]
            writable = []
            if ser and ser.is_open:
                readable.append(ser)
                if serial_write_buffer:
                    writable.append(ser)

            r, w, _ = select.select(readable, writable, [], SELECT_TIMEOUT)

            if ser in r:
                data = ser.read(READ_CHUNK)
                if data:
                    udp.sendto(data, (CAMERA_IP, CAMERA_PORT))

            if udp in r:
                data, _addr = udp.recvfrom(UDP_READ_CHUNK)
                if data and FORWARD_UDP_TO_SERIAL:
                    serial_write_buffer.extend(data)

            if ser in w and serial_write_buffer:
                written = ser.write(serial_write_buffer)
                del serial_write_buffer[:written]

        except serial.SerialException as exc:
            log.error("Serial error: %s", exc)
            try:
                ser.close()
            except Exception:
                pass
            ser = init_serial()
        except OSError as exc:
            log.error("Socket error: %s", exc)
            try:
                udp.close()
            except Exception:
                pass
            udp = init_udp()
        except Exception as exc:
            log.error("Unexpected error: %s", exc, exc_info=True)
            time.sleep(0.5)


if __name__ == "__main__":
    raise SystemExit(main())
