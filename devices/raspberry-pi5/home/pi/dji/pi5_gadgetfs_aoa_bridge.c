// Minimal DJI Goggles 3/O4 GadgetFS bridge.
// USB GadgetFS ep1out -> 55CC H.264 Annex B -> framed UDP.
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define GADGETFS_CONNECT 1
#define GADGETFS_DISCONNECT 2
#define GADGETFS_SETUP 3
#define GADGETFS_SUSPEND 4
#define USB_REQ_SET_CONFIGURATION 9
#define USB_REQ_SET_INTERFACE 11

#define MAX_PAYLOAD 65536
#define MAX_NAL 256
#define RTP_PT_H264 96

static const uint8_t DJI_TRIGGER_FRAME_1[] = {
    0x55,0xcc,0x49,0x57,0x2d,0x00,0x00,0x00,0x55,0x2d,0x04,0xf2,0x02,0x28,0xf3,0xfe,
    0x40,0x00,0x99,0x02,0x02,0x00,0x00,0xd5,0x07,0x00,0x00,0x00,0x00,0x00,0x13,0x00,
    0x0d,0x00,0x63,0x61,0x6d,0x63,0x61,0x70,0x5f,0x63,0x6f,0x6d,0x6d,0x6f,0x6e,0x00,
    0x00,0x00,0x00,0xd0,0x93,0x92,0x3a
};
static const uint8_t DJI_TRIGGER_FRAME_2[] = {
    0x55,0xcc,0x49,0x57,0x1b,0x00,0x00,0x00,0x55,0x1b,0x04,0x75,0x02,0x3c,0xf4,0xfe,
    0x40,0x00,0x88,0x17,0x00,0x00,0x23,0x00,0x41,0x50,0x50,0x00,0x00,0x00,0x00,0x00,
    0x02,0x58,0xa6,0x34,0x18
};

struct opts {
    const char *mount;
    const char *chip;
    const char *dest_ip;
    int dest_port;
    int udp_mtu;
    int send_pacing_us;
    bool tcp;
    bool rtp;
    int rtp_fps;
    int source_signal_port;
};

struct bulk_state {
    const struct opts *opts;
    int out_fd;
    int in_fd;
    int udp_fd;
    int tcp_fd;
    struct sockaddr_in dest;
    pthread_t reader_thread;
    pthread_t trigger_thread;
    volatile sig_atomic_t stop;
    volatile sig_atomic_t started;
    uint16_t video_channel;
    bool have_video_channel;
    uint8_t *sps;
    size_t sps_len;
    uint8_t *pps;
    size_t pps_len;
    uint8_t *rtp_stream_buf;
    size_t rtp_stream_len;
    size_t rtp_stream_cap;
    bool stream_ready;
    uint32_t udp_frame_id;
    uint16_t rtp_seq;
    uint32_t rtp_ts;
    uint32_t rtp_ssrc;
    uint64_t pkts;
    uint64_t video_pkts;
    uint64_t video_bytes;
    uint64_t udp_chunks;
    uint64_t udp_bytes;
    uint64_t udp_errors;
    time_t last_stats;
};

