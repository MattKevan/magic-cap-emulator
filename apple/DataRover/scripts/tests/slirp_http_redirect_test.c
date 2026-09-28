// Proves the patched libslirp redirects guest TCP port 80 to a loopback port
// and leaves other destinations alone. Injects raw SYN frames; no guest needed.
#include <slirp/libslirp.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int64_t clock_ns(void *opaque) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque) { return (slirp_ssize_t)len; }
static void guest_error(const char *msg, void *opaque) { fprintf(stderr, "guest error: %s\n", msg); }
static int timer_token;
static void *timer_new(SlirpTimerCb cb, void *cb_opaque, void *opaque) { return &timer_token; }
static void timer_free(void *timer, void *opaque) {}
static void timer_mod(void *timer, int64_t expire, void *opaque) {}
static void register_poll_socket(slirp_os_socket socket, void *opaque) {}
static void unregister_poll_socket(slirp_os_socket socket, void *opaque) {}
static void notify(void *opaque) {}

static uint16_t checksum(const uint8_t *data, size_t len, uint32_t sum) {
    for (size_t i = 0; i + 1 < len; i += 2) sum += (uint32_t)(data[i] << 8 | data[i + 1]);
    if (len & 1) sum += (uint32_t)(data[len - 1] << 8);
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

static void send_syn(Slirp *slirp, const char *dst, uint16_t dport, uint16_t sport) {
    uint8_t f[54] = {0};
    const uint8_t host_mac[6] = {0x52, 0x55, 0x0a, 0x00, 0x02, 0x02};
    const uint8_t guest_mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
    memcpy(f, host_mac, 6); memcpy(f + 6, guest_mac, 6); f[12] = 0x08; f[13] = 0x00;
    uint8_t *ip = f + 14, *tcp = f + 34;
    ip[0] = 0x45; ip[3] = 40; ip[6] = 0x40; ip[8] = 64; ip[9] = 6;
    inet_pton(AF_INET, "10.0.2.15", ip + 12); inet_pton(AF_INET, dst, ip + 16);
    uint16_t ipsum = checksum(ip, 20, 0); ip[10] = ipsum >> 8; ip[11] = ipsum & 0xff;
    tcp[0] = sport >> 8; tcp[1] = sport & 0xff; tcp[2] = dport >> 8; tcp[3] = dport & 0xff;
    tcp[7] = 1; tcp[12] = 5 << 4; tcp[13] = 0x02; tcp[14] = 0xff; tcp[15] = 0xff;
    uint8_t pseudo[12]; memcpy(pseudo, ip + 12, 8); pseudo[8] = 0; pseudo[9] = 6; pseudo[10] = 0; pseudo[11] = 20;
    uint32_t partial = 0;
    for (int i = 0; i < 12; i += 2) partial += (uint32_t)(pseudo[i] << 8 | pseudo[i + 1]);
    uint16_t tsum = checksum(tcp, 20, partial); tcp[16] = tsum >> 8; tcp[17] = tsum & 0xff;
    slirp_input(slirp, f, sizeof f);
}

static int listener(uint16_t *port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = 0 };
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 4)) { perror("listen"); exit(2); }
    socklen_t len = sizeof a; getsockname(fd, (struct sockaddr *)&a, &len);
    *port = ntohs(a.sin_port);
    return fd;
}

// 1 when a connection arrives within timeout_ms.
static int accepted(int fd, int timeout_ms) {
    struct pollfd p = { .fd = fd, .events = POLLIN };
    if (poll(&p, 1, timeout_ms) != 1) return 0;
    int c = accept(fd, NULL, NULL);
    if (c >= 0) close(c);
    return c >= 0;
}

static void require(int ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL %s\n", what); exit(1); }
    printf("ok   %s\n", what);
}

int main(void) {
    uint16_t redirect_port, other_port;
    int redirect = listener(&redirect_port), other = listener(&other_port);
    SlirpConfig cfg = {0};
    cfg.version = SLIRP_CONFIG_VERSION_MAX; cfg.in_enabled = true;
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork); inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost); inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    cfg.if_mtu = 1500; cfg.if_mru = 1500;
    SlirpCb cb = { .send_packet = send_packet, .guest_error = guest_error, .clock_get_ns = clock_ns,
                   .timer_new = timer_new, .timer_free = timer_free, .timer_mod = timer_mod,
                   .register_poll_socket = register_poll_socket,
                   .unregister_poll_socket = unregister_poll_socket, .notify = notify };
    Slirp *slirp = slirp_new(&cfg, &cb, NULL);
    require(slirp != NULL, "slirp_new");

    slirp_set_http_redirect_port(slirp, redirect_port);
    send_syn(slirp, "93.184.216.34", 80, 40001);
    require(accepted(redirect, 2000), "public :80 reaches the redirect port");
    send_syn(slirp, "10.0.2.2", 80, 40002);
    require(accepted(redirect, 2000), "10.0.2.2:80 reaches the redirect port");
    send_syn(slirp, "10.0.2.2", other_port, 40003);
    require(accepted(other, 2000) && !accepted(redirect, 200), "10.0.2.2:<other> is unchanged");

    slirp_set_http_redirect_port(slirp, 0);
    send_syn(slirp, "10.0.2.2", 80, 40004);
    require(!accepted(redirect, 300), "port 0 disables the redirect");

    slirp_cleanup(slirp);
    puts("PASS libslirp http redirect");
    return 0;
}
