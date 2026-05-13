## SquirrelCast APK findings

Source APK:
- `C:\Users\werdr\Desktop\apk\SquirrelCast.apk`

Primary decompile roots:
- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_squirrel_jadx_out`
- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_tmp_single2`
- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_tmp_a0_simple`
- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_tmp_n0_simple`

### Confirmed transport facts

- App uses Android USB accessory mode.
  - `com.NuclearSquirrel.SquirrelCast.ui.StreamingFragment`
  - `com.NuclearSquirrel.SquirrelCast.usb.DumlShellReceiver`
- DUML builder is in `g2.g0`.
- `g2.g0.a(...)` builds inner DUML packets with:
  - start byte `0x55`
  - length/version field
  - CRC8 over first 3 bytes
  - header fields at bytes 4..10
  - CRC16 at tail

### Confirmed command name map

From `g2.l0`:

- `cmdSet=2, cmdId=24` = `Camera Video Format Set`
- `cmdSet=2, cmdId=25` = `Camera Video Format Get`
- `cmdSet=2, cmdId=651` = `Racing Liveview Format Set`
- `cmdSet=2, cmdId=652` = `Racing Liveview Format Get`
- `cmdSet=9, cmdId=2356` = `HDLnk SDR Liveview Mode Set`
- `cmdSet=9, cmdId=2357` = `HDLnk SDR Liveview Mode Get`
- `cmdSet=9, cmdId=2360` = `HDLnk SDR Set Rate`
- `cmdSet=9, cmdId=2361` = `HDLnk Liveview Config Set`

### Confirmed camera builder for cmd 24

From `g2.c0` and `g2.a0`:

- `cmdSet=2`
- `cmdType=64`
- `src=2`
- `dst=1`
- `prependLen=false`

That is the same camera-path we had already inferred, now confirmed from code.

### Exact payload structure for cmd 24

The set path is:

- `DumlShellReceiver op=camvideoformat`
- `g2.n0`
- `g2.a0.o(...)`
- `g2.c0.a(f3098l, ...)`

`g2.a0.o(...)` builds:

```text
payload = [format_code, fps_code, 0x00]
```

Where:

- `format_code` comes from `g2.a0.f3108v`
- `fps_code` comes from `g2.a0.f3106t`

#### Format code map

- `16:9 FHD` -> `10`
- `16:9 2.7K` -> `45`
- `16:9 UHD/4K` -> `16`
- `4:3 FHD` -> `98`
- `4:3 2.7K` -> `95`
- `4:3 UHD/4K` -> `103`

#### FPS code map

- `30` -> `3`
- `50` -> `5`
- `60` -> `6`
- `100` -> `10`
- `120` -> `7`

#### Confirmed example

- `16:9 FHD 60fps` -> `[10, 6, 0]`

This matches the known working payload.

### Confirmed shell argument syntax for cmd 24

From `g2.n0`:

- op name: `camvideoformat`
- accepted args:
  - `aspect`: `wide`, `widescreen`, `16:9`, `16_9`, `169`, `4:3`, `4_3`, `43`
  - `res` or `resolution`: `fhd`, `1080`, `1080p`, `27k`, `2p7k`, `2_7k`, `2.7k`, `uhd`, `4k`
  - `fps`: integer

### Liveview-related typed data found

These types exist and are likely fed from HDLink DUML replies / param decoding:

- `g2.w0` -> `HdLinkSdrLiveviewRateData(codeRate=float)`
- `g2.x0` -> `HdLinkVtSignalQualityData(quality=int)`
- `g2.y0` -> `HdLinkWlEnvQualityData(channelStatus=int)`

Also:

- `g2.o1` registers `link.liveview_rate`
- `d2.r.r()` reads `link.liveview_rate`

This strongly suggests `2360` or `2358` is decoded into the param key `link.liveview_rate`.

### What is still not fully extracted

Not yet recovered exactly from decompiled code:

- payload structure for `cmdSet=9, cmdId=2356`
- payload structure for `cmdSet=9, cmdId=2360`
- payload structure for `cmdSet=9, cmdId=2361`
- payload structure for `cmdSet=2, cmdId=651`
- exact `src/dst/prependLen` for those HDLink commands

Reason:

- camera path is exposed through `g2.a0` and shell helper `g2.n0`
- HDLink liveview path appears to be hidden behind a param/telemetry layer and the most relevant methods are still partially skipped by JADX in normal decompile

### Best current integration guidance

Already safe to integrate:

- `cmdSet=2, cmdId=24`
- `cmdSet=2, cmdId=25`
- their exact payload mapping above

For HDLink:

- trust the command IDs from `g2.l0`
- keep current Linux probing focused on:
  - `2356`
  - `2357`
  - `2360`
  - `2361`