static void logmsg(const char *fmt, ...) {
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char ts[16];
    strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
    fprintf(stdout, "%s ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stdout, fmt, ap);
    va_end(ap);
    fputc('\n', stdout);
    fflush(stdout);
}

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

static void ep_desc(uint8_t *p, uint8_t addr, uint16_t maxpkt, bool enabled) {
    p[0] = 7; p[1] = 5; p[2] = addr; p[3] = enabled ? 2 : 0;
    put16(p + 4, enabled ? maxpkt : 0); p[6] = 0;
}

static size_t config_desc(uint8_t *p, uint16_t maxpkt) {
    uint16_t total = 9 + 9 + 7 + 7;
    p[0] = 9; p[1] = 2; put16(p + 2, total); p[4] = 1; p[5] = 1; p[6] = 0; p[7] = 0x80; p[8] = 250;
    uint8_t *q = p + 9;
    q[0] = 9; q[1] = 4; q[2] = 0; q[3] = 0; q[4] = 2; q[5] = 0xff; q[6] = 0xff; q[7] = 0; q[8] = 0;
    ep_desc(q + 9, 0x01, maxpkt, true);
    ep_desc(q + 16, 0x81, maxpkt, true);
    return total;
}

static size_t device_desc(uint8_t *p) {
    p[0] = 18; p[1] = 1; put16(p + 2, 0x0200); p[4] = 0; p[5] = 0; p[6] = 0; p[7] = 64;
    put16(p + 8, 0x18d1); put16(p + 10, 0x2d00); put16(p + 12, 0x0100);
    p[14] = 0; p[15] = 0; p[16] = 0; p[17] = 1;
    return 18;
}

static int write_endpoint_desc(int fd, uint8_t addr, uint16_t maxpkt) {
    uint8_t b[4 + 7 + 7];
    put32(b, 1);
    ep_desc(b + 4, addr, 0, false);
    ep_desc(b + 11, addr, maxpkt, true);
    return (write(fd, b, sizeof(b)) == (ssize_t)sizeof(b)) ? 0 : -1;
}

static bool has_annexb(const uint8_t *p, size_t n) {
    for (size_t i = 0; i + 3 < n; i++) {
        if (p[i] == 0 && p[i + 1] == 0 && ((p[i + 2] == 1) || (i + 3 < n && p[i + 2] == 0 && p[i + 3] == 1))) {
            return true;
        }
    }
    return false;
}

static void cache_copy(uint8_t **dst, size_t *dst_len, const uint8_t *src, size_t len) {
    uint8_t *p = malloc(len);
    if (!p) return;
    memcpy(p, src, len);
    free(*dst);
    *dst = p;
    *dst_len = len;
}

static void scan_nals(struct bulk_state *st, const uint8_t *p, size_t n, bool *has_idr, bool *has_sps) {
    size_t starts[MAX_NAL];
    int sc_len[MAX_NAL];
    size_t count = 0;
    for (size_t i = 0; i + 3 < n && count < MAX_NAL; i++) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            starts[count] = i; sc_len[count] = 3; count++; i += 2;
        } else if (i + 4 < n && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1) {
            starts[count] = i; sc_len[count] = 4; count++; i += 3;
        }
    }
    for (size_t i = 0; i < count; i++) {
        size_t start = starts[i];
        size_t next = (i + 1 < count) ? starts[i + 1] : n;
        size_t hdr = start + (size_t)sc_len[i];
        if (hdr >= next) continue;
        uint8_t typ = p[hdr] & 0x1f;
        if (typ == 5) *has_idr = true;
        if (typ == 7) { *has_sps = true; cache_copy(&st->sps, &st->sps_len, p + start, next - start); }
        if (typ == 8) cache_copy(&st->pps, &st->pps_len, p + start, next - start);
    }
}

static void udp_send_framed(struct bulk_state *st, const uint8_t *p, size_t n) {
    int chunk = st->opts->udp_mtu - 12;
    if (chunk < 256) chunk = 256;
    uint16_t total = (uint16_t)((n + (size_t)chunk - 1) / (size_t)chunk);
    uint32_t fid = st->udp_frame_id++;
    uint8_t buf[2048];
    if ((size_t)chunk + 12 > sizeof(buf)) chunk = (int)sizeof(buf) - 12;
    for (uint16_t idx = 0; idx < total; idx++) {
        size_t off = (size_t)idx * (size_t)chunk;
        size_t len = n - off;
        if (len > (size_t)chunk) len = (size_t)chunk;
        memcpy(buf, "DJI0", 4);
        uint32_t be_fid = htonl(fid);
        uint16_t be_idx = htons(idx);
        uint16_t be_total = htons(total);
        memcpy(buf + 4, &be_fid, 4);
        memcpy(buf + 8, &be_idx, 2);
        memcpy(buf + 10, &be_total, 2);
        memcpy(buf + 12, p + off, len);
        ssize_t sent = sendto(st->udp_fd, buf, len + 12, 0, (struct sockaddr *)&st->dest, sizeof(st->dest));
        if (sent < 0) {
            st->udp_errors++;
            if (st->udp_errors < 10) logmsg("sendto failed: %s", strerror(errno));
        } else {
            st->udp_chunks++;
            st->udp_bytes += (uint64_t)sent;
            if (st->opts->send_pacing_us > 0) usleep((useconds_t)st->opts->send_pacing_us);
        }
    }
}

