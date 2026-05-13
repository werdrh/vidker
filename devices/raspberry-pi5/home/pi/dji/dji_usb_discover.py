#!/usr/bin/env python3
"""List USB devices and endpoint candidates for DJI Goggles userspace probing."""

from __future__ import annotations

import sys

try:
    import usb.core
    import usb.util
except ImportError:
    print("pyusb is not installed. Install with: sudo apt install -y python3-usb", file=sys.stderr)
    raise SystemExit(2)


def direction_name(address: int) -> str:
    return "IN" if usb.util.endpoint_direction(address) == usb.util.ENDPOINT_IN else "OUT"


def transfer_name(attributes: int) -> str:
    kind = usb.util.endpoint_type(attributes)
    if kind == usb.util.ENDPOINT_TYPE_BULK:
        return "bulk"
    if kind == usb.util.ENDPOINT_TYPE_INTR:
        return "interrupt"
    if kind == usb.util.ENDPOINT_TYPE_ISO:
        return "iso"
    if kind == usb.util.ENDPOINT_TYPE_CTRL:
        return "control"
    return f"type{kind}"


def safe_get_string(dev: usb.core.Device, index: int) -> str:
    if not index:
        return ""
    try:
        return usb.util.get_string(dev, index) or ""
    except Exception:
        return ""


def main() -> int:
    devices = list(usb.core.find(find_all=True))
    if not devices:
        print("No USB devices found")
        return 1

    for dev in devices:
        vid = int(dev.idVendor)
        pid = int(dev.idProduct)
        product = safe_get_string(dev, dev.iProduct)
        manufacturer = safe_get_string(dev, dev.iManufacturer)
        marker = " DJI?" if "dji" in f"{manufacturer} {product}".lower() or vid == 0x2CA3 else ""
        print(f"\n{vid:04x}:{pid:04x}{marker} manufacturer={manufacturer!r} product={product!r}")
        try:
            for cfg in dev:
                print(f"  config={cfg.bConfigurationValue}")
                for intf in cfg:
                    num = intf.bInterfaceNumber
                    alt = intf.bAlternateSetting
                    cls = intf.bInterfaceClass
                    sub = intf.bInterfaceSubClass
                    proto = intf.bInterfaceProtocol
                    print(f"    interface={num} alt={alt} class=0x{cls:02x} sub=0x{sub:02x} proto=0x{proto:02x}")
                    for ep in intf:
                        addr = ep.bEndpointAddress
                        print(
                            f"      ep=0x{addr:02x} {direction_name(addr):3s} "
                            f"{transfer_name(ep.bmAttributes):9s} maxpkt={ep.wMaxPacketSize}"
                        )
        except Exception as exc:
            print(f"  unable to inspect descriptors: {exc}")

    print("\nFor the bridge, pick one bulk IN endpoint for --ep-in and one bulk OUT for --ep-out.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