- correlate with keys like:
  - `link.liveview_rate`
  - `link.signal_quality`
  - `link.env_quality`

## DJI Fly APK cross-check

Source APK:

- `C:\Users\werdr\Desktop\DJI Fly.apk`

Decompile / extraction roots:

- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_dji_fly_jadx_out`
- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_dji_native_extract`
- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_dji_cmd_symbols.txt`
- `C:\Users\werdr\Documents\Codex\2026-04-23-embedded-linux-video-reverse-engineering-engineer\_dji_native_strings_hits.txt`

### APK structure

- APK size is about 678 MB.
- `classes.dex` is only about 2.1 MB.
- Most useful SDK/control logic is in native libraries, especially:
  - `lib/arm64-v8a/libsdk_jni.so`
  - `lib/arm64-v8a/libdatajar.so`
  - `lib/arm64-v8a/libsdk_key_value.so`
  - `lib/arm64-v8a/libsdk_base.so`

### Native command table evidence

`libsdk_jni.so` contains C++ command template symbols that confirm modern DJI Fly still has equivalent command concepts:

- `cmdSet=2, wireCmdId=24` -> `uav_camera_set_video_format_req`
- `cmdSet=2, wireCmdId=9` -> `uav_camera_set_liveview_source_camera_req`
- `cmdSet=8, wireCmdId=105` -> `uav_dm368_set_liveview_priority_bandwidth_req`
- `cmdSet=8, wireCmdId=120` -> `uav_dm368_set_sh_start_live_streaming_req`
- `cmdSet=8, wireCmdId=121` -> `uav_dm368_get_sh_get_live_streaming_setting_info_req`
- `cmdSet=9, wireCmdId=33` -> `uav_ofdm_get_sdr_conf_req`
- `cmdSet=9, wireCmdId=38` -> `uav_ofdm_read_sdr_param_req`
- `cmdSet=9, wireCmdId=39` -> `uav_ofdm_set_sdr_param_req`
- `cmdSet=9, wireCmdId=57` -> `uav_ofdm_set_sdr_config_info_req`
- `cmdSet=9, wireCmdId=68` -> `uav_ofdm_sdr_role_revert_req`
- `cmdSet=9, wireCmdId=75` -> `device_ofdm_sdr_dongle_state_req`
- `cmdSet=9, wireCmdId=77` -> `uav_ofdm_get_hdvt_mode_get_req`
- `cmdSet=9, wireCmdId=78` -> `uav_ofdm_set_hdvt_mode_switch_req`
- `cmdSet=21, wireCmdId=53` -> `uav_goggles_app_to_glass_push_data_push`

This cross-check confirms the general areas to probe, but it did not expose ready-to-send SquirrelCast USB-accessory payloads for `2356/2360/2361`.

### Important cmdId numbering clarification

SquirrelCast's `g2.l0` table uses global command IDs:

```text
global_id = cmdSet * 256 + wire_cmd_id
```

So the commands we care about should be sent on the wire as:

- `cmdSet=2, global 651` -> `wireCmdId=139` (`0x8b`)
- `cmdSet=9, global 2356` -> `wireCmdId=52` (`0x34`)
- `cmdSet=9, global 2357` -> `wireCmdId=53` (`0x35`)
- `cmdSet=9, global 2360` -> `wireCmdId=56` (`0x38`)
- `cmdSet=9, global 2361` -> `wireCmdId=57` (`0x39`)

`radxa_goggles_bridge.py` now accepts either wire IDs or global IDs for `--probe-cmd-id` and logs the normalized wire ID.

### DJI Fly did not yet provide

Still unknown:

- exact SquirrelCast-compatible payload for global `2356`
- exact SquirrelCast-compatible payload for global `2360`
- exact SquirrelCast-compatible payload for global `2361`
- exact SquirrelCast-compatible payload for global `651`
- whether DJI Fly's native command model maps 1:1 to the USB accessory DUML path used by Goggles 3

### Practical next probes

Use global IDs in commands for readability; the bridge converts to wire IDs:

```bash
# Liveview mode get, usually safer than set
python3 radxa_goggles_bridge.py ... --probe-cmd-set 9 --probe-cmd-id 2357 --probe-payload-hex "" --probe-wrap-55cc --dump-raw --verbose

# Candidate set-rate / config probes only after logging replies from GET/push traffic
python3 radxa_goggles_bridge.py ... --probe-cmd-set 9 --probe-cmd-id 2360 --probe-payload-hex "<payload>" --probe-wrap-55cc --dump-raw --verbose
python3 radxa_goggles_bridge.py ... --probe-cmd-set 9 --probe-cmd-id 2361 --probe-payload-hex "<payload>" --probe-wrap-55cc --dump-raw --verbose
```