static ssize_t write_all(int fd, const uint8_t *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, p + off, n - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (w == 0) return -1;
        off += (size_t)w;
    }
    return (ssize_t)n;
}

static int send_transport_packet(struct bulk_state *st, const uint8_t *buf, size_t len) {
    if (st->opts->tcp) {
        if (len > 65535) return -1;
        uint8_t framed[4096];
        if (len + 2 > sizeof(framed)) return -1;
        uint16_t be_len = htons((uint16_t)len);
        memcpy(framed, &be_len, sizeof(be_len));
        memcpy(framed + 2, buf, len);
        if (write_all(st->tcp_fd, framed, len + 2) < 0) return -1;
        return (int)len;
    }
    ssize_t sent = sendto(st->udp_fd, buf, len, 0, (struct sockaddr *)&st->dest, sizeof(st->dest));
    return sent < 0 ? -1 : (int)sent;
}

static void udp_send_rtp_packet(struct bulk_state *st, const uint8_t *payload, size_t payload_len, bool marker) {
    int max_payload = st->opts->udp_mtu - 12;
    if (max_payload < 256) max_payload = 256;
    uint8_t buf[2048];
    if ((size_t)max_payload + 12 > sizeof(buf)) max_payload = (int)sizeof(buf) - 12;
    if (payload_len > (size_t)max_payload) return;

    buf[0] = 0x80;
    buf[1] = (uint8_t)(RTP_PT_H264 | (marker ? 0x80 : 0x00));
    uint16_t seq = htons(st->rtp_seq++);
    uint32_t ts = htonl(st->rtp_ts);
    uint32_t ssrc = htonl(st->rtp_ssrc);
    memcpy(buf + 2, &seq, 2);
    memcpy(buf + 4, &ts, 4);
    memcpy(buf + 8, &ssrc, 4);
    memcpy(buf + 12, payload, payload_len);

    int sent = send_transport_packet(st, buf, payload_len + 12);
    if (sent < 0) {
        st->udp_errors++;
        if (st->udp_errors < 10) logmsg("rtp send failed: %s", strerror(errno));
        if (st->opts->tcp) _exit(111);
    } else {
        st->udp_chunks++;
        st->udp_bytes += (uint64_t)sent;
        if (st->opts->send_pacing_us > 0) usleep((useconds_t)st->opts->send_pacing_us);
    }
}

static void udp_send_rtp_nal(struct bulk_state *st, const uint8_t *nal, size_t nal_len, bool marker) {
    if (nal_len < 1) return;
    int max_payload = st->opts->udp_mtu - 12;
    if (max_payload < 256) max_payload = 256;
    if (max_payload > 1400) max_payload = 1400;

    if (nal_len <= (size_t)max_payload) {
        udp_send_rtp_packet(st, nal, nal_len, marker);
        return;
    }

    uint8_t nal_hdr = nal[0];
    uint8_t fu_indicator = (uint8_t)((nal_hdr & 0xe0) | 28);
    uint8_t nal_type = (uint8_t)(nal_hdr & 0x1f);
    const uint8_t *p = nal + 1;
    size_t remaining = nal_len - 1;
    size_t frag_payload = (size_t)max_payload - 2;
    bool first = true;
    uint8_t buf[1500];
    while (remaining > 0) {
        size_t take = remaining < frag_payload ? remaining : frag_payload;
        bool last = (take == remaining);
        buf[0] = fu_indicator;
        buf[1] = (uint8_t)(nal_type | (first ? 0x80 : 0x00) | (last ? 0x40 : 0x00));
        memcpy(buf + 2, p, take);
        udp_send_rtp_packet(st, buf, take + 2, marker && last);
        p += take;
        remaining -= take;
        first = false;
    }
}

