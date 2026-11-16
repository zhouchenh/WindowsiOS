/* Port forwards end to end: host/net_slirp.c over the real libslirp (Homebrew's), with a stand-in guest at 10.0.2.15
   that answers ARP and echoes TCP and UDP on any port. Clients on this Mac connect to the forwarded ports and must get
   their bytes back through libslirp and the guest. No network is needed (the local-network case also uses this Mac's
   own Wi-Fi or Ethernet address when it has one).

   Each scenario runs in its own process, since net_slirp.c attaches once:
   - rules: a forward saved in the store before the network starts is open once it runs (127.0.0.1 and [::1]); TCP,
     UDP and TCP+UDP forwards added at run time work over IPv4 and IPv6; removing one closes its ports; editing one
     moves it; turning one off closes it; "local network" listens on every interface (0.0.0.0 and [::]); "VPN" waits
     for a VPN interface and follows it when it appears (HV_NET_VPN_IF names lo0 as the VPN here); a port another
     program holds is reported as in use and tried again until it is free; a second forward of a port is refused;
     expose-port (hv_net_add_hostfwd) shows up as a session forward and is not saved; what the guest may ask for is
     limited; the store file holds the saved forwards only.
   - a damaged store is put aside (<path>.bad) and the list starts empty.
   - HV_NET_FWD_RULES=0: saved forwards are listed but not opened. */
#include "net_slirp.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures;
static void check(const char *what, int ok) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    }
}
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void wr16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 8), p[1] = (uint8_t)v; }
static void wr32(uint8_t *p, uint32_t v) { wr16(p, v >> 16), wr16(p + 2, v); }

/* ---- stand-ins for the machine and the virtio-net device ---- */

void hv_machine_wake(HvMachine *m) { (void)m; }

static HvVirtioNet net;
static const uint8_t GUEST_MAC[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56};
static const uint8_t GUEST_IP[4] = {10, 0, 2, 15};

static uint32_t sum16(uint32_t s, const uint8_t *p, uint32_t n) {
    for (uint32_t i = 0; i + 1 < n; i += 2) s += (uint32_t)(p[i] << 8 | p[i + 1]);
    if (n & 1) s += (uint32_t)p[n - 1] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return s;
}

/* ---- the guest: ARP, and an echo on every TCP and UDP port ---- */

typedef struct Conn {
    int used;
    uint8_t peer[4];
    uint16_t pport, lport;
    uint32_t rcv_nxt, snd_nxt;
} Conn;
static Conn conns[64];
static uint16_t ip_id = 1;
static int guest_tcp_syns, guest_udp_datagrams;
static pthread_mutex_t guest_mu = PTHREAD_MUTEX_INITIALIZER;

static void send_guest(uint8_t *f, uint32_t len) { net.transmit(net.opaque, f, len); }

/* An IPv4 frame from the guest to peer with protocol proto and a payload of n bytes after the IP header. */
static uint8_t *ip4(uint8_t *f, const uint8_t *dst_mac, const uint8_t *peer, uint8_t proto, uint32_t n) {
    memset(f, 0, 14 + 20 + n);
    memcpy(f, dst_mac, 6), memcpy(f + 6, GUEST_MAC, 6);
    f[12] = 8, f[13] = 0;
    uint8_t *ip = f + 14;
    ip[0] = 0x45, wr16(ip + 2, 20 + n), wr16(ip + 4, ip_id++), ip[8] = 64, ip[9] = proto;
    memcpy(ip + 12, GUEST_IP, 4), memcpy(ip + 16, peer, 4);
    wr16(ip + 10, (uint16_t)~sum16(0, ip, 20));
    return ip + 20;
}

static void tcp_out(const uint8_t *dst_mac, Conn *c, uint8_t flags, const uint8_t *data, uint32_t n) {
    uint8_t f[14 + 20 + 20 + 1500];
    if (n > 1460) n = 1460;
    uint8_t *t = ip4(f, dst_mac, c->peer, 6, 20 + n);
    wr16(t, c->lport), wr16(t + 2, c->pport), wr32(t + 4, c->snd_nxt), wr32(t + 8, c->rcv_nxt);
    t[12] = 5 << 4, t[13] = flags, wr16(t + 14, 65535);
    if (n) memcpy(t + 20, data, n);
    uint8_t pseudo[12];
    memcpy(pseudo, GUEST_IP, 4), memcpy(pseudo + 4, c->peer, 4), pseudo[8] = 0, pseudo[9] = 6, wr16(pseudo + 10, 20 + n);
    wr16(t + 16, (uint16_t)~sum16(sum16(0, pseudo, 12), t, 20 + n));
    send_guest(f, 14 + 20 + 20 + n);
}

