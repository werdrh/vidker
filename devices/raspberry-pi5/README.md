# Raspberry Pi 5 snapshot

This board still needs a fresh collection pass.

The last known role of the Pi 5 in this project:

- Connects to DJI Goggles over USB gadget/accessory work.
- Extracts/transports DJI liveview H.264 toward the Radxa ground station.
- Receives CRSF/control over the network and forwards it to the ELRS TX UART.
- Can work over direct LAN or internet tunnel, depending on mode.

Known prior addresses:

- Tailscale: `100.91.223.27`
- LAN: `192.168.1.179`

Do not store Tailscale keys, WireGuard keys, FPV Mesh provision files, or password hashes here.
