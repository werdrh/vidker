# Raspberry Pi 5 snapshot

Collected from the live board `ground` on `2026-05-13`.

The last known role of the Pi 5 in this project:

- Connects to DJI Goggles over USB gadget/accessory work.
- Extracts/transports DJI liveview H.264 toward the Radxa ground station.
- Receives CRSF/control over the network and forwards it to the ELRS TX UART.
- Can work over direct LAN or internet tunnel, depending on mode.

Known prior addresses:

- Tailscale: `100.91.223.27`
- LAN: `192.168.1.179`

Included areas:

- `/home/pi/dji` DJI USB/gadget bridge scripts and C bridge binary/source.
- `/opt/easycap-rc` EasyCAP/CRSF helper scripts still installed on the Pi.
- `/etc/systemd/system` Pi video/control/link services.
- `/boot/firmware/config.txt` and `/boot/firmware/cmdline.txt`.

Do not store Tailscale keys, WireGuard keys, FPV Mesh provision files, Wi-Fi PSKs, or password hashes here.