static void guest_frame(const uint8_t *f, uint32_t len) {
    if (len >= 42 && f[12] == 8 && f[13] == 6 && rd16(f + 20) == 1 && !memcmp(f + 38, GUEST_IP, 4)) { /* ARP who-has */
        uint8_t r[42];
        memcpy(r, f + 6, 6), memcpy(r + 6, GUEST_MAC, 6);
        r[12] = 8, r[13] = 6;
        wr16(r + 14, 1), wr16(r + 16, 0x800), r[18] = 6, r[19] = 4, wr16(r + 20, 2);
        memcpy(r + 22, GUEST_MAC, 6), memcpy(r + 28, GUEST_IP, 4);
        memcpy(r + 32, f + 22, 6), memcpy(r + 38, f + 28, 4);
        send_guest(r, 42);
        return;
    }
    if (len < 34 || f[12] != 8 || f[13] != 0) return;
    const uint8_t *ip = f + 14;
    uint32_t ihl = (ip[0] & 15) * 4u, tot = rd16(ip + 2);
    if (memcmp(ip + 16, GUEST_IP, 4) || tot > len - 14 || tot < ihl) return;
    const uint8_t *l4 = ip + ihl;
    uint32_t n = tot - ihl;
    if (ip[9] == 17 && n >= 8) { /* UDP: echo */
        uint32_t dl = rd16(l4 + 4) - 8u;
        if (dl > n - 8) return;
        uint8_t r[14 + 20 + 8 + 1500];
        if (dl > 1472) return;
        uint8_t *u = ip4(r, f + 6, ip + 12, 17, 8 + dl);
        wr16(u, rd16(l4 + 2)), wr16(u + 2, rd16(l4)), wr16(u + 4, 8 + dl), wr16(u + 6, 0);
        memcpy(u + 8, l4 + 8, dl);
        pthread_mutex_lock(&guest_mu);
        guest_udp_datagrams++;
        pthread_mutex_unlock(&guest_mu);
        send_guest(r, 14 + 20 + 8 + dl);
        return;
    }
    if (ip[9] != 6 || n < 20) return;
    uint32_t off = (l4[12] >> 4) * 4u;
    if (off < 20 || off > n) return;
    uint8_t flags = l4[13];
    uint16_t sport = rd16(l4), dport = rd16(l4 + 2);
    uint32_t seq = rd32(l4 + 4), dl = n - off;
    Conn *c = NULL;
    for (int i = 0; i < 64; i++)
        if (conns[i].used && conns[i].pport == sport && conns[i].lport == dport && !memcmp(conns[i].peer, ip + 12, 4))
            c = &conns[i];
    if (flags & 0x04) { /* RST */
        if (c) c->used = 0;
        return;
    }
    if ((flags & 0x02) && !(flags & 0x10)) { /* SYN */
        if (!c)
            for (int i = 0; i < 64 && !c; i++)
                if (!conns[i].used) c = &conns[i];
        if (!c) return;
        c->used = 1, memcpy(c->peer, ip + 12, 4), c->pport = sport, c->lport = dport;
        c->rcv_nxt = seq + 1, c->snd_nxt = 7000;
        pthread_mutex_lock(&guest_mu);
        guest_tcp_syns++;
        pthread_mutex_unlock(&guest_mu);
        tcp_out(f + 6, c, 0x12, NULL, 0); /* SYN+ACK */
        c->snd_nxt++;
        return;
    }
    if (!c) return;
    if (seq != c->rcv_nxt) { /* a repeat: say where we are */
        tcp_out(f + 6, c, 0x10, NULL, 0);
        return;
    }
    if (dl) {
        c->rcv_nxt += dl;
        tcp_out(f + 6, c, 0x18, l4 + off, dl); /* the same bytes back */
        c->snd_nxt += dl;
    }
    if (flags & 0x01) { /* FIN: close our side too */
        c->rcv_nxt++;
        tcp_out(f + 6, c, 0x11, NULL, 0);
        c->snd_nxt++;
        c->used = 0;
    }
}

int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *frame, uint32_t len) {
    (void)n;
    guest_frame(frame, len);
    return 1;
}

