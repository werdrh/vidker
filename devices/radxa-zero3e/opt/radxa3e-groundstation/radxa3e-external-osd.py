#!/usr/bin/env python3
import glob, math, mmap, os, socket, struct, subprocess, time
import cairo

SHM = os.environ.get('RADXA3E_EXT_OSD_SHM', '/dev/shm/Radxa column')
X = int(os.environ.get('RADXA3E_EXT_OSD_X', '20'))
Y = int(os.environ.get('RADXA3E_EXT_OSD_Y', '560'))
FONT_SIZE = int(os.environ.get('RADXA3E_EXT_OSD_FONT_SIZE', '30'))
LINE_STEP = int(os.environ.get('RADXA3E_EXT_OSD_LINE_STEP', '38'))
ALERT_Y = int(os.environ.get('RADXA3E_EXT_OSD_ALERT_Y', '880'))
ALERT_TEXT = os.environ.get('RADXA3E_EXT_OSD_ALERT_TEXT', 'НИЗЬКИЙ РІВЕНЬ ОПТИЧНОГО СИГНАЛУ')
FONT_FACE = os.environ.get('RADXA3E_EXT_OSD_FONT_FACE', 'Noto Sans Mono')
I2C_BUS = os.environ.get('SFP_I2C_BUS', '4')
RECORD_STATE_FILE = os.environ.get('RECORD_STATE_FILE', '/run/radxa3e-record.state')
STATUS_FILE = os.environ.get('PIXELPILOT_STATUS_FILE', '/run/radxa3e-record-status')
SOURCE_MODE_FILE = os.environ.get('RADXA3E_SOURCE_MODE_FILE', '/etc/default/radxa3e-source-mode')
LINK_MODE_FILE = os.environ.get('RADXA3E_LINK_MODE_FILE', '/run/radxa3e-link-mode')
RECORD_DIR = os.environ.get('RECORD_DIR', '/media/recordings')
DDM_ADDR = os.environ.get('SFP_DDM_ADDR', '0x51')
CAMERA_QUALITY_HOST = os.environ.get('CAMERA_QUALITY_HOST', '192.168.121.50')
CAMERA_QUALITY_PORT = int(os.environ.get('CAMERA_QUALITY_PORT', '5510'))
CAMERA_QUALITY_PREFIX = os.environ.get('CAMERA_QUALITY_PREFIX', 'LINK')
HIDE_OPTICAL_RX = os.environ.get('RADXA3E_HIDE_OPTICAL_RX', 'auto').lower()
DJI_SOURCE_IP = os.environ.get('RADXA3E_DJI_SOURCE_IP', '192.168.121.50')
DJI_SOURCE_SIGNAL_PORT = int(os.environ.get('RADXA3E_DJI_SOURCE_SIGNAL_PORT', '5512'))
DJI_SOURCE_STALE_SEC = float(os.environ.get('RADXA3E_DJI_SOURCE_STALE_SEC', '3.0'))
PEER_PING_HOST = os.environ.get('RADXA3E_PEER_PING_HOST', '192.168.121.50')
PEER_PING_LABEL = os.environ.get('RADXA3E_PEER_PING_LABEL', 'PING')
PEER_PING_ENABLED = os.environ.get('RADXA3E_PEER_PING_ENABLED', '1').lower() in ('1', 'true', 'yes', 'on')
VIDEO_STATS_ENABLED = os.environ.get('RADXA3E_VIDEO_STATS_ENABLED', '1').lower() in ('1', 'true', 'yes', 'on')
VIDEO_STATS_PORT = os.environ.get('RADXA3E_VIDEO_STATS_PORT', '5600').lower()
_last_camera_quality = {'text': None, 'ts': 0.0}
_last_source_check = {'ts': 0.0, 'is_dji': False}
_source_sock = None
_last_dji_source_ts = 0.0
_last_ping = {'ts': 0.0, 'text': 'PING --'}
_last_video_stats = {'ts': 0.0, 'drops': None, 'text': 'V --M D--'}
_last_rx_dbm = {'ts': 0.0, 'value': None, 'fail_until': 0.0}


def read_cmd(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=0.3).strip()
    except Exception:
        return ''


def current_mode_line():
    source = 'camera'
    try:
        for line in open(SOURCE_MODE_FILE, errors='ignore'):
            if line.startswith('RADXA3E_SOURCE_MODE='):
                source = line.split('=', 1)[1].strip() or 'camera'
    except Exception:
        pass

    labels = {
        'camera': 'Оптика',
        'optics': 'Оптика',
        'pi-local': 'PI Lan',
        'pi-internet': 'Internet',
    }
    return labels.get(source, f'MODE {source.upper()}')


