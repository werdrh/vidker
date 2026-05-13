#!/usr/bin/env python3
import argparse
import socket


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=5601)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))

    while True:
        data, addr = sock.recvfrom(2048)
        if not data:
            continue
        sock.sendto(data, addr)


if __name__ == "__main__":
    main()