static _Atomic int guest_stop;
static void *guest_thread(void *arg) {
    (void)arg;
    /* An unasked ARP reply, so libslirp knows the guest's MAC before it forwards anything. */
    uint8_t r[42] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    memcpy(r + 6, GUEST_MAC, 6);
    r[12] = 8, r[13] = 6;
    wr16(r + 14, 1), wr16(r + 16, 0x800), r[18] = 6, r[19] = 4, wr16(r + 20, 2);
    memcpy(r + 22, GUEST_MAC, 6), memcpy(r + 28, GUEST_IP, 4);
    r[38] = 10, r[40] = 2, r[41] = 2;
    send_guest(r, 42);
    while (!guest_stop) {
        hv_net_poll();
        usleep(300);
    }
    return NULL;
}

/* ---- clients on this Mac ---- */

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static socklen_t make_addr(struct sockaddr_storage *ss, const char *addr, int port) {
    memset(ss, 0, sizeof *ss);
    struct sockaddr_in *a4 = (struct sockaddr_in *)ss;
    struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)ss;
    if (inet_pton(AF_INET, addr, &a4->sin_addr) == 1) {
        a4->sin_len = sizeof *a4, a4->sin_family = AF_INET, a4->sin_port = htons((uint16_t)port);
        return sizeof *a4;
    }
    if (inet_pton(AF_INET6, addr, &a6->sin6_addr) == 1) {
        a6->sin6_len = sizeof *a6, a6->sin6_family = AF_INET6, a6->sin6_port = htons((uint16_t)port);
        return sizeof *a6;
    }
    exit(2);
}

/* Connects within 3 s: 1, 0 when refused (*refused set) or timed out. */
static int tcp_connect(const char *addr, int port, int *fd_out, int *refused) {
    struct sockaddr_storage ss;
    socklen_t sl = make_addr(&ss, addr, port);
    int fd = socket(ss.ss_family, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    *refused = 0;
    int rc = connect(fd, (struct sockaddr *)&ss, sl);
    if (rc != 0 && errno == EINPROGRESS) {
        struct pollfd p = {fd, POLLOUT, 0};
        int err = 0;
        socklen_t el = sizeof err;
        if (poll(&p, 1, 3000) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) == 0 && err == 0) rc = 0;
        else errno = err ? err : ETIMEDOUT;
    }
    if (rc != 0) {
        *refused = errno == ECONNREFUSED;
        close(fd);
        return 0;
    }
    fcntl(fd, F_SETFL, 0);
    *fd_out = fd;
    return 1;
}

/* What the guest echoes, within 3 s. Through a forward, a connection is accepted on this Mac at once and closed if
   the guest does not answer, so "got the bytes back" is the test, not "connected". */
static int tcp_echo(const char *addr, int port) {
    int fd, refused;
    if (!tcp_connect(addr, port, &fd, &refused)) return 0;
    char msg[64], got[64];
    int n = snprintf(msg, sizeof msg, "hello %s %d", addr, port);
    if (send(fd, msg, (size_t)n, 0) != n) return close(fd), 0;
    int have = 0;
    int64_t end = now_ms() + 3000;
    while (have < n && now_ms() < end) {
        struct pollfd p = {fd, POLLIN, 0};
        if (poll(&p, 1, 200) <= 0) continue;
        ssize_t r = recv(fd, got + have, sizeof got - (size_t)have, 0);
        if (r <= 0) break;
        have += (int)r;
    }
    close(fd);
    return have == n && !memcmp(msg, got, (size_t)n);
}

/* Nothing listens: refused, or (through a stale relay) closed without an answer. */
static int tcp_closed(const char *addr, int port) {
    int fd, refused;
    if (!tcp_connect(addr, port, &fd, &refused)) return refused;
    close(fd);
    return 0;
}

static int udp_echo(const char *addr, int port) {
    struct sockaddr_storage ss;
    socklen_t sl = make_addr(&ss, addr, port);
    int fd = socket(ss.ss_family, SOCK_DGRAM, 0);
    char msg[64], got[64];
    int n = snprintf(msg, sizeof msg, "udp %s %d", addr, port), ok = 0;
    for (int tries = 0; tries < 6 && !ok; tries++) { /* the first datagram may wait for ARP */
        if (sendto(fd, msg, (size_t)n, 0, (struct sockaddr *)&ss, sl) != n) break;
        struct pollfd p = {fd, POLLIN, 0};
        if (poll(&p, 1, 500) == 1) {
            ssize_t r = recv(fd, got, sizeof got, 0);
            ok = r == n && !memcmp(msg, got, (size_t)n);
        }
    }
    close(fd);
    return ok;
}