def current_source_and_link():
    source = 'camera'
    link = ''
    try:
        for line in open(SOURCE_MODE_FILE, errors='ignore'):
            if line.startswith('RADXA3E_SOURCE_MODE='):
                source = line.split('=', 1)[1].strip() or 'camera'
    except Exception:
        pass

    try:
        parts = open(LINK_MODE_FILE, errors='ignore').read().strip().split()
        if parts:
            link = parts[0]
    except Exception:
        pass

    return source, link


def optical_rx_hidden():
    global _source_sock, _last_dji_source_ts
    if HIDE_OPTICAL_RX in ('1', 'true', 'yes', 'on'):
        return True
    if HIDE_OPTICAL_RX in ('0', 'false', 'no', 'off'):
        return False

    source, link = current_source_and_link()
    if source in ('pi-local', 'pi-internet') or link in ('local', 'tailscale'):
        return True
    if source in ('camera', 'optics') or link == 'camera':
        return False

    now = time.monotonic()
    if _source_sock is None and DJI_SOURCE_SIGNAL_PORT > 0:
        try:
            _source_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            _source_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            _source_sock.bind(('0.0.0.0', DJI_SOURCE_SIGNAL_PORT))
            _source_sock.setblocking(False)
        except Exception:
            _source_sock = False

    if _source_sock:
        while True:
            try:
                data, addr = _source_sock.recvfrom(256)
            except BlockingIOError:
                break
            except Exception:
                break
            if data.strip() == b'DJI_SOURCE':
                _last_dji_source_ts = now

    return bool(_last_dji_source_ts and now - _last_dji_source_ts <= DJI_SOURCE_STALE_SEC)


def i2c_reg(reg):
    out = read_cmd(['/usr/sbin/i2cget', '-y', str(I2C_BUS), str(DDM_ADDR), hex(reg)])
    try:
        return int(out, 16)
    except Exception:
        return None


def rx_dbm_value():
    now = time.monotonic()
    if now < _last_rx_dbm['fail_until']:
        return _last_rx_dbm['value']
    if now - _last_rx_dbm['ts'] < 0.5:
        return _last_rx_dbm['value']

    hi, lo = i2c_reg(0x68), i2c_reg(0x69)
    if hi is None or lo is None:
        _last_rx_dbm['ts'] = now
        _last_rx_dbm['value'] = None
        _last_rx_dbm['fail_until'] = now + 2.0
        return None
    raw = (hi << 8) | lo
    if raw <= 0:
        _last_rx_dbm['ts'] = now
        _last_rx_dbm['value'] = None
        _last_rx_dbm['fail_until'] = now + 2.0
        return None
    value = 10 * math.log10(raw * 0.0001)
    _last_rx_dbm['ts'] = now
    _last_rx_dbm['value'] = value
    _last_rx_dbm['fail_until'] = 0.0
    return value


def rx_status(dbm):
    if dbm is None:
        return '--'
    if dbm > -9:
        return 'GOOD'
    if dbm > -15:
        return 'WARN'
    if dbm > -20:
        return 'BAD'
    return 'ALERT'


def rx_line():
    dbm = rx_dbm_value()
    if dbm is None:
        return 'RX --'
    return f'RX {rx_status(dbm)} {dbm:.1f}'


def camera_quality_text(dbm):
    if dbm is None:
        return f'&G8 &L32 &F28 {CAMERA_QUALITY_PREFIX} --'
    return f'&G8 &L32 &F28 {CAMERA_QUALITY_PREFIX} {dbm:.1f}'


def send_camera_quality(dbm):
    if optical_rx_hidden():
        return
    now = time.monotonic()
    text = camera_quality_text(dbm)
    if text == _last_camera_quality['text'] and now - _last_camera_quality['ts'] < 1.0:
        return
    _last_camera_quality['text'] = text
    _last_camera_quality['ts'] = now
    try:
        with socket.create_connection((CAMERA_QUALITY_HOST, CAMERA_QUALITY_PORT), timeout=0.12) as sock:
            sock.sendall((text + '\n').encode('ascii', 'ignore'))
    except Exception:
        pass


def optical_alert_active():
    if optical_rx_hidden():
        return False
    dbm = rx_dbm_value()
    return dbm is None or dbm <= -20.0


