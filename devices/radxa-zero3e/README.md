# Radxa Zero 3E ground station snapshot

Collected from the live board `radxa-zero3` on `2026-05-13`.

Current role:

- HDMI ground-station receiver via PixelPilot.
- RTP/H.264 receive on UDP `5600`.
- CRSF UART bridge on `/dev/ttyS4` at `420000`.
- Source modes: `camera`, `pi-local`, `pi-internet`.
- Recording to external USB media at `/media/recordings`.
- OSD, signal-loss splash, record button, mode button, power button, guard/watchdog.

Important pin assignments:

- Record button: `PIN_32`, pull-up, falling edge.
- Mode button: `PIN_26`, pull-up, active low.
- Power button: `PIN_18`, pull-up, active low.
- CRSF UART: `/dev/ttyS4`, 3.3 V logic, `420000` baud.

Important boot overlays:

- `rk3568-uart4-m1.dtbo`
- `rk3568-i2c4-m0.dtbo`

The snapshot includes actual active files only. Old `.bak` experiment files from the board are not included.