/* A port that is free for TCP and UDP on IPv4 and IPv6 right now. */
static int free_port(void) {
    for (int tries = 0; tries < 50; tries++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET};
        socklen_t al = sizeof a;
        if (bind(s, (struct sockaddr *)&a, sizeof a) || getsockname(s, (struct sockaddr *)&a, &al)) exit(2);
        int port = ntohs(a.sin_port);
        close(s);
        int ok = 1;
        int kinds[4][2] = {{AF_INET, SOCK_DGRAM}, {AF_INET6, SOCK_STREAM}, {AF_INET6, SOCK_DGRAM}, {AF_INET, SOCK_STREAM}};
        for (int k = 0; k < 4 && ok; k++) {
            struct sockaddr_storage ss;
            socklen_t sl = make_addr(&ss, kinds[k][0] == AF_INET ? "0.0.0.0" : "::", port);
            s = socket(kinds[k][0], kinds[k][1], 0);
            int one = 1;
            if (kinds[k][0] == AF_INET6) setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
            ok = bind(s, (struct sockaddr *)&ss, sl) == 0;
            close(s);
        }
        if (ok) return port;
    }
    exit(2);
}

/* Binding addr:port ourselves fails with EADDRINUSE: something listens there. */
static int in_use(int type, const char *addr, int port) {
    struct sockaddr_storage ss;
    socklen_t sl = make_addr(&ss, addr, port);
    int s = socket(ss.ss_family, type, 0), one = 1;
    if (ss.ss_family == AF_INET6) setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
    int rc = bind(s, (struct sockaddr *)&ss, sl), e = errno;
    close(s);
    return rc != 0 && e == EADDRINUSE;
}

/* ---- the list ---- */

/* The JSON object of the forward with this id ("" if none), from the list. */
static void rule_json(const char *id, char *out, size_t cap) {
    char *all = hv_net_fwd_list_json(), key[80];
    snprintf(key, sizeof key, "{\"id\":\"%s\"", id);
    char *p = strstr(all, key);
    out[0] = 0;
    if (p) {
        char *e = strstr(p, "]}");
        size_t n = e ? (size_t)(e - p) + 2 : strlen(p);
        snprintf(out, cap, "%.*s", (int)n, p);
    }
    free(all);
}
static int has(const char *id, const char *what) {
    char j[2048];
    rule_json(id, j, sizeof j);
    return j[0] && strstr(j, what) != NULL;
}
/* Waits up to ms for the forward's JSON to contain what. */
static int wait_for(const char *id, const char *what, int ms) {
    int64_t end = now_ms() + ms;
    do {
        hv_net_fwd_sync(1000);
        if (has(id, what)) return 1;
        usleep(50 * 1000);
    } while (now_ms() < end);
    char j[2048];
    rule_json(id, j, sizeof j);
    fprintf(stderr, "  (forward %s: %s)\n", id, j[0] ? j : "not listed");
    return 0;
}

static HvFwdRule rule(const char *id, int proto, int hp, int gp, int scope) {
    HvFwdRule r = {.proto = proto, .host_port = hp, .guest_port = gp, .scope = scope, .enabled = 1};
    snprintf(r.id, sizeof r.id, "%s", id);
    snprintf(r.name, sizeof r.name, "test %s", id);
    return r;
}
static void put(HvFwdRule r) {
    char err[160];
    if (hv_net_fwd_put(&r, HV_FWD_SAVED, err, sizeof err) != 0) {
        fprintf(stderr, "FAIL: put %s: %s\n", r.id, err);
        failures++;
    }
}

/* A non-loopback IPv4 address of this Mac (Wi-Fi or Ethernet), if it has one. */
static int lan_ipv4(char *out, size_t cap) {
    struct ifaddrs *ifa;
    if (getifaddrs(&ifa)) return 0;
    int found = 0;
    for (struct ifaddrs *i = ifa; i && !found; i = i->ifa_next)
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET && (i->ifa_flags & IFF_UP) && !(i->ifa_flags & IFF_LOOPBACK) &&
            !strncmp(i->ifa_name, "en", 2)) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, out, (socklen_t)cap);
            found = strncmp(out, "169.254.", 8) != 0;
        }
    freeifaddrs(ifa);
    return found;
}

static char dir[256];
static void store_file(char *out, size_t cap, const char *name) { snprintf(out, cap, "%s/%s", dir, name); }
static char *read_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    static char buf[65536];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    buf[n] = 0;
    fclose(f);
    return buf;
}

static void start_net(void) {
    if (hv_net_attach(NULL, &net) != 0) {
        fprintf(stderr, "FAIL: hv_net_attach\n");
        exit(1);
    }
    pthread_t t;
    pthread_create(&t, NULL, guest_thread, NULL);
}