def cpu_percent():
    def sample():
        vals = [int(x) for x in open('/proc/stat').readline().split()[1:8]]
        return vals[3] + vals[4], sum(vals)
    try:
        i1, t1 = sample()
        time.sleep(0.05)
        i2, t2 = sample()
        return int(100 * (1 - (i2 - i1) / max(1, t2 - t1)))
    except Exception:
        return None


def mem_percent():
    vals = {}
    try:
        for line in open('/proc/meminfo'):
            k, v = line.split(':', 1)
            vals[k] = int(v.split()[0])
        return int((vals['MemTotal'] - vals['MemAvailable']) * 100 / vals['MemTotal'])
    except Exception:
        return None


def temp_c():
    for path in glob.glob('/sys/class/thermal/thermal_zone*/temp'):
        try:
            value = int(open(path).read().strip()) // 1000
            if 0 < value < 120:
                return value
        except Exception:
            pass
    return None


def peer_ping_line():
    if not PEER_PING_ENABLED:
        return None
    now = time.monotonic()
    if now - _last_ping['ts'] < 1.0:
        return _last_ping['text']
    _last_ping['ts'] = now
    out = read_cmd(['ping', '-c', '1', '-W', '1', PEER_PING_HOST])
    text = f'{PEER_PING_LABEL} --'
    marker = 'time='
    if marker in out:
        try:
            value = out.split(marker, 1)[1].split()[0]
            text = f'{PEER_PING_LABEL} {float(value):.1f}ms'
        except Exception:
            text = f'{PEER_PING_LABEL} --'
    _last_ping['text'] = text
    return text



def video_udp_sample():
    try:
        port_hex = f'{int(VIDEO_STATS_PORT):04X}'
    except Exception:
        port_hex = '15E0'
    try:
        for line in open('/proc/net/udp'):
            parts = line.split()
            if len(parts) < 13 or ':' not in parts[1]:
                continue
            local_port = parts[1].split(':', 1)[1].upper()
            if local_port != port_hex:
                continue
            drops = int(parts[12])
            inode = parts[9]
            rx_bytes = 0
            for fd in glob.glob(f'/proc/*/fd/*'):
                try:
                    if os.readlink(fd) != f'socket:[{inode}]':
                        continue
                    pid = fd.split('/')[2]
                    dev_text = open(f'/proc/{pid}/net/dev').read(); rx_bytes = int(dev_text.split('tailscale0:')[1].split()[0]) if 'tailscale0:' in dev_text else 0
                    break
                except Exception:
                    pass
            if rx_bytes <= 0:
                # Prefer tailscale0 when present, otherwise end1. This is interface-level,
                # but for our receiver mode the video stream dominates RX traffic.
                for iface in ('tailscale0', 'end1'):
                    try:
                        rx_bytes = int(open(f'/sys/class/net/{iface}/statistics/rx_bytes').read())
                        if rx_bytes > 0:
                            break
                    except Exception:
                        pass
            return rx_bytes, drops
    except Exception:
        return None
    return None


def video_stats_line():
    if not VIDEO_STATS_ENABLED:
        return None
    now = time.monotonic()
    if now - _last_video_stats['ts'] < 1.0:
        return _last_video_stats['text']
    sample = video_udp_sample()
    if not sample:
        _last_video_stats['ts'] = now
        _last_video_stats['text'] = 'V --M D--'
        return _last_video_stats['text']
    rx_bytes, drops = sample
    prev_ts = _last_video_stats.get('ts') or now
    prev_bytes = _last_video_stats.get('bytes')
    prev_drops = _last_video_stats.get('drops')
    mbps = None
    if prev_bytes is not None and now > prev_ts:
        mbps = max(0.0, (rx_bytes - prev_bytes) * 8.0 / (now - prev_ts) / 1000000.0)
    drop_delta = 0 if prev_drops is None else max(0, drops - prev_drops)
    _last_video_stats.update({'ts': now, 'bytes': rx_bytes, 'drops': drops})
    if mbps is None:
        text = f'V --M D{drop_delta}'
    else:
        text = f'V {mbps:.1f}M D{drop_delta}'
    _last_video_stats['text'] = text
    return text


def format_bytes(value):
    try:
        value = float(value)
    except Exception:
        return '--'
    units = ('B', 'K', 'M', 'G', 'T')
    idx = 0
    while value >= 1024 and idx < len(units) - 1:
        value /= 1024
        idx += 1
    if idx == 0:
        return f'{int(value)}{units[idx]}'
    return f'{value:.1f}{units[idx]}'