static int start_code_len_at(const uint8_t *p, size_t n, size_t i) {
    if (i + 3 <= n && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) return 3;
    if (i + 4 <= n && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1) return 4;
    return 0;
}

static bool rtp_stream_reserve(struct bulk_state *st, size_t need) {
    if (need <= st->rtp_stream_cap) return true;
    size_t cap = st->rtp_stream_cap ? st->rtp_stream_cap : 65536;
    while (cap < need) cap *= 2;
    uint8_t *p = realloc(st->rtp_stream_buf, cap);
    if (!p) return false;
    st->rtp_stream_buf = p;
    st->rtp_stream_cap = cap;
    return true;
}

static void udp_send_rtp_annexb_complete(struct bulk_state *st, const uint8_t *p, size_t n) {
    size_t starts[MAX_NAL];
    int sc_len[MAX_NAL];
    size_t count = 0;
    for (size_t i = 0; i + 3 < n && count < MAX_NAL; i++) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
            starts[count] = i; sc_len[count] = 3; count++; i += 2;
        } else if (i + 4 < n && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1) {
            starts[count] = i; sc_len[count] = 4; count++; i += 3;
        }
    }
    if (!count) return;
    for (size_t i = 0; i < count; i++) {
        size_t start = starts[i] + (size_t)sc_len[i];
        size_t next = (i + 1 < count) ? starts[i + 1] : n;
        while (next > start && p[next - 1] == 0) next--;
        if (next <= start) continue;
        uint8_t nal_type = p[start] & 0x1f;
        bool marker = (nal_type == 1 || nal_type == 5);
        udp_send_rtp_nal(st, p + start, next - start, marker);
        if (nal_type == 1 || nal_type == 5) {
            int fps = st->opts->rtp_fps > 0 ? st->opts->rtp_fps : 60;
            st->rtp_ts += (uint32_t)(90000 / fps);
        }
    }
}

static void udp_send_rtp_annexb_stream(struct bulk_state *st, const uint8_t *p, size_t n) {
    if (!rtp_stream_reserve(st, st->rtp_stream_len + n)) return;
    memcpy(st->rtp_stream_buf + st->rtp_stream_len, p, n);
    st->rtp_stream_len += n;

    size_t starts[MAX_NAL];
    int sc_len[MAX_NAL];
    size_t count = 0;
    for (size_t i = 0; i + 3 < st->rtp_stream_len && count < MAX_NAL; i++) {
        int scl = start_code_len_at(st->rtp_stream_buf, st->rtp_stream_len, i);
        if (scl) {
            starts[count] = i;
            sc_len[count] = scl;
            count++;
            i += (size_t)scl - 1;
        }
    }

    if (count < 2) {
        if (st->rtp_stream_len > 2 * 1024 * 1024) {
            memmove(st->rtp_stream_buf, st->rtp_stream_buf + st->rtp_stream_len - 65536, 65536);
            st->rtp_stream_len = 65536;
        }
        return;
    }

    size_t emit_end = starts[count - 1];
    udp_send_rtp_annexb_complete(st, st->rtp_stream_buf, emit_end);

    size_t remain = st->rtp_stream_len - emit_end;
    memmove(st->rtp_stream_buf, st->rtp_stream_buf + emit_end, remain);
    st->rtp_stream_len = remain;
}

