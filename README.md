# vidker recovery repo

This repository is a safe recovery snapshot for the FPV ground-station setup.

It stores the active service files, scripts, boot overlays, and restore tooling needed to rebuild the boards after SD-card or image damage.

## What is included

- `devices/radxa-zero3e/` - current Radxa Zero 3E ground-station files collected from the live board.
- `devices/raspberry-pi5/` - current Raspberry Pi 5 bridge files collected from the live board.
- `scripts/restore_radxa_zero3e.sh` - restore script to run on a fresh/repaired Radxa image.
- `scripts/restore_raspberry_pi5.sh` - restore script to run on a fresh/repaired Pi 5 image.
- `scripts/collect_radxa_zero3e.py` - collector script to refresh this repo from the live Radxa.
- `devices/radxa-zero3e/system-state.txt` - diagnostic snapshot from the board at collection time.

## Radxa Source Modes

The Radxa mode button cycles through:

- `camera` - normal OpenIPC/optical camera mode, static camera side address.
- `pi-local` - Raspberry Pi DJI bridge over direct LAN.
- `pi-internet` - Raspberry Pi DJI bridge over the internet/Tailscale path.
- `pi-easycap` - Raspberry Pi EasyCAP capture card mode. Radxa first tries direct LAN to the Pi, then falls back to Tailscale. The Pi source-mode agent starts only the EasyCAP H.264/RTP sender and stops the DJI sender so they do not fight for UDP `5600`.

## What is intentionally not included

- Private SSH keys.
- Tailscale auth keys.
- WireGuard private keys.
- FPV Mesh provision files such as `/etc/fpvmesh/provision.json`.
- Password hashes such as `/etc/shadow`.
- Video recordings or large captures.

## Quick restore on Radxa

On the Radxa board:

```sh
sudo apt-get update
sudo apt-get install -y git openssh-server network-manager tailscale libgpiod-tools i2c-tools
git clone https://github.com/werdrh/vidker.git
cd vidker
sudo ./scripts/restore_radxa_zero3e.sh --apply-now
sudo reboot
```

The restore script backs up existing target files to `/root/vidker-restore-backup-YYYYmmdd-HHMMSS` before copying anything.

## Quick restore on Raspberry Pi 5

On the Pi 5:

```sh
sudo apt-get update
sudo apt-get install -y git openssh-server tailscale python3
git clone https://github.com/werdrh/vidker.git
cd vidker
sudo ./scripts/restore_raspberry_pi5.sh --apply-now
sudo reboot
```

The Pi restore script backs up replaced files to `/root/vidker-pi5-restore-backup-YYYYmmdd-HHMMSS`.

## Refresh snapshot from PC

From the Windows/Codex workspace:

```powershell
$env:RADXA_PASSWORD="your-password"
python .\vidker\scripts\collect_radxa_zero3e.py --host 100.80.47.96 --user rock
```

Then review and commit:

```powershell
git -C .\vidker status
git -C .\vidker add .
git -C .\vidker commit -m "Update Radxa recovery snapshot"
git -C .\vidker push
```
