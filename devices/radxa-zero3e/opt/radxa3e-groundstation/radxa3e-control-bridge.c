#define _GNU_SOURCE

#include <arpa/inet.h>
#include <asm/ioctls.h>
#include <asm/termbits.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void on_signal(int signo) {
    (void)signo;
    running = 0;
}

static const char *env_str(const char *name, const char *fallback) {
    const char *value = getenv(name);
    return (value && *value) ? value : fallback;
}

static int env_int(const char *name, int fallback) {
    const char *value = getenv(name);
    if (!value || !*value) {
        return fallback;
    }
    char *end = NULL;
    long parsed = strtol(value, &end, 0);
    return (end && *end == '\0') ? (int)parsed : fallback;
}

static bool env_bool(const char *name, bool fallback) {
    const char *value = getenv(name);
    if (!value || !*value) {
        return fallback;
    }
    return strcmp(value, "1") == 0 || strcasecmp(value, "true") == 0 ||
           strcasecmp(value, "yes") == 0 || strcasecmp(value, "on") == 0;
}

static void log_msg(const char *level, const char *fmt, ...) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);

    char stamp[64];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);

    fprintf(stderr, "%s.%03ld %s ", stamp, ts.tv_nsec / 1000000L, level);

    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
}

static int open_serial(const char *path, int baudrate) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        log_msg("ERROR", "open %s failed: %s", path, strerror(errno));
        return -1;
    }

    struct termios2 tio;
    memset(&tio, 0, sizeof(tio));
    if (ioctl(fd, TCGETS2, &tio) != 0) {
        log_msg("ERROR", "TCGETS2 failed: %s", strerror(errno));
        close(fd);
        return -1;
    }

    tio.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXOFF | IXANY);
    tio.c_oflag &= ~OPOST;
    tio.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    tio.c_cflag &= ~(CSIZE | PARENB | CSTOPB | CRTSCTS | CBAUD);
    tio.c_cflag |= CLOCAL | CREAD | CS8;
    tio.c_cflag |= BOTHER;
    tio.c_ispeed = (unsigned int)baudrate;
    tio.c_ospeed = (unsigned int)baudrate;
    tio.c_cc[VMIN] = 0;
    tio.c_cc[VTIME] = 0;

    if (ioctl(fd, TCSETS2, &tio) != 0) {
        log_msg("ERROR", "TCSETS2 failed: %s", strerror(errno));
        close(fd);
        return -1;
    }

    ioctl(fd, TCFLSH, TCIOFLUSH);
    return fd;
}

static int open_udp_sender(const char *camera_ip, int camera_port, struct sockaddr_in *dest) {
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        log_msg("ERROR", "socket failed: %s", strerror(errno));
        return -1;
    }

    int priority = 6;
    setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &priority, sizeof(priority));

    memset(dest, 0, sizeof(*dest));
    dest->sin_family = AF_INET;
    dest->sin_port = htons((uint16_t)camera_port);
    if (inet_pton(AF_INET, camera_ip, &dest->sin_addr) != 1) {
        log_msg("ERROR", "invalid CAMERA_IP=%s", camera_ip);
        close(fd);
        return -1;
    }

    return fd;
}

static uint8_t crsf_crc8(const uint8_t *data, size_t len) {
    uint8_t crc = 0;

    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0xD5) : (uint8_t)(crc << 1);
        }
    }

    return crc;
}

static ssize_t send_udp_frame(int udp_fd, const struct sockaddr_in *dest, uint8_t *frame, size_t frame_len) {
    return sendto(udp_fd, frame, frame_len, MSG_DONTWAIT,
                  (const struct sockaddr *)dest, sizeof(*dest));
}

static void parse_and_forward_crsf(
    uint8_t *pending,
    size_t *pending_len,
    const uint8_t *data,
    size_t data_len,
    int udp_fd,
    const struct sockaddr_in *dest,
    uint8_t output_addr,
    unsigned long long *bytes,
    unsigned long long *packets,
    unsigned long long *frames,
    unsigned long long *bad_frames
) {
    if (data_len > 512 - *pending_len) {
        size_t keep = *pending_len < 64 ? *pending_len : 64;
        memmove(pending, pending + (*pending_len - keep), keep);
        *pending_len = keep;
    }

    memcpy(pending + *pending_len, data, data_len);
    *pending_len += data_len;

    while (*pending_len >= 4) {
        uint8_t len = pending[1];
        if (len < 2 || len > 64) {
            memmove(pending, pending + 1, *pending_len - 1);
            (*pending_len)--;
            continue;
        }

        size_t frame_len = (size_t)len + 2;
        if (*pending_len < frame_len) {
            break;
        }

        uint8_t crc = crsf_crc8(pending + 2, (size_t)len - 1);
        if (crc == pending[frame_len - 1]) {
            uint8_t out[66];
            memcpy(out, pending, frame_len);

            // Handset/JR bay RC frames can be addressed as 0xEE. Betaflight usually
            // expects RC frames addressed to the flight controller (0xC8).
            if (out[2] == 0x16) {
                out[0] = output_addr;
            }

            ssize_t sent = send_udp_frame(udp_fd, dest, out, frame_len);
            if (sent >= 0) {
                *bytes += (unsigned long long)sent;
                (*packets)++;
                (*frames)++;
            }

            memmove(pending, pending + frame_len, *pending_len - frame_len);
            *pending_len -= frame_len;
            continue;
        }

        (*bad_frames)++;
        memmove(pending, pending + 1, *pending_len - 1);
        (*pending_len)--;
    }
}