static void udp_send_video_payload(struct bulk_state *st, const uint8_t *p, size_t n) {
    if (st->opts->rtp) udp_send_rtp_annexb_stream(st, p, n);
    else udp_send_framed(st, p, n);
}

static void handle_payload(struct bulk_state *st, uint16_t channel, const uint8_t *p, size_t n) {
    bool h264 = n >= 256 && has_annexb(p, n);
    if (h264 && !st->have_video_channel && channel != 0x5749) {
        st->video_channel = channel;
        st->have_video_channel = true;
        logmsg("locked video channel=0x%04x", channel);
    }
    if (!st->have_video_channel || st->video_channel != channel) return;

    bool has_idr = false;
    bool has_sps = false;
    scan_nals(st, p, n, &has_idr, &has_sps);
    if (!st->stream_ready) {
        if (st->sps_len && st->pps_len) {
            st->stream_ready = true;
            logmsg("H264 parameter sets ready; UDP stream enabled");
        } else {
            return;
        }
    }
    if (has_idr && !has_sps && st->sps_len && st->pps_len) {
        size_t combo_len = st->sps_len + st->pps_len;
        uint8_t *combo = malloc(combo_len);
        if (combo) {
            memcpy(combo, st->sps, st->sps_len);
            memcpy(combo + st->sps_len, st->pps, st->pps_len);
            udp_send_video_payload(st, combo, combo_len);
            free(combo);
        }
    }
    st->video_pkts++;
    st->video_bytes += n;
    udp_send_video_payload(st, p, n);
}

static void *reader_main(void *arg) {
    struct bulk_state *st = arg;
    uint8_t buf[32768];
    while (!st->stop) {
        ssize_t r = read(st->out_fd, buf, sizeof(buf));
        if (r <= 0) {
            if (errno != EINTR) logmsg("OUT read error: %s", strerror(errno));
            usleep(200000);
            continue;
        }
        st->pkts++;
        if (r >= 8 && buf[0] == 0x55 && buf[1] == 0xcc) {
            uint16_t ch = (uint16_t)buf[2] | ((uint16_t)buf[3] << 8);
            uint16_t len = (uint16_t)buf[4] | ((uint16_t)buf[5] << 8);
            if ((size_t)len <= (size_t)r - 8) handle_payload(st, ch, buf + 8, len);
        }
        time_t now = time(NULL);
        if (now != st->last_stats) {
            st->last_stats = now;
            logmsg("stats pkts=%llu video_channel=%s0x%04x video_pkts=%llu video_bytes=%llu",
                   (unsigned long long)st->pkts,
                   st->have_video_channel ? "" : "none/",
                   st->video_channel,
                   (unsigned long long)st->video_pkts,
                   (unsigned long long)st->video_bytes);
            logmsg("udp chunks=%llu bytes=%llu errors=%llu",
                   (unsigned long long)st->udp_chunks,
                   (unsigned long long)st->udp_bytes,
                   (unsigned long long)st->udp_errors);
        }
    }
    return NULL;
}

static void *trigger_main(void *arg) {
    struct bulk_state *st = arg;
    while (!st->stop) {
        ssize_t a = write(st->in_fd, DJI_TRIGGER_FRAME_1, sizeof(DJI_TRIGGER_FRAME_1));
        ssize_t b = write(st->in_fd, DJI_TRIGGER_FRAME_2, sizeof(DJI_TRIGGER_FRAME_2));
        if (a < 0 || b < 0) logmsg("IN write error: %s", strerror(errno));
        if (st->opts->rtp && st->opts->source_signal_port > 0) {
            struct sockaddr_in sig_dest = st->dest;
            sig_dest.sin_port = htons((uint16_t)st->opts->source_signal_port);
            const char msg[] = "DJI_SOURCE\n";
            sendto(st->udp_fd, msg, sizeof(msg) - 1, 0, (struct sockaddr *)&sig_dest, sizeof(sig_dest));
        }
        sleep(1);
    }
    return NULL;
}