/* ---- scenarios ---- */

static int scenario_rules(void) {
    char path[512], what[128];
    store_file(path, sizeof path, "rules.json");
    int p_saved = free_port();
    FILE *f = fopen(path, "w");
    fprintf(f, "{\"version\": 1, \"rules\": [{\"id\": \"saved\", \"name\": \"Saved \\u00e9\", \"protocol\": \"tcp\", "
               "\"hostPort\": %d, \"guestPort\": 7, \"scope\": \"loopback\", \"enabled\": true, \"future\": [1, {\"x\": null}]}]}\n",
            p_saved);
    fclose(f);
    unsetenv("HV_NET_FWD");
    unsetenv("HV_NET_FWD_RULES");
    setenv("HV_NET_VPN_IF", "nothing", 1);
    check("store loads", hv_net_fwd_set_store(path) == 0);
    check("before the network runs: waiting", has("saved", "\"state\":\"waiting\""));
    check("name with an escape", has("saved", "\"name\":\"Saved \xc3\xa9\""));
    start_net();

    /* The saved one, opened at start. */
    snprintf(what, sizeof what, "\"listen\":[\"127.0.0.1:%d\",\"[::1]:%d\"]", p_saved, p_saved);
    check("saved forward listening on 127.0.0.1 and [::1]", wait_for("saved", what, 3000));
    check("saved forward: TCP over IPv4", tcp_echo("127.0.0.1", p_saved));
    check("saved forward: TCP over IPv6", tcp_echo("::1", p_saved));

    /* UDP, and TCP+UDP. */
    int p_udp = free_port(), p_both = free_port();
    put(rule("udp", HV_FWD_UDP, p_udp, 9, HV_FWD_LOOPBACK));
    put(rule("both", HV_FWD_BOTH, p_both, 3389, HV_FWD_LOOPBACK));
    check("UDP forward listening", wait_for("udp", "\"state\":\"listening\"", 3000));
    check("UDP forward: IPv4", udp_echo("127.0.0.1", p_udp));
    check("UDP forward: IPv6", udp_echo("::1", p_udp));
    check("UDP forward: no TCP", tcp_closed("127.0.0.1", p_udp));
    check("TCP+UDP forward listening", wait_for("both", "\"state\":\"listening\"", 3000));
    check("TCP+UDP forward: TCP", tcp_echo("127.0.0.1", p_both) && tcp_echo("::1", p_both));
    check("TCP+UDP forward: UDP", udp_echo("127.0.0.1", p_both) && udp_echo("::1", p_both));
    pthread_mutex_lock(&guest_mu);
    check("the guest saw the connections and datagrams", guest_tcp_syns >= 4 && guest_udp_datagrams >= 4);
    pthread_mutex_unlock(&guest_mu);

    /* A second forward of a port is refused. */
    char err[160] = "";
    HvFwdRule dup = rule("dup", HV_FWD_TCP, p_both, 22, HV_FWD_LAN);
    check("a port already forwarded is refused", hv_net_fwd_put(&dup, HV_FWD_SAVED, err, sizeof err) != 0 &&
                                                     strstr(err, "already forwarded"));
    HvFwdRule dup_off = rule("dup-off", HV_FWD_TCP, p_both, 22, HV_FWD_LAN);
    dup_off.enabled = 0;
    check("... but may be kept turned off", hv_net_fwd_put(&dup_off, HV_FWD_SAVED, err, sizeof err) == 0);
    check("the turned-off one is off", wait_for("dup-off", "\"state\":\"off\"", 1000));

    /* Removing closes, on IPv4 and IPv6. */
    check("remove", hv_net_fwd_remove("udp", 0) == 0);
    check("remove: no such forward any more", hv_net_fwd_remove("udp", 0) != 0);
    hv_net_fwd_sync(2000);
    check("removed UDP forward: the port is free (IPv4)", !in_use(SOCK_DGRAM, "127.0.0.1", p_udp));
    check("removed UDP forward: the port is free (IPv6)", !in_use(SOCK_DGRAM, "::1", p_udp));
    check("removed forward is not listed", !has("udp", "\"id\""));

    /* Editing moves it: same id, another port. */
    int p_moved = free_port();
    put(rule("both", HV_FWD_TCP, p_moved, 3389, HV_FWD_LOOPBACK));
    check("edited forward listening", wait_for("both", "\"state\":\"listening\"", 3000));
    check("edited forward: the new port works", tcp_echo("127.0.0.1", p_moved) && tcp_echo("::1", p_moved));
    check("edited forward: the old port is closed", tcp_closed("127.0.0.1", p_both) && tcp_closed("::1", p_both));
    check("edited forward: its old UDP port is free", !in_use(SOCK_DGRAM, "127.0.0.1", p_both));

    /* Turned off. */
    HvFwdRule off = rule("both", HV_FWD_TCP, p_moved, 3389, HV_FWD_LOOPBACK);
    off.enabled = 0;
    put(off);
    check("turned off", wait_for("both", "\"state\":\"off\"", 2000));
    /* (Refused, not "can bind it": a relayed connection may linger in TIME_WAIT on the port.) */
    check("turned off: closed", tcp_closed("127.0.0.1", p_moved) && tcp_closed("::1", p_moved));

    /* Local network: every interface. */
    int p_lan = free_port();
    put(rule("lan", HV_FWD_BOTH, p_lan, 7, HV_FWD_LAN));
    snprintf(what, sizeof what, "\"listen\":[\"0.0.0.0:%d\",\"[::]:%d\"]", p_lan, p_lan);
    check("local network forward on 0.0.0.0 and [::]", wait_for("lan", what, 3000));
    check("local network forward: 0.0.0.0 taken (TCP)", in_use(SOCK_STREAM, "0.0.0.0", p_lan));
    check("local network forward: [::] taken (UDP)", in_use(SOCK_DGRAM, "::", p_lan));
    check("local network forward: through loopback", tcp_echo("127.0.0.1", p_lan) && tcp_echo("::1", p_lan));
    check("local network forward: UDP", udp_echo("127.0.0.1", p_lan) && udp_echo("::1", p_lan));
    char lan[64];
    if (lan_ipv4(lan, sizeof lan)) {
        check("local network forward: through this Mac's own LAN address (TCP)", tcp_echo(lan, p_lan));
        check("local network forward: through this Mac's own LAN address (UDP)", udp_echo(lan, p_lan));
    } else {
        printf("fwd: no LAN address on this Mac, the LAN-address checks are skipped\n");
    }
    char *addrs = hv_net_fwd_addresses_json();
    check("addresses JSON", addrs && !strncmp(addrs, "{\"lan\":[", 8) && strstr(addrs, "\"vpn\":[]"));
    if (lan_ipv4(lan, sizeof lan)) check("addresses list the LAN address", addrs && strstr(addrs, lan));
    free(addrs);

    /* VPN: none yet, then lo0 plays the VPN. */
    int p_vpn = free_port();
    put(rule("vpn", HV_FWD_TCP, p_vpn, 7, HV_FWD_VPN));
    check("VPN forward without a VPN", wait_for("vpn", "\"code\":\"no_vpn\"", 2000));
    check("VPN forward without a VPN: nothing open", tcp_closed("127.0.0.1", p_vpn));
    setenv("HV_NET_VPN_IF", "lo0", 1);
    hv_net_fwd_refresh();
    snprintf(what, sizeof what, "\"listen\":[\"127.0.0.1:%d\",\"[::1]:%d\"]", p_vpn, p_vpn);
    check("VPN forward follows the VPN when it comes", wait_for("vpn", what, 3000));
    check("VPN forward works", tcp_echo("127.0.0.1", p_vpn) && tcp_echo("::1", p_vpn));
    addrs = hv_net_fwd_addresses_json();
    check("addresses list the VPN", addrs && strstr(addrs, "\"vpn\":[{\"interface\":\"lo0\",\"address\":\"127.0.0.1\""));
    free(addrs);
    setenv("HV_NET_VPN_IF", "nothing", 1); /* gone again: noticed by the timer */
    check("VPN forward closes when the VPN goes", wait_for("vpn", "\"code\":\"no_vpn\"", 5000));
    check("VPN forward closed", tcp_closed("127.0.0.1", p_vpn));

    /* A port another program holds: in use, then open once it is free (the timer retries). */
    int p_busy = free_port();
    struct sockaddr_storage ss;
    socklen_t sl = make_addr(&ss, "127.0.0.1", p_busy);
    int holder = socket(AF_INET, SOCK_STREAM, 0);
    if (bind(holder, (struct sockaddr *)&ss, sl) || listen(holder, 1)) exit(2);
    put(rule("busy", HV_FWD_TCP, p_busy, 7, HV_FWD_LOOPBACK));
    check("port in use is reported", wait_for("busy", "\"code\":\"in_use\"", 2000) && has("busy", "\"state\":\"error\""));
    close(holder);
    check("... and opened once it is free", wait_for("busy", "\"state\":\"listening\"", 6000));
    check("... and works", tcp_echo("127.0.0.1", p_busy));

    /* Opened again (as after the app comes back from the background): still working. */
    hv_net_fwd_reopen();
    check("reopen: synced", hv_net_fwd_sync(3000) == 0);
    check("reopen: still listening", has("busy", "\"state\":\"listening\"") && has("lan", "\"state\":\"listening\""));
    check("reopen: works", tcp_echo("127.0.0.1", p_busy) && tcp_echo("::1", p_lan) && udp_echo("::1", p_lan));

    /* expose-port: a session forward, listed, not saved; the same port again changes nothing. */
    int p_exp = free_port();
    hv_net_add_hostfwd(p_exp, 7);
    hv_net_add_hostfwd(p_exp, 7);
    char sid[48];
    snprintf(sid, sizeof sid, "session-tcp-%d", p_exp);
    check("expose-port listed as a session forward", wait_for(sid, "\"session\":true", 2000) &&
                                                         wait_for(sid, "\"state\":\"listening\"", 2000));
    check("expose-port works over IPv4 and IPv6", tcp_echo("127.0.0.1", p_exp) && tcp_echo("::1", p_exp));
    hv_net_add_hostfwd(80, 80);
    check("expose-port below 1024 is ignored", !has("session-tcp-80", "\"id\""));

    /* What the guest may ask for (/.henge/forwards): loopback only, from 1024, not the app's forwards. */
    HvFwdRule g = rule("", HV_FWD_UDP, 80, 80, HV_FWD_LAN);
    check("guest: port below 1024 refused", hv_net_fwd_put(&g, HV_FWD_GUEST, err, sizeof err) != 0);
    int p_guest = free_port();
    g = rule("", HV_FWD_UDP, p_guest, 7, HV_FWD_LAN);
    check("guest: accepted", hv_net_fwd_put(&g, HV_FWD_GUEST, err, sizeof err) == 0 && g.id[0]);
    check("guest: kept on loopback", wait_for(g.id, "\"scope\":\"loopback\"", 1000) &&
                                         wait_for(g.id, "\"state\":\"listening\"", 2000));
    check("guest: works", udp_echo("127.0.0.1", p_guest));
    HvFwdRule steal = rule("lan", HV_FWD_TCP, free_port(), 7, HV_FWD_LOOPBACK);
    check("guest: cannot replace the app's forward", hv_net_fwd_put(&steal, HV_FWD_GUEST, err, sizeof err) != 0);
    check("guest: can only remove its own", hv_net_fwd_remove("lan", 1) != 0 && hv_net_fwd_remove(g.id, 1) == 0);
    HvFwdRule parsed = {.proto = HV_FWD_TCP};
    const char *js = "{\"protocol\":\"tcp+udp\",\"hostPort\":5000,\"guestPort\":22,\"name\":\"a\\\"b\",\"scope\":\"vpn\"}";
    check("parse a forward", hv_net_fwd_parse_rule(js, strlen(js), &parsed) == 0 && parsed.proto == HV_FWD_BOTH &&
                                 parsed.host_port == 5000 && parsed.guest_port == 22 && !strcmp(parsed.name, "a\"b") &&
                                 parsed.scope == HV_FWD_VPN);
    const char *bad[] = {"{\"protocol\":\"icmp\"}", "{\"hostPort\":\"x\"}", "{\"hostPort\":1.5}", "{", "{}x",
                         "{\"name\":\"\\ud800\"}", "[]"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        snprintf(what, sizeof what, "parse refuses %s", bad[i]);
        check(what, hv_net_fwd_parse_rule(bad[i], strlen(bad[i]), &parsed) != 0);
    }

    /* The store: the saved forwards, not the session ones. */
    hv_net_fwd_sync(1000);
    const char *text = read_file(path);
    check("store written", text != NULL);
    if (text) {
        check("store has the saved forwards", strstr(text, "\"id\": \"saved\"") && strstr(text, "\"id\": \"lan\"") &&
                                                  strstr(text, "\"id\": \"busy\"") && strstr(text, "\"id\": \"vpn\""));
        check("store: TCP+UDP and the scope", strstr(text, "\"protocol\": \"tcp+udp\"") && strstr(text, "\"scope\": \"lan\""));
        check("store: the turned-off one is kept, off", strstr(text, "\"id\": \"both\"") && strstr(text, "\"enabled\": false"));
        check("store: removed and session forwards are not", !strstr(text, "\"id\": \"udp\"") && !strstr(text, "session-"));
        check("store: the name kept as UTF-8", strstr(text, "Saved \xc3\xa9") != NULL);
    }
    /* Read back as a fresh list (another path, then this one again). */
    char copy[512];
    store_file(copy, sizeof copy, "copy.json");
    FILE *c = fopen(copy, "w");
    if (c && text) fputs(text, c);
    if (c) fclose(c);
    check("store reloads", hv_net_fwd_set_store(copy) == 0);
    check("reloaded: saved forward kept and listening", wait_for("saved", "\"state\":\"listening\"", 3000));
    check("reloaded: the session forward stays", has(sid, "\"session\":true"));
    check("reloaded: works", tcp_echo("127.0.0.1", p_saved) && tcp_echo("127.0.0.1", p_lan));

    guest_stop = 1;
    printf("fwd (rules): %d failures\n", failures);
    fflush(stdout);
    return failures != 0;
}

