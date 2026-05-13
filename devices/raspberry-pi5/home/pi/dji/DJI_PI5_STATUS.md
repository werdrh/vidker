# DJI Goggles 3 on Raspberry Pi 5 status

Date: 2026-05-08

## Current hardware mode

Raspberry Pi 5 is connected to DJI Goggles 3 through Pi USB-A host port.

Linux enumerates the goggles as:

```text
2ca3:0020 DJI Technology Co., Ltd. Goggles3-753XN41702CPB4
```

The device exposes:

- interface 0/1: RNDIS/CDC network pair
- interface 2: mass-storage style interface
- interfaces 3..7: vendor-specific bulk pairs

Important: SquirrelCast does not use this exact Pi USB-A host mode. The APK uses Android `UsbAccessory`:

```java
UsbManager.openAccessory(UsbAccessory)
FileInputStream(openAccessory.getFileDescriptor())
FileOutputStream(openAccessory.getFileDescriptor())
```

That means the working phone path is Android accessory mode, where the goggles side behaves as USB host/accessory-controller and the Android device exposes the accessory file descriptor to the app. Pi5 USB-A host mode sees a different composite device mode.

## What works

- Pi5 USB power setting survived reboot: `usb_max_current_enable=1`.
- Goggles enumerate reliably after reboot.
- Vendor interface 4 (`OUT 0x04`, `IN 0x85`) accepts writes and emits a periodic DUML-like heartbeat:

```text
src=188 dst=42 type=0x40 cmdSet=0 cmdId=0x81 payload_ascii=ZV902
```

- RNDIS `usb0` can be restored after libusb detach by running:

```bash
./pi5_dji_restore_rndis.sh
```

## What did not produce H.264 yet

- Passive reads on vendor IN endpoints `0x84..0x88`.
- SquirrelCast trigger frame replay on OUT endpoints `0x01`, `0x03`, `0x04`, `0x05`, `0x06`, `0x07`.
- DUML probe `cmdSet=9 cmdId=2357` in raw and `55CC`-wrapped forms to `dst=27/40/60`.
- Camera video format command `cmdSet=2 cmdId=24 payload=0a0600` in raw and `55CC`-wrapped forms.

All tests only showed the same `ZV902` heartbeat and no Annex B H.264 start codes.

## Working conclusion

For the final no-phone solution, one of these is likely needed:

1. A board/port that can act as a USB device/gadget and emulate the Android accessory endpoint expected by Goggles.
2. A correct init sequence for the Pi USB-A host composite mode, if DJI also supports liveview there.
3. A capture of the exact Android accessory traffic from a real phone session, then replay/emulation on a USB-gadget-capable Linux device.

Pi5 USB-A host mode alone is not yet enough evidence for live H.264. It is a different mode from the proven SquirrelCast phone path.