static int bulk_start(struct bulk_state *st) {
    if (st->started) return 0;
    char path[256];
    snprintf(path, sizeof(path), "%s/ep1out", st->opts->mount);
    st->out_fd = open(path, O_RDWR);
    snprintf(path, sizeof(path), "%s/ep1in", st->opts->mount);
    st->in_fd = open(path, O_RDWR);
    if (st->out_fd < 0 || st->in_fd < 0) return -1;
    if (write_endpoint_desc(st->out_fd, 0x01, 512) || write_endpoint_desc(st->in_fd, 0x81, 512)) return -1;
    st->stop = 0;
    st->started = 1;
    logmsg("bulk endpoints started ep1out/ep1in");
    pthread_create(&st->reader_thread, NULL, reader_main, st);
    pthread_create(&st->trigger_thread, NULL, trigger_main, st);
    return 0;
}

static void bulk_reset(struct bulk_state *st) {
    if (!st->started) return;
    st->stop = 1;
    close(st->out_fd);
    close(st->in_fd);
    pthread_join(st->reader_thread, NULL);
    pthread_join(st->trigger_thread, NULL);
    st->out_fd = -1;
    st->in_fd = -1;
    st->started = 0;
    st->have_video_channel = false;
    st->stream_ready = false;
    free(st->sps); st->sps = NULL; st->sps_len = 0;
    free(st->pps); st->pps = NULL; st->pps_len = 0;
    st->rtp_stream_len = 0;
    logmsg("bulk endpoints reset");
}