int main(void) {
    const char *serial_port = env_str("SERIAL_PORT", "/dev/ttyS4");
    const char *camera_ip = env_str("CAMERA_IP", "192.168.121.50");
    int baudrate = env_int("BAUDRATE", 420000);
    int camera_port = env_int("CAMERA_PORT", 5000);
    int read_chunk = env_int("READ_CHUNK", 64);
    bool normalize_crsf = env_bool("NORMALIZE_CRSF", false);
    uint8_t output_addr = (uint8_t)env_int("OUTPUT_CRSF_ADDR", 0xC8);
    if (read_chunk < 1 || read_chunk > 2048) {
        read_chunk = 64;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    struct sched_param sp;
    memset(&sp, 0, sizeof(sp));
    sp.sched_priority = 20;
    if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0) {
        log_msg("WARN", "SCHED_FIFO unavailable: %s", strerror(errno));
    }

    int serial_fd = open_serial(serial_port, baudrate);
    if (serial_fd < 0) {
        return 1;
    }

    struct sockaddr_in dest;
    int udp_fd = open_udp_sender(camera_ip, camera_port, &dest);
    if (udp_fd < 0) {
        close(serial_fd);
        return 1;
    }

    log_msg("INFO", "C bridge started: %s @ %d -> udp %s:%d, read_chunk=%d, normalize_crsf=%s, output_addr=0x%02X",
            serial_port, baudrate, camera_ip, camera_port, read_chunk,
            normalize_crsf ? "on" : "off", output_addr);

    uint8_t *buf = calloc((size_t)read_chunk, 1);
    if (!buf) {
        log_msg("ERROR", "calloc failed");
        close(serial_fd);
        close(udp_fd);
        return 1;
    }

    struct pollfd pfd = {
        .fd = serial_fd,
        .events = POLLIN,
        .revents = 0,
    };

    unsigned long long bytes = 0;
    unsigned long long packets = 0;
    unsigned long long frames = 0;
    unsigned long long bad_frames = 0;
    uint8_t pending[512];
    size_t pending_len = 0;
    time_t last_log = time(NULL);

    while (running) {
        int pr = poll(&pfd, 1, 1000);
        if (pr < 0) {
            if (errno == EINTR) {
                continue;
            }
            log_msg("ERROR", "poll failed: %s", strerror(errno));
            break;
        }
        if (pr == 0) {
            continue;
        }
        if (!(pfd.revents & POLLIN)) {
            continue;
        }

        for (;;) {
            ssize_t n = read(serial_fd, buf, (size_t)read_chunk);
            if (n > 0) {
                if (normalize_crsf) {
                    parse_and_forward_crsf(pending, &pending_len, buf, (size_t)n, udp_fd, &dest,
                                           output_addr, &bytes, &packets, &frames, &bad_frames);
                } else {
                    ssize_t sent = send_udp_frame(udp_fd, &dest, buf, (size_t)n);
                    if (sent < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                        log_msg("WARN", "sendto failed: %s", strerror(errno));
                    }
                    bytes += (unsigned long long)n;
                    packets++;
                }
                continue;
            }
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                break;
            }
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n < 0) {
                log_msg("ERROR", "read failed: %s", strerror(errno));
                running = 0;
            }
            break;
        }

        time_t now = time(NULL);
        if (now - last_log >= 30) {
            log_msg("INFO", "forwarded bytes=%llu udp_packets=%llu crsf_frames=%llu bad_frames=%llu",
                    bytes, packets, frames, bad_frames);
            last_log = now;
        }
    }

    log_msg("INFO", "C bridge stopped: bytes=%llu udp_packets=%llu crsf_frames=%llu bad_frames=%llu",
            bytes, packets, frames, bad_frames);
    free(buf);
    close(serial_fd);
    close(udp_fd);
    return 0;
}