static int scenario_bad_store(void) {
    char path[512], moved[600];
    store_file(path, sizeof path, "bad.json");
    FILE *f = fopen(path, "w");
    fputs("{\"rules\": [{\"id\": \"x\", \"hostPort\": ", f);
    fclose(f);
    check("damaged store: -1", hv_net_fwd_set_store(path) != 0);
    snprintf(moved, sizeof moved, "%s.bad", path);
    struct stat st;
    check("damaged store kept aside", stat(moved, &st) == 0 && stat(path, &st) != 0);
    char *list = hv_net_fwd_list_json();
    check("damaged store: an empty list", list && !strcmp(list, "{\"running\":false,\"rules\":[]}"));
    free(list);
    HvFwdRule r = rule("new", HV_FWD_TCP, 4000, 7, HV_FWD_LOOPBACK);
    char err[160];
    check("damaged store: new forwards are saved", hv_net_fwd_put(&r, HV_FWD_SAVED, err, sizeof err) == 0 &&
                                                       read_file(path) && strstr(read_file(path), "\"id\": \"new\""));
    printf("fwd (damaged store): %d failures\n", failures);
    fflush(stdout);
    return failures != 0;
}

static int scenario_rules_off(void) {
    char path[512];
    store_file(path, sizeof path, "off.json");
    int p = free_port();
    FILE *f = fopen(path, "w");
    fprintf(f, "{\"rules\":[{\"id\":\"a\",\"protocol\":\"tcp\",\"hostPort\":%d,\"guestPort\":7,\"scope\":\"loopback\",\"enabled\":true}]}", p);
    fclose(f);
    setenv("HV_NET_FWD_RULES", "0", 1);
    char env[32];
    int p_env = free_port();
    snprintf(env, sizeof env, "%d:7", p_env);
    setenv("HV_NET_FWD", env, 1);
    setenv("HV_NET_FWD_FILE", path, 1); /* as the Mac tool does */
    start_net();
    check("HV_NET_FWD_RULES=0: saved forward listed but off", wait_for("a", "\"code\":\"env_off\"", 2000) &&
                                                                    has("a", "\"state\":\"off\""));
    check("HV_NET_FWD_RULES=0: nothing open", tcp_closed("127.0.0.1", p));
    char sid[48];
    snprintf(sid, sizeof sid, "session-tcp-%d", p_env);
    check("HV_NET_FWD still works (a session forward)", wait_for(sid, "\"state\":\"listening\"", 2000) &&
                                                             tcp_echo("127.0.0.1", p_env));
    guest_stop = 1;
    printf("fwd (HV_NET_FWD_RULES=0): %d failures\n", failures);
    fflush(stdout);
    return failures != 0;
}

int main(void) {
    const char *tmp = getenv("TMPDIR");
    snprintf(dir, sizeof dir, "%s/test_net_fwd.XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(dir)) return 2;
    int (*scenarios[])(void) = {scenario_rules, scenario_bad_store, scenario_rules_off};
    const char *names[] = {"rules", "damaged store", "HV_NET_FWD_RULES=0"};
    int bad = 0;
    for (int i = 0; i < 3; i++) {
        fflush(stdout);
        pid_t pid = fork();
        if (pid < 0) return 2;
        if (pid == 0) {
            alarm(90);
            _exit(scenarios[i]());
        }
        int status = 0;
        waitpid(pid, &status, 0);
        if (!WIFEXITED(status) || WEXITSTATUS(status)) {
            fprintf(stderr, "FAIL: scenario %s (status %d)\n", names[i], status);
            bad = 1;
        }
    }
    char cmd[300];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir);
    (void)!system(cmd);
    printf("fwd: %s\n", bad ? "FAILED" : "ok");
    return bad;
}