static void usage(const char *argv0) {
    fprintf(stderr, "Usage: %s [--mount /dev/gadget] [--chip 1000480000.usb] --dest-ip IP [--dest-port 5600] [--udp-mtu 1200] [--send-pacing-us 0] [--tcp] [--udp-framed|--rtp] [--rtp-fps 60] [--source-signal-port 5512]\n", argv0);
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    struct opts opt = { .mount = "/dev/gadget", .chip = "1000480000.usb", .dest_ip = "127.0.0.1", .dest_port = 5600, .udp_mtu = 1200, .send_pacing_us = 0, .tcp = false, .rtp = false, .rtp_fps = 60, .source_signal_port = 5512 };
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--mount") && i + 1 < argc) opt.mount = argv[++i];
        else if (!strcmp(argv[i], "--chip") && i + 1 < argc) opt.chip = argv[++i];
        else if (!strcmp(argv[i], "--dest-ip") && i + 1 < argc) opt.dest_ip = argv[++i];
        else if (!strcmp(argv[i], "--dest-port") && i + 1 < argc) opt.dest_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--udp-mtu") && i + 1 < argc) opt.udp_mtu = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--send-pacing-us") && i + 1 < argc) opt.send_pacing_us = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tcp")) opt.tcp = true;
        else if (!strcmp(argv[i], "--transport") && i + 1 < argc) { i++; }
        else if (!strcmp(argv[i], "--repeat-params") && i + 1 < argc) { i++; }
        else if (!strcmp(argv[i], "--udp-framed")) opt.rtp = false;
        else if (!strcmp(argv[i], "--rtp")) opt.rtp = true;
        else if (!strcmp(argv[i], "--rtp-fps") && i + 1 < argc) opt.rtp_fps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--source-signal-port") && i + 1 < argc) opt.source_signal_port = atoi(argv[++i]);
        else { usage(argv[0]); return 2; }
    }

    int udp = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp < 0) { perror("socket"); return 1; }
    int tcp = -1;
    struct sockaddr_in dest = {0};
    dest.sin_family = AF_INET;
    dest.sin_port = htons((uint16_t)opt.dest_port);
    if (inet_pton(AF_INET, opt.dest_ip, &dest.sin_addr) != 1) { perror("inet_pton"); return 1; }
    if (opt.tcp) {
        tcp = socket(AF_INET, SOCK_STREAM, 0);
        if (tcp < 0) { perror("tcp socket"); return 1; }
        int one = 1;
        setsockopt(tcp, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        if (connect(tcp, (struct sockaddr *)&dest, sizeof(dest)) < 0) { perror("tcp connect"); return 1; }
    }
    logmsg("dest %s:%d transport=%s mtu=%d pacing_us=%d mode=%s fps=%d source_signal_port=%d", opt.dest_ip, opt.dest_port, opt.tcp ? "tcp" : "udp", opt.udp_mtu, opt.send_pacing_us, opt.rtp ? "rtp-h264" : "dji0-framed", opt.rtp_fps, opt.source_signal_port);

    char ep0_path[256];
    snprintf(ep0_path, sizeof(ep0_path), "%s/%s", opt.mount, opt.chip);
    logmsg("open ep0 %s", ep0_path);
    int ep0 = open(ep0_path, O_RDWR);
    if (ep0 < 0) { perror("open ep0"); return 1; }

    uint8_t blob[4 + 32 + 32 + 18];
    put32(blob, 0);
    size_t off = 4;
    off += config_desc(blob + off, 64);
    off += config_desc(blob + off, 512);
    off += device_desc(blob + off);
    logmsg("write descriptors len=%zu", off);
    if (write(ep0, blob, off) != (ssize_t)off) { perror("write descriptors"); return 1; }

    struct bulk_state st = {0};
    st.opts = &opt;
    st.out_fd = -1;
    st.in_fd = -1;
    st.udp_fd = udp;
    st.tcp_fd = tcp;
    st.dest = dest;
    st.last_stats = time(NULL);
    st.rtp_seq = (uint16_t)(time(NULL) & 0xffff);
    st.rtp_ts = (uint32_t)time(NULL) * 90000u;
    st.rtp_ssrc = 0x44524a35u; // "DRJ5" stable enough for one stream.

    struct pollfd pfd = { .fd = ep0, .events = POLLIN };
    while (1) {
        int pr = poll(&pfd, 1, 1000);
        if (pr <= 0) continue;
        uint8_t raw[12];
        ssize_t r = read(ep0, raw, sizeof(raw));
        if (r != 12) continue;
        uint32_t ev = raw[8] | (raw[9] << 8) | (raw[10] << 16) | (raw[11] << 24);
        if (ev == GADGETFS_CONNECT) {
            uint32_t speed = raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24);
            logmsg("CONNECT speed=%u", speed);
        } else if (ev == GADGETFS_DISCONNECT) {
            logmsg("DISCONNECT");
            bulk_reset(&st);
        } else if (ev == GADGETFS_SUSPEND) {
            logmsg("SUSPEND");
            bulk_reset(&st);
        } else if (ev == GADGETFS_SETUP) {
            uint8_t bm = raw[0], req = raw[1];
            uint16_t value = raw[2] | (raw[3] << 8);
            uint16_t length = raw[6] | (raw[7] << 8);
            logmsg("SETUP bm=0x%02x req=0x%02x value=0x%04x len=%u", bm, req, value, length);
            if (bm & 0x80) {
                read(ep0, NULL, 0);
            } else {
                if (length) {
                    uint8_t tmp[1024];
                    read(ep0, tmp, length < sizeof(tmp) ? length : sizeof(tmp));
                }
                if (req == USB_REQ_SET_CONFIGURATION || req == USB_REQ_SET_INTERFACE) {
                    read(ep0, NULL, 0);
                    if (req == USB_REQ_SET_CONFIGURATION && value) {
                        if (bulk_start(&st) != 0) logmsg("bulk start failed: %s", strerror(errno));
                    }
                } else {
                    write(ep0, "", 0);
                }
            }
        }
    }
}