def recording_free_text():
    try:
        source = read_cmd(['findmnt', '-n', '-o', 'SOURCE', '-T', RECORD_DIR])
        if not source or not os.path.exists(source):
            return 'USB --'
        parent = read_cmd(['lsblk', '-ndo', 'PKNAME', source])
        block_name = os.path.basename(parent or source)
        if block_name.startswith(('mmcblk', 'zram', 'loop')):
            return 'USB --'
        stat = os.statvfs(RECORD_DIR)
        free = stat.f_bavail * stat.f_frsize
        return f'USB {format_bytes(free)}'
    except Exception:
        return 'USB --'


def recording_active():
    try:
        return 'RECORD=1' in open(RECORD_STATE_FILE).read()
    except Exception:
        return False


def status_message():
    try:
        msg = open(STATUS_FILE).read().strip().replace('\ufeff', '').replace('\u200b', '')
    except Exception:
        return ''
    return msg[:24]


def status_color(msg):
    upper = msg.upper()
    if 'ERR' in upper or 'NO USB' in upper:
        return (1, 0.05, 0.05, 1)
    if 'SAVED' in upper:
        return (0.1, 1, 0.1, 1)
    if 'SAVING' in upper or 'REMUX' in upper:
        return (1, 0.85, 0.05, 1)
    return (1, 1, 1, 1)


def lines():
    cpu = cpu_percent()
    mem = mem_percent()
    temp = temp_c()
    out = [
        current_mode_line(),
        f'CPU {cpu if cpu is not None else "--"}%',
        f'RAM {mem if mem is not None else "--"}%',
        f'T {temp if temp is not None else "--"}C',
        recording_free_text(),
    ]
    dji_source = optical_rx_hidden()
    if dji_source:
        video = video_stats_line()
        if video:
            out.insert(0, video)
        ping = peer_ping_line()
        if ping:
            out.insert(0, ping)
    else:
        dbm = rx_dbm_value()
        send_camera_quality(dbm)
        out.insert(0, f'RX {rx_status(dbm)} {dbm:.1f}' if dbm is not None else 'RX --')
    return out


def draw_outlined_text(ctx, x, y, text, size, color):
    ctx.select_font_face(FONT_FACE, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
    ctx.set_font_size(size)
    ctx.set_source_rgba(0, 0, 0, 0.9)
    for dx, dy in ((2, 2), (-2, 2), (2, -2), (-2, -2), (3, 0), (0, 3)):
        ctx.move_to(x + dx, y + dy)
        ctx.show_text(text)
    ctx.set_source_rgba(*color)
    ctx.move_to(x, y)
    ctx.show_text(text)


def draw(surface, width, height):
    ctx = cairo.Context(surface)
    ctx.set_operator(cairo.OPERATOR_CLEAR)
    ctx.paint()
    ctx.set_operator(cairo.OPERATOR_OVER)

    msg = status_message()
    if recording_active():
        draw_outlined_text(ctx, 58, 58, 'REC', 36, (1, 0.05, 0.05, 1))
    elif msg:
        draw_outlined_text(ctx, 58, 58, msg.upper(), 30, status_color(msg))

    for idx, text in enumerate(lines()):
        y = Y + idx * LINE_STEP
        draw_outlined_text(ctx, X, y, text, FONT_SIZE, (1, 1, 1, 1))

    if optical_alert_active():
        ctx.select_font_face(FONT_FACE, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        ctx.set_font_size(34)
        xb, yb, tw, th, xa, ya = ctx.text_extents(ALERT_TEXT)
        alert_x = int((width - tw) / 2)
        draw_outlined_text(ctx, alert_x, ALERT_Y, ALERT_TEXT, 34, (1, 0.02, 0.02, 1))
    surface.flush()


def main():
    while not os.path.exists(SHM):
        time.sleep(0.2)
    fd = os.open(SHM, os.O_RDWR)
    mm = None
    while True:
        size = os.fstat(fd).st_size
        if size >= 4:
            mm = mmap.mmap(fd, size)
            width, height = struct.unpack_from('<HH', mm, 0)
            if width and height and size >= 4 + width * height * 4:
                break
            mm.close()
        time.sleep(0.2)

    frame = bytearray(width * height * 4)
    surface = cairo.ImageSurface.create_for_data(frame, cairo.FORMAT_ARGB32, width, height)
    while True:
        draw(surface, width, height)
        # Atomic-ish update: PixelPilot never sees a cleared frame, only complete frames.
        mm.seek(4)
        mm.write(frame)
        mm.flush()
        time.sleep(1)


if __name__ == '__main__':
    main()
