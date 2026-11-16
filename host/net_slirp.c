/* The guest's network: user-mode NAT through libslirp (as QEMU's -netdev user),
   so it needs no root and no entitlement. 10.0.2.0/24: the host is 10.0.2.2,
   DNS 10.0.2.3, the guest gets 10.0.2.15 by DHCP. DNS over UDP is answered through the
   host's own resolver (dns_proxy.c, from Henge), not libslirp's choice of name server;
   HV_DNS_PROXY=0 leaves it all to libslirp.

   IPv6 too, unless HV_IPV6=0: the guest configures itself by SLAAC from libslirp's Router
   Advertisements for fd2d:7064:6c3f:2::/64 (host ::2, DNS ::3, the DNS proxy announcing
   ::3 when libslirp would not). The prefix is a unique local one (RFC 4193: fd + a random
   40-bit global ID + subnet 2, like 10.0.2.x), so it cannot clash with real networks, and
   Windows prefers IPv4 for names that have both (RFC 6724: ULA source, global destination).
   docs/networking.md has the whole picture.

   Port forwards (TCP and UDP, from this device's loopback, every interface or the VPN's address into the guest)
   are rules kept in a table and applied on the network thread: see "port forwards" below.

   libslirp is not thread-safe, so it lives on one thread with its sockets and
   timers. Frames the guest sends are queued to it (and the thread woken through
   a pipe); frames for the guest are queued the other way and handed to the
   virtio-net device on the CPU thread (hv_net_poll), which may only take them
   when the guest has posted receive buffers. */
#include "net_slirp.h"
#include "dns_proxy.h"
#include "share.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <libslirp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define QUEUE 512
#define MAX_FRAME 65550
#define MAX_TIMERS 64
#define MAX_POLL 1024

typedef struct Frame {
    uint32_t len;
    uint8_t *data;
} Frame;

typedef struct Queue {
    Frame f[QUEUE];
    uint32_t head, tail;
    pthread_mutex_t mu;
} Queue;

typedef struct Timer {
    int used;
    SlirpTimerId id;
    void *cb_opaque;
    int64_t expire_ms; /* -1: not armed */
} Timer;

static Slirp *slirp;
static HvVirtioNet *net;
static HvMachine *machine;
static Queue to_guest, to_host;
static int wake_pipe[2];
static Timer timers[MAX_TIMERS];
static struct pollfd pfds[MAX_POLL];
static int npfd;
uint64_t hv_net_tx_frames, hv_net_rx_frames;

static char share_socket[256];

/* IPv6 (see the top): the /64 prefix, the host and the name server. */
#define V6_PREFIX "fd2d:7064:6c3f:2::"
#define V6_HOST V6_PREFIX "2"
#define V6_DNS V6_PREFIX "3"

void hv_net_set_share_socket(const char *path) {
    snprintf(share_socket, sizeof share_socket, "%s", path ? path : "");
}

static int push(Queue *q, const uint8_t *data, uint32_t len) {
    pthread_mutex_lock(&q->mu);
    int ok = q->tail - q->head < QUEUE;
    if (ok) {
        Frame *f = &q->f[q->tail % QUEUE];
        f->data = malloc(len);
        memcpy(f->data, data, len);
        f->len = len;
        q->tail++;
    }
    pthread_mutex_unlock(&q->mu);
    return ok;
}

/* HV_NET_LOG: one line per frame (ethertype, IP protocol, ports). */
static void log_frame(const char *dir, const uint8_t *p, uint32_t len) {
    static int on = -1;
    if (on < 0) on = getenv("HV_NET_LOG") != NULL;
    if (!on || len < 14) return;
    unsigned et = p[12] << 8 | p[13];
    if (et == 0x0800 && len >= 34) {
        unsigned ihl = (p[14] & 15) * 4, proto = p[23];
        unsigned sp = 0, dp = 0;
        if ((proto == 6 || proto == 17) && len >= 14 + ihl + 4) {
            sp = p[14 + ihl] << 8 | p[15 + ihl];
            dp = p[16 + ihl] << 8 | p[17 + ihl];
        }
        fprintf(stderr, "net %s ipv4 %u.%u.%u.%u:%u -> %u.%u.%u.%u:%u proto %u len %u\n", dir, p[26], p[27], p[28],
                p[29], sp, p[30], p[31], p[32], p[33], dp, proto, len);
    } else if (et == 0x86dd && len >= 54) {
        char src[INET6_ADDRSTRLEN], dst[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, p + 22, src, sizeof src);
        inet_ntop(AF_INET6, p + 38, dst, sizeof dst);
        unsigned nh = p[20], sp = 0, dp = 0;
        if ((nh == 6 || nh == 17) && len >= 58) sp = p[54] << 8 | p[55], dp = p[56] << 8 | p[57];
        else if (nh == 58 && len >= 55) sp = p[54]; /* ICMPv6: its type */
        fprintf(stderr, "net %s ipv6 [%s]:%u -> [%s]:%u nh %u len %u\n", dir, src, sp, dst, dp, nh, len);
    } else {
        fprintf(stderr, "net %s ethertype %#06x len %u\n", dir, et, len);
    }
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- slirp callbacks (all on the network thread) ---- */

static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque) {
    (void)opaque;
    if (len > MAX_FRAME) return (slirp_ssize_t)len;
    const uint8_t *frame = buf;
    uint32_t n = (uint32_t)len;
    uint8_t ra[1600]; /* a Router Advertisement with the DNS proxy's address added (dns_proxy.c) */
    uint32_t ra_len = n <= sizeof ra - 24 ? hv_dns_proxy_announce(frame, n, ra, sizeof ra) : 0;
    if (ra_len) frame = ra, n = ra_len;
    log_frame("rx", frame, n);
    if (push(&to_guest, frame, n)) hv_machine_wake(machine);
    return (slirp_ssize_t)len;
}

static void guest_error(const char *msg, void *opaque) {
    (void)opaque;
    fprintf(stderr, "hengevm: net: %s\n", msg);
}

static int64_t clock_get_ns(void *opaque) {
    (void)opaque;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void *timer_new_opaque(SlirpTimerId id, void *cb_opaque, void *opaque) {
    (void)opaque;
    for (int i = 0; i < MAX_TIMERS; i++)
        if (!timers[i].used) {
            timers[i] = (Timer){1, id, cb_opaque, -1};
            return &timers[i];
        }
    return NULL;
}

static void timer_free(void *timer, void *opaque) {
    (void)opaque;
    if (timer) ((Timer *)timer)->used = 0;
}

static void timer_mod(void *timer, int64_t expire_ms, void *opaque) {
    (void)opaque;
    if (timer) ((Timer *)timer)->expire_ms = expire_ms;
}

static void register_poll_socket(slirp_os_socket fd, void *opaque) {
    (void)fd, (void)opaque;
}

static void unregister_poll_socket(slirp_os_socket fd, void *opaque) {
    (void)fd, (void)opaque;
}

static void notify(void *opaque) {
    (void)opaque;
    char c = 0;
    (void)!write(wake_pipe[1], &c, 1);
}

static int add_poll(slirp_os_socket fd, int events, void *opaque) {
    (void)opaque;
    if (npfd == MAX_POLL) return -1;
    short ev = 0;
    if (events & SLIRP_POLL_IN) ev |= POLLIN;
    if (events & SLIRP_POLL_OUT) ev |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ev |= POLLPRI;
    pfds[npfd] = (struct pollfd){fd, ev, 0};
    return npfd++;
}

static int get_revents(int idx, void *opaque) {
    (void)opaque;
    short r = pfds[idx].revents;
    int ev = 0;
    if (r & POLLIN) ev |= SLIRP_POLL_IN;
    if (r & POLLOUT) ev |= SLIRP_POLL_OUT;
    if (r & POLLPRI) ev |= SLIRP_POLL_PRI;
    if (r & POLLERR) ev |= SLIRP_POLL_ERR;
    if (r & POLLHUP) ev |= SLIRP_POLL_HUP;
    return ev;
}

static const SlirpCb callbacks = {
    .send_packet = send_packet,
    .guest_error = guest_error,
    .clock_get_ns = clock_get_ns,
    .timer_free = timer_free,
    .timer_mod = timer_mod,
    .notify = notify,
    .timer_new_opaque = timer_new_opaque,
    .register_poll_socket = register_poll_socket,
    .unregister_poll_socket = unregister_poll_socket,
};

/* ---- port forwards ----

   A forward is a rule: protocol(s), a port on the device, a port in the guest and who can connect (net_slirp.h).
   Rules live in a table any thread may change (fwd_mu); the network thread owns libslirp, so it alone opens and
   closes the listeners, comparing what each rule wants with what it has (fwd_reconcile). It does so when told
   (fwd_changed), and every few seconds to follow the VPN's address and to retry forwards that failed.

   IPv4 is libslirp's own host forward, on 127.0.0.1, the local network's addresses or the VPN's address. libslirp
   cannot take an IPv6 connection to the guest's IPv4 address, so IPv6 ([::1], the local network's private
   addresses, the VPN's IPv6 address) is a small relay of our own (Bridge) that hands each TCP connection, or each
   UDP peer's datagrams, to the IPv4 listener. The guest then sees those as coming from 10.0.2.2. The local network
   is the addresses of the Wi-Fi, wired and Personal Hotspot interfaces (lan_ifs), followed as they change, never
   every interface: not cellular, and not a global IPv6 address the internet may reach. Saved rules are a JSON
   file in the machine's folder (fwd_save). */

#define MAX_RULES 64
#define MAX_SESSION_RULES 32
#define FWD_PERIOD_MS 3000
#define UDP_PEERS 32
#define UDP_IDLE_MS 120000
#define BRIDGE_PUMPS 64 /* TCP connections one IPv6 relay carries at once; more are refused */
#define FWD_ADDRS 6      /* addresses of one family a forward listens on */
#define FWD_LISTEN (2 * FWD_ADDRS)

/* How many connections of one relay are being pumped; shared by the relay and its pump threads, which
   may outlive it (refs). */
typedef struct PumpCount {
    _Atomic int live, refs;
} PumpCount;

static void pumps_release(PumpCount *pc) {
    if (pc && atomic_fetch_sub(&pc->refs, 1) == 1) free(pc);
}

typedef struct Bridge {
    int udp;
    int fd; /* the IPv6 socket */
    int stop[2];
    struct sockaddr_in target; /* libslirp's IPv4 listener */
    pthread_t thread;
    _Atomic int dead; /* the socket broke: the network thread opens the forward again (fwd_reconcile) */
    PumpCount *pumps;
} Bridge;

typedef struct Applied { /* what is open for a rule: network thread only */
    int on;
    int proto, host_port, guest_port;
    int n4;
    struct in_addr a4[FWD_ADDRS];
    int tcp4[FWD_ADDRS], udp4[FWD_ADDRS];
    int n6;
    struct in6_addr a6[FWD_ADDRS];
    Bridge *tcp6[FWD_ADDRS], *udp6[FWD_ADDRS];
} Applied;

typedef struct Rule {
    int used, removed, session;
    int load_off;    /* saved as on, off for now: its port was taken when the store was loaded (still saved as on) */
    char blocked[160];
    int dirty;       /* changed since the network thread last looked */
    int reopen;      /* close and open again (hv_net_fwd_reopen) */
    uint64_t serial; /* which use of the slot */
    HvFwdRule cfg;
    /* state, from the network thread */
    char state[12], code[16], msg[160], warn[160];
    char listen[FWD_LISTEN][64];
    int nlisten;
    Applied ap; /* network thread only */
} Rule;

static pthread_mutex_t fwd_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t fwd_cond = PTHREAD_COND_INITIALIZER;
static Rule rules[MAX_RULES];
static int net_running;
static uint64_t fwd_change_gen, fwd_done_gen, rule_serial;
static char store_path[1024];
static uint64_t store_seq;
static pthread_mutex_t save_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t saved_seq;
/* Saved forwards of the store that found no free slot when it was loaded: not in the table, but written back
   with the rest, so a full table never shortens the file. fwd_mu. */
static HvFwdRule kept_out[MAX_RULES];
static int nkept_out;

static void wake_net(void) {
    if (wake_pipe[1] > 0) {
        char c = 0;
        (void)!write(wake_pipe[1], &c, 1);
    }
}

/* fwd_mu held. */
static void fwd_changed_locked(void) {
    fwd_change_gen++;
}

static const char *proto_name(int proto) {
    return proto == HV_FWD_BOTH ? "tcp+udp" : proto == HV_FWD_UDP ? "udp" : "tcp";
}
static const char *scope_name(int scope) {
    return scope == HV_FWD_LAN ? "lan" : scope == HV_FWD_VPN ? "vpn" : "loopback";
}

/* ---- a growing string ---- */

typedef struct Buf {
    char *p;
    size_t n, cap;
} Buf;

static void bput(Buf *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (b->n + n + 1 > cap) cap *= 2;
        char *p = realloc(b->p, cap);
        if (!p) return;
        b->p = p, b->cap = cap;
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void bstr(Buf *b, const char *s) { bput(b, s, strlen(s)); }

/* ---- UTF-8: names come from people and from the guest, and the list goes to JSON readers that refuse
   anything else (NSString gives nil for the whole list) ---- */

/* The length of the valid UTF-8 sequence at p (n bytes left), or 0: a stray or cut sequence, an overlong
   one, a surrogate, past U+10FFFF. */
static size_t utf8_seq(const unsigned char *p, size_t n) {
    if (!n) return 0;
    unsigned c = p[0], cp, min;
    size_t len;
    if (c < 0x80) return 1;
    if ((c & 0xe0) == 0xc0) len = 2, cp = c & 0x1f, min = 0x80;
    else if ((c & 0xf0) == 0xe0) len = 3, cp = c & 0x0f, min = 0x800;
    else if ((c & 0xf8) == 0xf0) len = 4, cp = c & 0x07, min = 0x10000;
    else return 0;
    if (n < len) return 0;
    for (size_t i = 1; i < len; i++) {
        if ((p[i] & 0xc0) != 0x80) return 0;
        cp = cp << 6 | (p[i] & 0x3f);
    }
    if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp < 0xe000)) return 0;
    return len;
}

/* A string cut to fit may end inside a character (a lead byte with fewer continuation bytes after it than
   it announces): that piece goes. Bytes that start no character at all are left to utf8_repair. */
static void utf8_trim_cut(char *s) {
    size_t n = strlen(s), i = n;
    while (i > 0 && n - i < 3 && ((unsigned char)s[i - 1] & 0xc0) == 0x80) i--; /* back over continuation bytes */
    if (!i) return;
    unsigned c = (unsigned char)s[i - 1];
    size_t want = c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
    if (want && n - (i - 1) < want) s[i - 1] = 0;
}

/* In place: cut at a character boundary, and every byte that does not start a valid character becomes '?'
   (the string keeps its size). */
static void utf8_repair(char *s) {
    utf8_trim_cut(s);
    size_t n = strlen(s);
    for (size_t i = 0; i < n;) {
        size_t k = utf8_seq((const unsigned char *)s + i, n - i);
        if (!k) s[i] = '?', k = 1;
        i += k;
    }
}
static void bint(Buf *b, long v) {
    char t[24];
    snprintf(t, sizeof t, "%ld", v);
    bstr(b, t);
}
static void bjson(Buf *b, const char *s) { /* a JSON string */
    bput(b, "\"", 1);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '"' || *p == '\\') {
            char e[2] = {'\\', (char)*p};
            bput(b, e, 2);
        } else if (*p < 0x20) {
            char e[8];
            snprintf(e, sizeof e, "\\u%04x", *p);
            bstr(b, e);
        } else if (*p < 0x80) {
            bput(b, (const char *)p, 1);
        } else {
            /* never anything but UTF-8: one bad name must not make a whole list unreadable */
            size_t k = utf8_seq(p, strlen((const char *)p));
            if (k) bput(b, (const char *)p, k), p += k - 1;
            else bstr(b, "\\ufffd");
        }
    }
    bput(b, "\"", 1);
}

/* ---- reading JSON: just what the rules file and the guest's requests need ---- */

typedef struct JP {
    const char *p, *end;
} JP;

static void jws(JP *j) {
    while (j->p < j->end && (*j->p == ' ' || *j->p == '\t' || *j->p == '\n' || *j->p == '\r')) j->p++;
}
static int jlit(JP *j, const char *lit) {
    size_t n = strlen(lit);
    if ((size_t)(j->end - j->p) < n || memcmp(j->p, lit, n)) return 0;
    j->p += n;
    return 1;
}
static void utf8(char *out, size_t cap, size_t *o, unsigned cp) {
    char t[4];
    size_t n;
    if (cp < 0x80) t[0] = (char)cp, n = 1;
    else if (cp < 0x800) t[0] = (char)(0xc0 | cp >> 6), t[1] = (char)(0x80 | (cp & 63)), n = 2;
    else if (cp < 0x10000)
        t[0] = (char)(0xe0 | cp >> 12), t[1] = (char)(0x80 | (cp >> 6 & 63)), t[2] = (char)(0x80 | (cp & 63)), n = 3;
    else
        t[0] = (char)(0xf0 | cp >> 18), t[1] = (char)(0x80 | (cp >> 12 & 63)), t[2] = (char)(0x80 | (cp >> 6 & 63)),
        t[3] = (char)(0x80 | (cp & 63)), n = 4;
    if (*o + n < cap) memcpy(out + *o, t, n), *o += n; /* longer strings are cut, at a character boundary */
}
static int jhex4(JP *j, unsigned *v) {
    if (j->end - j->p < 4) return 0;
    *v = 0;
    for (int i = 0; i < 4; i++) {
        char c = *j->p++;
        int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
        if (d < 0) return 0;
        *v = *v << 4 | (unsigned)d;
    }
    return 1;
}
/* A string into out (cap > 0), cut to fit, at a character boundary. */
static int jstr(JP *j, char *out, size_t cap) {
    jws(j);
    if (j->p >= j->end || *j->p != '"') return 0;
    j->p++;
    size_t o = 0;
    int cut = 0;
    while (j->p < j->end && *j->p != '"') {
        unsigned char c = (unsigned char)*j->p++;
        if (c < 0x20) return 0;
        if (c != '\\') {
            if (o + 1 < cap) out[o++] = (char)c;
            else cut = 1;
            continue;
        }
        if (j->p >= j->end) return 0;
        c = (unsigned char)*j->p++;
        unsigned cp;
        switch (c) {
        case '"': case '\\': case '/': cp = c; break;
        case 'b': cp = 8; break;
        case 'f': cp = 12; break;
        case 'n': cp = 10; break;
        case 'r': cp = 13; break;
        case 't': cp = 9; break;
        case 'u':
            if (!jhex4(j, &cp)) return 0;
            if (cp >= 0xd800 && cp < 0xdc00) { /* a surrogate pair */
                unsigned lo;
                if (!jlit(j, "\\u") || !jhex4(j, &lo) || lo < 0xdc00 || lo > 0xdfff) return 0;
                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
            } else if (cp >= 0xdc00 && cp < 0xe000) {
                return 0;
            }
            break;
        default: return 0;
        }
        if (!cp) return 0;
        utf8(out, cap, &o, cp);
    }
    if (j->p >= j->end) return 0;
    j->p++;
    out[o < cap ? o : cap - 1] = 0;
    if (cut) utf8_trim_cut(out); /* raw bytes cut inside a character */
    return 1;
}
static int jnum(JP *j, long *v) {
    jws(j);
    const char *s = j->p;
    if (j->p < j->end && *j->p == '-') j->p++;
    long x = 0;
    int digits = 0;
    while (j->p < j->end && *j->p >= '0' && *j->p <= '9') {
        if (x < 100000000) x = x * 10 + (*j->p - '0');
        j->p++, digits++;
    }
    if (!digits) return 0;
    if (j->p < j->end && (*j->p == '.' || *j->p == 'e' || *j->p == 'E')) return 0; /* ports are whole numbers */
    *v = *s == '-' ? -x : x;
    return 1;
}
static int jbool(JP *j, int *v) {
    jws(j);
    if (jlit(j, "true")) return *v = 1, 1;
    if (jlit(j, "false")) return *v = 0, 1;
    return 0;
}
static int jskip(JP *j, int depth) {
    jws(j);
    if (j->p >= j->end || depth > 16) return 0;
    char c = *j->p;
    if (c == '"') {
        char t[2];
        return jstr(j, t, sizeof t);
    }
    if (c == '{' || c == '[') {
        char close = c == '{' ? '}' : ']';
        j->p++;
        jws(j);
        if (j->p < j->end && *j->p == close) return j->p++, 1;
        for (;;) {
            if (c == '{') {
                char t[2];
                if (!jstr(j, t, sizeof t)) return 0;
                jws(j);
                if (j->p >= j->end || *j->p++ != ':') return 0;
            }
            if (!jskip(j, depth + 1)) return 0;
            jws(j);
            if (j->p >= j->end) return 0;
            if (*j->p == ',') {
                j->p++;
                continue;
            }
            if (*j->p == close) return j->p++, 1;
            return 0;
        }
    }
    if (jlit(j, "true") || jlit(j, "false") || jlit(j, "null")) return 1;
    long v;
    if (c == '-' || (c >= '0' && c <= '9')) {
        if (jnum(j, &v)) return 1;
        while (j->p < j->end && strchr("+-.eE0123456789", *j->p)) j->p++; /* a number with a fraction */
        return 1;
    }
    return 0;
}

static int parse_proto(const char *s) {
    if (!strcasecmp(s, "tcp")) return HV_FWD_TCP;
    if (!strcasecmp(s, "udp")) return HV_FWD_UDP;
    if (!strcasecmp(s, "tcp+udp") || !strcasecmp(s, "both")) return HV_FWD_BOTH;
    return 0;
}
static int parse_scope(const char *s) {
    if (!strcasecmp(s, "loopback")) return HV_FWD_LOOPBACK;
    if (!strcasecmp(s, "lan")) return HV_FWD_LAN;
    if (!strcasecmp(s, "vpn")) return HV_FWD_VPN;
    return -1;
}

/* One rule object; unknown keys are skipped. */
static int jrule(JP *j, HvFwdRule *r) {
    jws(j);
    if (j->p >= j->end || *j->p != '{') return 0;
    j->p++;
    jws(j);
    if (j->p < j->end && *j->p == '}') return j->p++, 1;
    for (;;) {
        char key[32], s[64];
        long v;
        if (!jstr(j, key, sizeof key)) return 0;
        jws(j);
        if (j->p >= j->end || *j->p++ != ':') return 0;
        if (!strcmp(key, "id")) {
            if (!jstr(j, r->id, sizeof r->id)) return 0;
        } else if (!strcmp(key, "name")) {
            if (!jstr(j, r->name, sizeof r->name)) return 0;
        } else if (!strcmp(key, "protocol")) {
            if (!jstr(j, s, sizeof s) || !(r->proto = parse_proto(s))) return 0;
        } else if (!strcmp(key, "scope")) {
            if (!jstr(j, s, sizeof s) || (r->scope = parse_scope(s)) < 0) return 0;
        } else if (!strcmp(key, "hostPort")) {
            if (!jnum(j, &v)) return 0;
            r->host_port = v < 0 || v > 70000 ? -1 : (int)v;
        } else if (!strcmp(key, "guestPort")) {
            if (!jnum(j, &v)) return 0;
            r->guest_port = v < 0 || v > 70000 ? -1 : (int)v;
        } else if (!strcmp(key, "enabled")) {
            if (!jbool(j, &r->enabled)) return 0;
        } else if (!jskip(j, 1)) {
            return 0;
        }
        jws(j);
        if (j->p >= j->end) return 0;
        if (*j->p == ',') {
            j->p++;
            continue;
        }
        if (*j->p == '}') return j->p++, 1;
        return 0;
    }
}

int hv_net_fwd_parse_rule(const char *json, size_t len, HvFwdRule *r) {
    JP j = {json, json + len};
    HvFwdRule t = *r;
    if (!jrule(&j, &t)) return -1;
    jws(&j);
    if (j.p != j.end) return -1;
    *r = t;
    return 0;
}

/* ---- the IPv6 relay (Bridge): [::1], [::] or the VPN's IPv6 address -> libslirp's IPv4 listener ---- */

static void no_sigpipe(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
}

typedef struct Pump {
    int a;
    struct sockaddr_in target;
    PumpCount *pumps;
} Pump;

static void pump_done(Pump *p) {
    atomic_fetch_sub(&p->pumps->live, 1);
    pumps_release(p->pumps);
}

/* One TCP connection: connect to the IPv4 listener, then copy both ways until both sides are done. */
static void *pump_thread(void *arg) {
    Pump p = *(Pump *)arg;
    free(arg);
    int b = socket(AF_INET, SOCK_STREAM, 0);
    if (b < 0) {
        close(p.a);
        pump_done(&p);
        return NULL;
    }
    no_sigpipe(b);
    if (connect(b, (struct sockaddr *)&p.target, sizeof p.target) != 0) {
        close(p.a), close(b);
        pump_done(&p);
        return NULL;
    }
    int one = 1;
    setsockopt(b, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(p.a, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    uint8_t buf[16384];
    int eof[2] = {0, 0}, fd[2] = {p.a, b};
    while (!eof[0] || !eof[1]) {
        struct pollfd fds[2] = {{eof[0] ? -1 : p.a, POLLIN, 0}, {eof[1] ? -1 : b, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        int bad = 0;
        for (int i = 0; i < 2 && !bad; i++) {
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t n = recv(fd[i], buf, sizeof buf, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { /* this side is done sending: pass that on */
                eof[i] = 1;
                shutdown(fd[1 - i], SHUT_WR);
                if (n < 0) bad = 1;
                continue;
            }
            for (ssize_t off = 0; off < n;) {
                ssize_t w = send(fd[1 - i], buf + off, (size_t)(n - off), 0);
                if (w < 0 && errno == EINTR) continue;
                if (w <= 0) {
                    bad = 1;
                    break;
                }
                off += w;
            }
        }
        if (bad) break;
    }
    close(p.a), close(b);
    pump_done(&p);
    return NULL;
}

static void *tcp_bridge_thread(void *arg) {
    Bridge *br = arg;
    int dead = 0;    /* the socket broke (iOS reclaims a suspended app's listeners): the network thread reopens it */
    int backoff = 0; /* out of descriptors or memory for now: the waiting connections stay queued meanwhile */
    for (;;) {
        struct pollfd fds[2] = {{dead || backoff ? -1 : br->fd, POLLIN, 0}, {br->stop[0], POLLIN, 0}};
        int n = poll(fds, 2, backoff ? 200 : -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (fds[1].revents) break;
        if (backoff) {
            backoff = 0;
            continue;
        }
        if (fds[0].revents & (POLLERR | POLLNVAL)) dead = 1, atomic_store(&br->dead, 1);
        if (!(fds[0].revents & POLLIN)) continue;
        int c = accept(br->fd, NULL, NULL);
        if (c < 0) {
            if (errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM) backoff = 1;
            else if (errno == EBADF || errno == EINVAL || errno == ENOTSOCK) dead = 1, atomic_store(&br->dead, 1);
            continue; /* EAGAIN, EINTR, ECONNABORTED...: the next one */
        }
        no_sigpipe(c);
        if (atomic_load(&br->pumps->live) >= BRIDGE_PUMPS) { /* a peer opening connection after connection */
            close(c);
            continue;
        }
        Pump *p = malloc(sizeof *p);
        pthread_t t;
        if (!p) {
            close(c);
            continue;
        }
        p->a = c, p->target = br->target, p->pumps = br->pumps;
        atomic_fetch_add(&br->pumps->live, 1);
        atomic_fetch_add(&br->pumps->refs, 1);
        if (pthread_create(&t, NULL, pump_thread, p) == 0) {
            pthread_detach(t);
        } else {
            pump_done(p);
            free(p), close(c);
        }
    }
    return NULL;
}

typedef struct UdpPeer {
    int fd; /* connected to the IPv4 listener; -1: free */
    struct sockaddr_in6 addr;
    int64_t last;
} UdpPeer;

/* Each IPv6 peer gets an IPv4 socket of its own, so the answers can be told apart. */
static void *udp_bridge_thread(void *arg) {
    Bridge *br = arg;
    UdpPeer peers[UDP_PEERS];
    for (int i = 0; i < UDP_PEERS; i++) peers[i].fd = -1;
    static __thread uint8_t buf[65536];
    int dead = 0; /* as in tcp_bridge_thread */
    for (;;) {
        struct pollfd fds[2 + UDP_PEERS];
        fds[0] = (struct pollfd){br->stop[0], POLLIN, 0};
        fds[1] = (struct pollfd){dead ? -1 : br->fd, POLLIN, 0};
        for (int i = 0; i < UDP_PEERS; i++) fds[2 + i] = (struct pollfd){peers[i].fd, POLLIN, 0};
        if (poll(fds, 2 + UDP_PEERS, 1000) < 0 && errno != EINTR) break;
        if (fds[0].revents) break;
        int64_t now = now_ms();
        if (fds[1].revents & POLLNVAL) dead = 1, atomic_store(&br->dead, 1);
        if (fds[1].revents & (POLLIN | POLLERR)) {
            struct sockaddr_in6 from;
            socklen_t fl = sizeof from;
            ssize_t n = recvfrom(br->fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
            if (n < 0 && errno != EAGAIN && errno != EINTR && errno != ECONNREFUSED && errno != EHOSTUNREACH &&
                errno != ENETUNREACH && errno != ENOBUFS && errno != ENOMEM)
                dead = 1, atomic_store(&br->dead, 1);
            if (n >= 0 && from.sin6_family == AF_INET6) {
                int k = -1, oldest = 0;
                for (int i = 0; i < UDP_PEERS; i++) {
                    if (peers[i].fd >= 0 && peers[i].addr.sin6_port == from.sin6_port &&
                        !memcmp(&peers[i].addr.sin6_addr, &from.sin6_addr, 16) &&
                        peers[i].addr.sin6_scope_id == from.sin6_scope_id)
                        k = i;
                    if (peers[i].fd < 0 || (peers[oldest].fd >= 0 && peers[i].last < peers[oldest].last)) oldest = i;
                }
                if (k < 0) { /* a new peer, in a free slot or the one heard from longest ago */
                    k = oldest;
                    if (peers[k].fd >= 0) close(peers[k].fd);
                    peers[k].fd = socket(AF_INET, SOCK_DGRAM, 0);
                    if (peers[k].fd >= 0 &&
                        connect(peers[k].fd, (struct sockaddr *)&br->target, sizeof br->target) != 0) {
                        close(peers[k].fd);
                        peers[k].fd = -1;
                    }
                    peers[k].addr = from;
                }
                if (peers[k].fd >= 0) {
                    peers[k].last = now;
                    (void)!send(peers[k].fd, buf, (size_t)n, 0);
                }
            }
        }
        for (int i = 0; i < UDP_PEERS; i++) {
            if (peers[i].fd < 0) continue;
            if (fds[2 + i].revents & (POLLIN | POLLERR)) {
                ssize_t n = recv(peers[i].fd, buf, sizeof buf, 0); /* an error here is an ICMP: nothing to pass on */
                if (n >= 0) {
                    (void)!sendto(br->fd, buf, (size_t)n, 0, (struct sockaddr *)&peers[i].addr, sizeof peers[i].addr);
                    peers[i].last = now;
                }
            }
            if (now - peers[i].last > UDP_IDLE_MS) {
                close(peers[i].fd);
                peers[i].fd = -1;
            }
        }
    }
    for (int i = 0; i < UDP_PEERS; i++)
        if (peers[i].fd >= 0) close(peers[i].fd);
    return NULL;
}

/* NULL with *err set when the IPv6 socket cannot be had. */
static Bridge *bridge_start(int udp, const struct in6_addr *a6, int port, struct in_addr target, int *err) {
    int fd = socket(AF_INET6, udp ? SOCK_DGRAM : SOCK_STREAM, 0);
    if (fd < 0) return *err = errno, NULL;
    int one = 1;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one);
    if (!udp) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    no_sigpipe(fd);
    struct sockaddr_in6 sa = {0};
    sa.sin6_len = sizeof sa;
    sa.sin6_family = AF_INET6;
    sa.sin6_port = htons((uint16_t)port);
    sa.sin6_addr = *a6;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0 || (!udp && listen(fd, 16) != 0)) {
        *err = errno;
        close(fd);
        return NULL;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    Bridge *br = calloc(1, sizeof *br);
    PumpCount *pc = calloc(1, sizeof *pc);
    if (!br || !pc || pipe(br->stop) != 0) {
        *err = ENOMEM;
        free(br), free(pc);
        close(fd);
        return NULL;
    }
    atomic_store(&pc->refs, 1);
    br->pumps = pc;
    br->udp = udp, br->fd = fd;
    br->target.sin_len = sizeof br->target;
    br->target.sin_family = AF_INET;
    br->target.sin_port = htons((uint16_t)port);
    br->target.sin_addr = target;
    if (pthread_create(&br->thread, NULL, udp ? udp_bridge_thread : tcp_bridge_thread, br) != 0) {
        *err = EAGAIN;
        close(br->stop[0]), close(br->stop[1]), close(fd);
        pumps_release(br->pumps);
        free(br);
        return NULL;
    }
    return br;
}

/* Stops the relay and closes its socket before returning, so the port can be bound again at once. Connections
   already relayed go on until they end, as libslirp's own do. */
static void bridge_stop(Bridge *br) {
    if (!br) return;
    char c = 0;
    (void)!write(br->stop[1], &c, 1);
    pthread_join(br->thread, NULL);
    close(br->fd), close(br->stop[0]), close(br->stop[1]);
    pumps_release(br->pumps);
    free(br);
}

/* A relay of this forward broke (network thread). */
static int bridge_dead(const Applied *ap) {
    for (int k = 0; k < ap->n6; k++)
        if ((ap->tcp6[k] && atomic_load(&ap->tcp6[k]->dead)) || (ap->udp6[k] && atomic_load(&ap->udp6[k]->dead))) return 1;
    return 0;
}

/* ---- the device's interfaces ---- */

/* name starts with one of the comma-separated prefixes in list. */
static int if_matches(const char *name, const char *list) {
    for (const char *p = list; *p;) {
        const char *e = strchr(p, ',');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n && !strncmp(name, p, n)) return 1;
        p += n + (e ? 1 : 0);
    }
    return 0;
}
static int usable4(const struct sockaddr *sa) {
    uint32_t a = ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr);
    return a && (a >> 16) != 0xa9fe; /* not 0.0.0.0, not 169.254/16 */
}
static int usable6(const struct sockaddr *sa) {
    const struct in6_addr *a = &((const struct sockaddr_in6 *)sa)->sin6_addr;
    return !IN6_IS_ADDR_UNSPECIFIED(a) && !IN6_IS_ADDR_LINKLOCAL(a) && !IN6_IS_ADDR_MULTICAST(a) &&
           !IN6_IS_ADDR_V4MAPPED(a);
}
static const char *vpn_ifs(void) {
    const char *e = getenv("HV_NET_VPN_IF"); /* which interfaces are a VPN's, preferred in this order; the tests use lo0 */
    return e && *e ? e : "utun,wg,tun,ppp,ipsec";
}
/* Which of list's comma-separated prefixes name starts with (its place in the list), or -1. */
static int if_rank(const char *name, const char *list) {
    int k = 0;
    for (const char *p = list; *p; k++) {
        const char *e = strchr(p, ',');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n && !strncmp(name, p, n)) return k;
        p += n + (e ? 1 : 0);
    }
    return -1;
}
static int ula6(const struct sockaddr *sa) { /* fc00::/7: a private network's own IPv6 addresses */
    return (((const struct sockaddr_in6 *)sa)->sin6_addr.s6_addr[0] & 0xfe) == 0xfc;
}
static const char *lan_ifs(void) {
    const char *e = getenv("HV_NET_LAN_IF");
    return e && *e ? e : "en,bridge"; /* Wi-Fi and wired, and the personal hotspot (bridge100); never pdp_ip (cellular) */
}

typedef struct VpnAddr {
    char ifname[IFNAMSIZ];
    int has4, has6;
    struct in_addr a4;
    struct in6_addr a6;
} VpnAddr;

/* The active VPN: a VPN interface that is up with an IPv4 address, else one with a unique local IPv6 address
   (fc00::/7), preferring the list's order (utun, wg, tun, ppp, then ipsec). iOS's own utun interfaces only have
   link-local addresses, and the carrier's tunnels for Wi-Fi Calling and VoLTE (ipsecN, a global IPv6 address from
   the carrier and no IPv4) are not a VPN the user connected: both are passed over. */
static void vpn_lookup(VpnAddr *v) {
    memset(v, 0, sizeof *v);
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return;
    const char *list = vpn_ifs();
    for (int want4 = 1; want4 >= 0 && !v->ifname[0]; want4--) {
        int best = -1;
        for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
            if (!i->ifa_addr || !(i->ifa_flags & IFF_UP)) continue;
            int rank = if_rank(i->ifa_name, list), fam = i->ifa_addr->sa_family;
            if (rank < 0 || (best >= 0 && rank >= best)) continue;
            if ((want4 && fam == AF_INET && usable4(i->ifa_addr)) ||
                (!want4 && fam == AF_INET6 && usable6(i->ifa_addr) && ula6(i->ifa_addr))) {
                snprintf(v->ifname, sizeof v->ifname, "%s", i->ifa_name);
                best = rank;
            }
        }
    }
    for (struct ifaddrs *i = ifa; i && v->ifname[0]; i = i->ifa_next) {
        if (!i->ifa_addr || strcmp(i->ifa_name, v->ifname)) continue;
        if (i->ifa_addr->sa_family == AF_INET && !v->has4 && usable4(i->ifa_addr))
            v->has4 = 1, v->a4 = ((struct sockaddr_in *)i->ifa_addr)->sin_addr;
        if (i->ifa_addr->sa_family == AF_INET6 && !v->has6 && usable6(i->ifa_addr))
            v->has6 = 1, v->a6 = ((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr;
    }
    freeifaddrs(ifa);
}

/* A local network's IPv6 address a forward may listen on: a unique local one (fc00::/7). A global one on the Wi-Fi
   is reachable from the whole internet wherever the network does not filter incoming IPv6 (many carriers and public
   networks do not), so it is only taken with HV_NET_LAN_GLOBAL6=1. */
static int lan6_ok(const struct sockaddr *sa) {
    if (!usable6(sa)) return 0;
    if (ula6(sa)) return 1;
    const char *e = getenv("HV_NET_LAN_GLOBAL6");
    return e && *e && *e != '0';
}

typedef struct LanAddr {
    int n4, n6;
    struct in_addr a4[FWD_ADDRS - 1]; /* one place is loopback's */
    struct in6_addr a6[FWD_ADDRS - 1];
} LanAddr;

/* The local network's addresses now: those of the lan_ifs() interfaces that are up. */
static void lan_lookup(LanAddr *l) {
    memset(l, 0, sizeof *l);
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return;
    const char *list = lan_ifs();
    for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
        if (!i->ifa_addr || !(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK) || !if_matches(i->ifa_name, list))
            continue;
        if (i->ifa_addr->sa_family == AF_INET && usable4(i->ifa_addr) && l->n4 < FWD_ADDRS - 1) {
            struct in_addr a = ((struct sockaddr_in *)i->ifa_addr)->sin_addr;
            int dup = 0;
            for (int k = 0; k < l->n4; k++) dup |= l->a4[k].s_addr == a.s_addr;
            if (!dup) l->a4[l->n4++] = a;
        } else if (i->ifa_addr->sa_family == AF_INET6 && lan6_ok(i->ifa_addr) && l->n6 < FWD_ADDRS - 1) {
            struct in6_addr a = ((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr;
            int dup = 0;
            for (int k = 0; k < l->n6; k++) dup |= !memcmp(&l->a6[k], &a, sizeof a);
            if (!dup) l->a6[l->n6++] = a;
        }
    }
    freeifaddrs(ifa);
}

static void addr_list(Buf *b, struct ifaddrs *ifa, const char *list, const char *only_if) {
    int first = 1, n = 0;
    bstr(b, "[");
    for (struct ifaddrs *i = ifa; i && n < 8; i = i->ifa_next) {
        if (!i->ifa_addr || !(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK && !only_if)) continue;
        if (only_if ? strcmp(i->ifa_name, only_if) != 0 : !if_matches(i->ifa_name, list)) continue;
        int fam = i->ifa_addr->sa_family;
        char a[INET6_ADDRSTRLEN];
        if (fam == AF_INET && usable4(i->ifa_addr))
            inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, a, sizeof a);
        else if (fam == AF_INET6 && (only_if ? usable6(i->ifa_addr) : lan6_ok(i->ifa_addr))) /* what LAN forwards take */
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)i->ifa_addr)->sin6_addr, a, sizeof a);
        else
            continue;
        bstr(b, first ? "{\"interface\":" : ",{\"interface\":");
        bjson(b, i->ifa_name);
        bstr(b, ",\"address\":");
        bjson(b, a);
        bstr(b, fam == AF_INET ? ",\"family\":4}" : ",\"family\":6}");
        first = 0, n++;
    }
    bstr(b, "]");
}

char *hv_net_fwd_addresses_json(void) {
    Buf b = {0};
    struct ifaddrs *ifa = NULL;
    VpnAddr v;
    vpn_lookup(&v);
    if (getifaddrs(&ifa) != 0) ifa = NULL;
    bstr(&b, "{\"lan\":");
    addr_list(&b, ifa, lan_ifs(), NULL);
    bstr(&b, ",\"vpn\":");
    if (v.ifname[0]) addr_list(&b, ifa, NULL, v.ifname);
    else bstr(&b, "[]");
    bstr(&b, "}");
    if (ifa) freeifaddrs(ifa);
    return b.p ? b.p : strdup("{\"lan\":[],\"vpn\":[]}");
}

/* ---- the rules ---- */

/* fwd_mu held. */
static Rule *find_rule(const char *id) {
    for (int i = 0; i < MAX_RULES; i++)
        if (rules[i].used && !rules[i].removed && !strcmp(rules[i].cfg.id, id)) return &rules[i];
    return NULL;
}

static void set_state(Rule *r, const char *state, const char *code, const char *msg) {
    snprintf(r->state, sizeof r->state, "%s", state);
    snprintf(r->code, sizeof r->code, "%s", code ? code : "");
    snprintf(r->msg, sizeof r->msg, "%s", msg ? msg : "");
}

/* fwd_mu held: frees a slot (when the network thread has nothing open for it). */
static void free_rule(Rule *r) {
    memset(r, 0, sizeof *r);
}

static void store_rule_json(Buf *b, const HvFwdRule *c, int enabled, int first) {
    bstr(b, first ? "\n    {\"id\": " : ",\n    {\"id\": ");
    bjson(b, c->id);
    bstr(b, ", \"name\": ");
    bjson(b, c->name);
    bstr(b, ", \"protocol\": ");
    bjson(b, proto_name(c->proto));
    bstr(b, ", \"hostPort\": ");
    bint(b, c->host_port);
    bstr(b, ", \"guestPort\": ");
    bint(b, c->guest_port);
    bstr(b, ", \"scope\": ");
    bjson(b, scope_name(c->scope));
    bstr(b, enabled ? ", \"enabled\": true}" : ", \"enabled\": false}");
}

/* fwd_mu held. The saved rules as the file's JSON: as the user saved them. One turned off only for now
   (load_off) is written as on, and those left out for want of a slot are written too. */
static char *store_json_locked(void) {
    Buf b = {0};
    bstr(&b, "{\n  \"version\": 1,\n  \"rules\": [");
    int first = 1;
    for (int i = 0; i < MAX_RULES; i++) {
        Rule *r = &rules[i];
        if (!r->used || r->removed || r->session) continue;
        store_rule_json(&b, &r->cfg, r->cfg.enabled || r->load_off, first);
        first = 0;
    }
    for (int i = 0; i < nkept_out; i++) {
        if (find_rule(kept_out[i].id)) continue; /* added again since */
        store_rule_json(&b, &kept_out[i], kept_out[i].enabled, first);
        first = 0;
    }
    bstr(&b, first ? "]\n}\n" : "\n  ]\n}\n");
    return b.p;
}

/* Called with fwd_mu held: takes the JSON now, writes it after (newest wins). */
static void fwd_save_locked(char **json, char *path, size_t cap, uint64_t *seq) {
    *json = NULL;
    if (!store_path[0]) return;
    *json = store_json_locked();
    snprintf(path, cap, "%s", store_path);
    *seq = ++store_seq;
}
static void fwd_save_write(char *json, const char *path, uint64_t seq) {
    if (!json) return;
    pthread_mutex_lock(&save_mu);
    if (seq > saved_seq) {
        char tmp[1100];
        snprintf(tmp, sizeof tmp, "%s.tmp", path);
        FILE *f = fopen(tmp, "w");
        int ok = f && fputs(json, f) >= 0;
        if (f && fclose(f) != 0) ok = 0;
        if (ok && rename(tmp, path) == 0) saved_seq = seq;
        else fprintf(stderr, "winvm: net: could not save the port forwards to %s: %s\n", path, strerror(errno)), unlink(tmp);
    }
    pthread_mutex_unlock(&save_mu);
    free(json);
}

static int id_ok(const char *id) {
    if (!*id) return 0;
    for (const char *p = id; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '-' ||
              *p == '_' || *p == '.'))
            return 0;
    return 1;
}

/* fwd_mu held. 0, or -1 with why. */
static int put_locked(HvFwdRule *in, int session, int from_guest, char *err, size_t errlen) {
    HvFwdRule c = *in;
    c.name[sizeof c.name - 1] = 0;
    c.id[sizeof c.id - 1] = 0;
    utf8_repair(c.name); /* from the guest or a file: whatever bytes; cut by a caller inside a character */
    if (c.proto < HV_FWD_TCP || c.proto > HV_FWD_BOTH) return snprintf(err, errlen, "unknown protocol"), -1;
    if (c.host_port < 1 || c.host_port > 65535 || c.guest_port < 1 || c.guest_port > 65535)
        return snprintf(err, errlen, "ports go from 1 to 65535"), -1;
    if (from_guest && c.host_port < 1024) return snprintf(err, errlen, "Windows can only open ports from 1024 up"), -1;
    if (c.scope < HV_FWD_LOOPBACK || c.scope > HV_FWD_VPN) return snprintf(err, errlen, "unknown scope"), -1;
    if (from_guest) c.scope = HV_FWD_LOOPBACK; /* the guest never opens anything beyond this device */
    c.enabled = c.enabled != 0;
    if (!c.id[0]) {
        if (session) snprintf(c.id, sizeof c.id, "session-%s-%d", proto_name(c.proto), c.host_port);
        else snprintf(c.id, sizeof c.id, "fwd-%08x%04x", arc4random(), arc4random() & 0xffff);
        for (char *p = c.id; *p; p++)
            if (*p == '+') *p = '-';
    }
    if (!id_ok(c.id)) return snprintf(err, errlen, "bad id"), -1;
    if (!c.name[0]) snprintf(c.name, sizeof c.name, "%s %d", c.proto == HV_FWD_UDP ? "UDP" : "TCP", c.host_port);
    Rule *same = find_rule(c.id);
    if (same && session && !same->session) return snprintf(err, errlen, "that forward belongs to the app"), -1;
    if (c.enabled)
        for (int i = 0; i < MAX_RULES; i++) {
            Rule *o = &rules[i];
            if (!o->used || o->removed || o == same || !o->cfg.enabled) continue;
            if (o->cfg.host_port == c.host_port && (o->cfg.proto & c.proto)) {
                snprintf(err, errlen, "port %d (%s) is already forwarded by \"%s\"", c.host_port,
                         (o->cfg.proto & c.proto) == HV_FWD_UDP ? "UDP" : "TCP", o->cfg.name);
                return -1;
            }
        }
    if (!same) {
        int sessions = 0;
        for (int i = 0; i < MAX_RULES; i++) sessions += rules[i].used && rules[i].session;
        if (session && sessions >= MAX_SESSION_RULES) return snprintf(err, errlen, "too many forwards"), -1;
        for (int i = 0; i < MAX_RULES && !same; i++)
            if (!rules[i].used) same = &rules[i];
        if (!same) return snprintf(err, errlen, "too many forwards"), -1;
        memset(same, 0, sizeof *same);
        same->used = 1;
        same->serial = ++rule_serial;
        set_state(same, "waiting", NULL, NULL);
    }
    same->cfg = c;
    same->session = session;
    same->load_off = 0; /* set as asked now */
    same->blocked[0] = 0;
    same->dirty = 1;
    *in = c;
    fwd_changed_locked();
    return 0;
}

int hv_net_fwd_put(HvFwdRule *r, int session, char *err, size_t errlen) {
    char tmp[8], path[1024], *json = NULL;
    uint64_t seq = 0;
    if (!err || !errlen) err = tmp, errlen = sizeof tmp;
    err[0] = 0;
    pthread_mutex_lock(&fwd_mu);
    int rc = put_locked(r, session != HV_FWD_SAVED, session == HV_FWD_GUEST, err, errlen);
    if (rc == 0 && session == HV_FWD_SAVED) fwd_save_locked(&json, path, sizeof path, &seq);
    pthread_mutex_unlock(&fwd_mu);
    fwd_save_write(json, path, seq);
    if (rc == 0) wake_net();
    return rc;
}

/* fwd_mu held. */
static void remove_locked(Rule *r) {
    if (net_running) r->removed = 1; /* the network thread closes its listeners and frees it */
    else free_rule(r);
    fwd_changed_locked();
}

int hv_net_fwd_remove(const char *id, int session_only) {
    char path[1024], *json = NULL;
    uint64_t seq = 0;
    pthread_mutex_lock(&fwd_mu);
    Rule *r = id ? find_rule(id) : NULL;
    int rc = -1;
    if (r && (!session_only || r->session)) {
        int saved = !r->session;
        remove_locked(r);
        if (saved) fwd_save_locked(&json, path, sizeof path, &seq);
        rc = 0;
    }
    pthread_mutex_unlock(&fwd_mu);
    fwd_save_write(json, path, seq);
    if (rc == 0) wake_net();
    return rc;
}

void hv_net_add_hostfwd(int host_port, int guest_port) {
    if (host_port < 1024 || host_port > 65535 || guest_port < 1 || guest_port > 65535) return;
    pthread_mutex_lock(&fwd_mu);
    int covered = 0;
    for (int i = 0; i < MAX_RULES; i++) {
        Rule *o = &rules[i];
        if (o->used && !o->removed && o->cfg.enabled && o->cfg.host_port == host_port && (o->cfg.proto & HV_FWD_TCP)) {
            covered = 1;
            if (o->cfg.guest_port != guest_port)
                fprintf(stderr, "winvm: net: port %d is already forwarded (to %d), not to %d\n", host_port,
                        o->cfg.guest_port, guest_port);
        }
    }
    int rc = 0;
    if (!covered) {
        HvFwdRule r = {.proto = HV_FWD_TCP, .host_port = host_port, .guest_port = guest_port,
                       .scope = HV_FWD_LOOPBACK, .enabled = 1};
        snprintf(r.name, sizeof r.name, "localhost:%d", host_port);
        char err[160];
        rc = put_locked(&r, 1, 0, err, sizeof err);
        if (rc) fprintf(stderr, "winvm: net: no forward for port %d: %s\n", host_port, err);
    }
    pthread_mutex_unlock(&fwd_mu);
    if (!covered && rc == 0) wake_net();
}

int hv_net_fwd_set_store(const char *path) {
    if (!path || !*path) return -1;
    pthread_mutex_lock(&fwd_mu);
    if (!strcmp(path, store_path)) {
        pthread_mutex_unlock(&fwd_mu);
        return 0;
    }
    pthread_mutex_unlock(&fwd_mu);

    /* Read it outside the lock. */
    char *text = NULL;
    size_t len = 0;
    int bad = 0;
    FILE *f = fopen(path, "r");
    if (f) {
        Buf b = {0};
        char chunk[4096];
        size_t n;
        while ((n = fread(chunk, 1, sizeof chunk, f)) > 0 && b.n < (1 << 20)) bput(&b, chunk, n);
        bad = ferror(f) || b.n >= (1 << 20);
        fclose(f);
        text = b.p, len = b.n;
    } else if (errno != ENOENT) {
        bad = 1;
    }
    HvFwdRule loaded[MAX_RULES];
    int nloaded = 0;
    if (text && !bad) {
        JP j = {text, text + len};
        jws(&j);
        int ok = j.p < j.end && *j.p == '{';
        if (ok) j.p++;
        int found_rules = 0;
        while (ok) {
            char key[32];
            jws(&j);
            if (j.p < j.end && *j.p == '}') break;
            if (!jstr(&j, key, sizeof key)) { ok = 0; break; }
            jws(&j);
            if (j.p >= j.end || *j.p++ != ':') { ok = 0; break; }
            if (!strcmp(key, "rules")) {
                found_rules = 1;
                jws(&j);
                if (j.p >= j.end || *j.p++ != '[') { ok = 0; break; }
                jws(&j);
                if (j.p < j.end && *j.p == ']') j.p++;
                else
                    for (;;) {
                        HvFwdRule r = {.proto = HV_FWD_TCP, .enabled = 1};
                        if (!jrule(&j, &r)) { ok = 0; break; }
                        if (nloaded < MAX_RULES) loaded[nloaded++] = r;
                        jws(&j);
                        if (j.p < j.end && *j.p == ',') { j.p++; continue; }
                        if (j.p < j.end && *j.p == ']') { j.p++; break; }
                        ok = 0;
                        break;
                    }
            } else if (!jskip(&j, 1)) {
                ok = 0;
            }
            jws(&j);
            if (ok && j.p < j.end && *j.p == ',') j.p++;
        }
        bad = !ok || !found_rules;
    }
    free(text);
    if (bad) {
        char moved[1100];
        snprintf(moved, sizeof moved, "%s.bad", path);
        fprintf(stderr, "winvm: net: %s is not a list of port forwards: kept as %s\n", path, moved);
        rename(path, moved);
        nloaded = 0;
    }

    /* The machine's saved forwards come first. The former store's go, and a session forward (one the guest
       asked for, or one left from a machine that ran before in this process) on the port of an enabled saved
       one gives way. While the network thread runs, removed slots are only free once it has closed their
       listeners: it is given the chance before the saved forwards are added. */
    pthread_mutex_lock(&fwd_mu);
    snprintf(store_path, sizeof store_path, "%s", path);
    nkept_out = 0;
    for (int i = 0; i < MAX_RULES; i++)
        if (rules[i].used && !rules[i].removed && !rules[i].session) remove_locked(&rules[i]);
    for (int i = 0; i < nloaded; i++) {
        if (!loaded[i].enabled) continue;
        for (int k = 0; k < MAX_RULES; k++) {
            Rule *o = &rules[k];
            if (!o->used || o->removed || !o->session || !o->cfg.enabled) continue;
            if (o->cfg.host_port != loaded[i].host_port || !(o->cfg.proto & loaded[i].proto)) continue;
            fprintf(stderr, "winvm: net: session forward \"%s\" gives way to the saved \"%s\" (port %d)\n", o->cfg.name,
                    loaded[i].name, o->cfg.host_port);
            remove_locked(o);
        }
    }
    int running = net_running;
    fwd_changed_locked();
    pthread_mutex_unlock(&fwd_mu);
    if (running) {
        wake_net();
        hv_net_fwd_sync(1000);
    }

    pthread_mutex_lock(&fwd_mu);
    int skipped = 0;
    for (int i = 0; i < nloaded; i++) {
        char err[160];
        if (!loaded[i].id[0]) snprintf(loaded[i].id, sizeof loaded[i].id, "fwd-loaded-%d", i);
        if (put_locked(&loaded[i], 0, 0, err, sizeof err) == 0) continue;
        if (loaded[i].enabled) { /* its port is taken by a saved one before it: off for now, still saved as on */
            loaded[i].enabled = 0;
            char why[160];
            snprintf(why, sizeof why, "%s", err);
            if (put_locked(&loaded[i], 0, 0, err, sizeof err) == 0) {
                Rule *r = find_rule(loaded[i].id);
                if (r) r->load_off = 1, snprintf(r->blocked, sizeof r->blocked, "%s", why);
                fprintf(stderr, "winvm: net: saved forward \"%s\" off for now: %s\n", loaded[i].name, why);
                continue;
            }
            loaded[i].enabled = 1;
        }
        fprintf(stderr, "winvm: net: saved forward \"%s\" not loaded (kept in the file): %s\n", loaded[i].name, err);
        if (nkept_out < MAX_RULES) kept_out[nkept_out++] = loaded[i];
        skipped++;
    }
    fwd_changed_locked();
    pthread_mutex_unlock(&fwd_mu);
    fprintf(stderr, "winvm: net: %d port forward%s from %s\n", nloaded - skipped, nloaded - skipped == 1 ? "" : "s", path);
    wake_net();
    return bad ? -1 : 0;
}

void hv_net_fwd_refresh(void) {
    pthread_mutex_lock(&fwd_mu);
    for (int i = 0; i < MAX_RULES; i++) rules[i].dirty = 1;
    fwd_changed_locked();
    pthread_mutex_unlock(&fwd_mu);
    wake_net();
}

void hv_net_fwd_reopen(void) {
    pthread_mutex_lock(&fwd_mu);
    int open = 0;
    for (int i = 0; i < MAX_RULES; i++) {
        rules[i].dirty = rules[i].reopen = 1;
        open += rules[i].used && rules[i].cfg.enabled && net_running;
    }
    if (open) fprintf(stderr, "winvm: net: opening the port forwards again\n");
    fwd_changed_locked();
    pthread_mutex_unlock(&fwd_mu);
    wake_net();
}

int hv_net_fwd_sync(int timeout_ms) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += timeout_ms / 1000;
    until.tv_nsec += (long)(timeout_ms % 1000) * 1000000;
    if (until.tv_nsec >= 1000000000) until.tv_sec++, until.tv_nsec -= 1000000000;
    pthread_mutex_lock(&fwd_mu);
    uint64_t want = fwd_change_gen;
    int rc = 0;
    while (net_running && fwd_done_gen < want)
        if (pthread_cond_timedwait(&fwd_cond, &fwd_mu, &until) == ETIMEDOUT) {
            rc = fwd_done_gen < want ? -1 : 0;
            break;
        }
    pthread_mutex_unlock(&fwd_mu);
    return rc;
}

char *hv_net_fwd_list_json(void) {
    Buf b = {0};
    pthread_mutex_lock(&fwd_mu);
    bstr(&b, net_running ? "{\"running\":true,\"rules\":[" : "{\"running\":false,\"rules\":[");
    int first = 1;
    for (int i = 0; i < MAX_RULES; i++) {
        Rule *r = &rules[i];
        if (!r->used || r->removed) continue;
        const char *state = r->state;
        if (!r->cfg.enabled) state = "off";
        else if (!net_running) state = "waiting";
        bstr(&b, first ? "{\"id\":" : ",{\"id\":");
        bjson(&b, r->cfg.id);
        bstr(&b, ",\"name\":");
        bjson(&b, r->cfg.name);
        bstr(&b, ",\"protocol\":");
        bjson(&b, proto_name(r->cfg.proto));
        bstr(&b, ",\"hostPort\":");
        bint(&b, r->cfg.host_port);
        bstr(&b, ",\"guestPort\":");
        bint(&b, r->cfg.guest_port);
        bstr(&b, ",\"scope\":");
        bjson(&b, scope_name(r->cfg.scope));
        bstr(&b, r->cfg.enabled ? ",\"enabled\":true" : ",\"enabled\":false");
        bstr(&b, r->session ? ",\"session\":true,\"state\":" : ",\"session\":false,\"state\":");
        bjson(&b, state);
        int live = r->cfg.enabled && net_running;
        bstr(&b, ",\"code\":");
        bjson(&b, live ? r->code : r->load_off ? "blocked" : "");
        bstr(&b, ",\"message\":");
        bjson(&b, live ? r->msg : r->load_off ? r->blocked : "");
        bstr(&b, ",\"warning\":");
        bjson(&b, live ? r->warn : "");
        bstr(&b, ",\"listen\":[");
        for (int k = 0; live && k < r->nlisten; k++) {
            if (k) bstr(&b, ",");
            bjson(&b, r->listen[k]);
        }
        bstr(&b, "]}");
        first = 0;
    }
    bstr(&b, "]}");
    pthread_mutex_unlock(&fwd_mu);
    return b.p ? b.p : strdup("{\"running\":false,\"rules\":[]}");
}

/* ---- applying them (network thread) ---- */

static int fwd_rules_off(void) {
    const char *e = getenv("HV_NET_FWD_RULES"); /* 0: saved forwards are listed but not opened */
    return e && !strcmp(e, "0");
}

typedef struct Want {
    int ok;
    char code[16], msg[160];
    int n4;
    struct in_addr a4[FWD_ADDRS];
    int show4[FWD_ADDRS];  /* reachable as configured (not just the relays' way in) */
    struct in_addr relay;  /* the IPv4 listener the IPv6 relays hand their connections to */
    int n6;
    struct in6_addr a6[FWD_ADDRS];
} Want;

static void want4(Want *w, struct in_addr a, int show) {
    if (w->n4 < FWD_ADDRS) w->a4[w->n4] = a, w->show4[w->n4++] = show;
}
static void want6(Want *w, const struct in6_addr *a) {
    if (w->n6 < FWD_ADDRS) w->a6[w->n6++] = *a;
}

static void want_for(const HvFwdRule *c, const VpnAddr *vpn, const LanAddr *lan, Want *w) {
    memset(w, 0, sizeof *w);
    w->ok = 1;
    struct in_addr lo4 = {.s_addr = htonl(INADDR_LOOPBACK)};
    w->relay = lo4;
    switch (c->scope) {
    case HV_FWD_LAN: /* the local network's own addresses, and this device's apps */
        for (int k = 0; k < lan->n4; k++) want4(w, lan->a4[k], 1);
        want4(w, lo4, 1);
        for (int k = 0; k < lan->n6; k++) want6(w, &lan->a6[k]);
        want6(w, &in6addr_loopback);
        break;
    case HV_FWD_VPN:
        if (!vpn->has4 && !vpn->has6) {
            w->ok = 0;
            snprintf(w->code, sizeof w->code, "no_vpn");
            snprintf(w->msg, sizeof w->msg, "no VPN is connected");
            return;
        }
        if (vpn->has4) want4(w, vpn->a4, 1), w->relay = vpn->a4;
        else want4(w, lo4, 0); /* an IPv6-only VPN: the relay's way in */
        if (vpn->has6) want6(w, &vpn->a6);
        break;
    default:
        want4(w, lo4, 1);
        want6(w, &in6addr_loopback);
        break;
    }
}

static void fwd_teardown(Applied *ap) {
    for (int k = 0; k < ap->n4; k++) {
        if (ap->tcp4[k]) slirp_remove_hostfwd(slirp, 0, ap->a4[k], ap->host_port);
        if (ap->udp4[k]) slirp_remove_hostfwd(slirp, 1, ap->a4[k], ap->host_port);
    }
    for (int k = 0; k < ap->n6; k++) {
        bridge_stop(ap->tcp6[k]);
        bridge_stop(ap->udp6[k]);
    }
    memset(ap, 0, sizeof *ap);
}

static void errno_text(int e, int port, const char *proto, char *code, size_t cl, char *msg, size_t ml) {
    if (e == EADDRINUSE) {
        snprintf(code, cl, "in_use");
        snprintf(msg, ml, "port %d (%s) is in use by another app or forward on this device", port, proto);
    } else if (e == EACCES || e == EPERM) {
        snprintf(code, cl, "denied");
        snprintf(msg, ml, "the system does not let the app use port %d (%s)", port, proto);
    } else if (e == EADDRNOTAVAIL) {
        snprintf(code, cl, "no_address");
        snprintf(msg, ml, "the address for port %d (%s) is gone", port, proto);
    } else {
        snprintf(code, cl, "failed");
        snprintf(msg, ml, "port %d (%s): %s", port, proto, strerror(e));
    }
}

typedef struct Outcome {
    char state[12], code[16], msg[160], warn[160];
    char listen[FWD_LISTEN][64];
    int nlisten;
} Outcome;

static void fwd_apply(const HvFwdRule *c, const Want *w, Applied *ap, Outcome *o) {
    struct in_addr guest;
    inet_pton(AF_INET, "10.0.2.15", &guest);
    ap->proto = c->proto, ap->host_port = c->host_port, ap->guest_port = c->guest_port;
    ap->n4 = w->n4, ap->n6 = w->n6;
    memcpy(ap->a4, w->a4, sizeof ap->a4);
    memcpy(ap->a6, w->a6, sizeof ap->a6);
    for (int k = 0; k < w->n4; k++)
        for (int udp = 0; udp <= 1; udp++) {
            if (!(c->proto & (udp ? HV_FWD_UDP : HV_FWD_TCP))) continue;
            errno = 0;
            if (slirp_add_hostfwd(slirp, udp, w->a4[k], c->host_port, guest, c->guest_port) != 0) {
                int e = errno ? errno : EADDRINUSE;
                fwd_teardown(ap);
                snprintf(o->state, sizeof o->state, "error");
                errno_text(e, c->host_port, udp ? "UDP" : "TCP", o->code, sizeof o->code, o->msg, sizeof o->msg);
                return;
            }
            if (udp) ap->udp4[k] = 1;
            else ap->tcp4[k] = 1;
        }
    ap->on = 1;
    snprintf(o->state, sizeof o->state, "listening");
    char a[INET6_ADDRSTRLEN];
    for (int k = 0; k < w->n4 && o->nlisten < FWD_LISTEN; k++) {
        if (!w->show4[k]) continue;
        inet_ntop(AF_INET, &w->a4[k], a, sizeof a);
        snprintf(o->listen[o->nlisten++], sizeof o->listen[0], "%s:%d", a, c->host_port);
    }
    int e6 = 0;
    const char *p6 = NULL;
    for (int k = 0; k < w->n6; k++) {
        for (int udp = 0; udp <= 1; udp++) {
            if (!(c->proto & (udp ? HV_FWD_UDP : HV_FWD_TCP))) continue;
            int e = 0;
            Bridge *br = bridge_start(udp, &w->a6[k], c->host_port, w->relay, &e);
            if (udp) ap->udp6[k] = br;
            else ap->tcp6[k] = br;
            if (!br && !e6) e6 = e, p6 = udp ? "UDP" : "TCP";
        }
        if ((ap->tcp6[k] || ap->udp6[k]) && o->nlisten < FWD_LISTEN) {
            inet_ntop(AF_INET6, &w->a6[k], a, sizeof a);
            snprintf(o->listen[o->nlisten++], sizeof o->listen[0], "[%s]:%d", a, c->host_port);
        }
    }
    if (e6) {
        char code[16], msg[140];
        errno_text(e6, c->host_port, p6, code, sizeof code, msg, sizeof msg);
        snprintf(o->warn, sizeof o->warn, "IPv6: %s", msg);
    }
}

static int same_place(const Applied *ap, const HvFwdRule *c, const Want *w) {
    if (!ap->on || ap->proto != c->proto || ap->host_port != c->host_port || ap->guest_port != c->guest_port ||
        ap->n4 != w->n4 || ap->n6 != w->n6)
        return 0;
    for (int k = 0; k < w->n4; k++)
        if (ap->a4[k].s_addr != w->a4[k].s_addr) return 0;
    for (int k = 0; k < w->n6; k++)
        if (memcmp(&ap->a6[k], &w->a6[k], sizeof w->a6[k])) return 0;
    return 1;
}

typedef struct Snap {
    int used, removed, session, dirty, reopen, errored;
    uint64_t serial;
    HvFwdRule c;
    char state[12], msg[160], warn[160], listen0[64];
} Snap;

/* Make what is open match what the rules want: first close what changed, then open, so a forward that moved
   (edited, or removed and added again) does not find its own old listener in the way. periodic: the timer's pass,
   which retries forwards that failed and follows the VPN's address. */
static void fwd_reconcile(int periodic) {
    static Snap s[MAX_RULES];
    static Outcome o[MAX_RULES];
    static Want w[MAX_RULES];
    int act[MAX_RULES]; /* 0: as it is, 1: a new state, 2: a new state after opening */
    pthread_mutex_lock(&fwd_mu);
    uint64_t gen = fwd_change_gen;
    int need_vpn = 0, need_lan = 0;
    for (int i = 0; i < MAX_RULES; i++) {
        Rule *r = &rules[i];
        memset(&s[i], 0, sizeof s[i]);
        s[i].used = r->used, s[i].removed = r->removed, s[i].session = r->session, s[i].dirty = r->dirty;
        s[i].reopen = r->reopen;
        r->reopen = 0;
        s[i].errored = !strcmp(r->state, "error");
        s[i].serial = r->serial, s[i].c = r->cfg;
        memcpy(s[i].state, r->state, sizeof s[i].state);
        memcpy(s[i].msg, r->msg, sizeof s[i].msg);
        memcpy(s[i].warn, r->warn, sizeof s[i].warn);
        memcpy(s[i].listen0, r->nlisten ? r->listen[0] : "", r->nlisten ? sizeof s[i].listen0 : 1);
        r->dirty = 0;
        need_vpn |= r->used && !r->removed && r->cfg.enabled && r->cfg.scope == HV_FWD_VPN;
        need_lan |= r->used && !r->removed && r->cfg.enabled && r->cfg.scope == HV_FWD_LAN;
    }
    pthread_mutex_unlock(&fwd_mu);
    VpnAddr vpn;
    memset(&vpn, 0, sizeof vpn);
    if (need_vpn) vpn_lookup(&vpn);
    LanAddr lan;
    memset(&lan, 0, sizeof lan);
    if (need_lan) lan_lookup(&lan); /* followed on every pass, as the VPN's address is */
    int off = fwd_rules_off();

    for (int i = 0; i < MAX_RULES; i++) {
        act[i] = 0;
        if (!s[i].used) continue;
        Applied *ap = &rules[i].ap; /* network thread only */
        HvFwdRule *c = &s[i].c;
        int suspended = off && !s[i].session;
        memset(&o[i], 0, sizeof o[i]);
        act[i] = 1;
        if (s[i].removed || !c->enabled || suspended) {
            if (ap->on) fwd_teardown(ap);
            snprintf(o[i].state, sizeof o[i].state, "off");
            if (suspended && c->enabled) {
                snprintf(o[i].code, sizeof o[i].code, "env_off");
                snprintf(o[i].msg, sizeof o[i].msg, "saved forwards are off (HV_NET_FWD_RULES=0)");
            }
            continue;
        }
        want_for(c, &vpn, &lan, &w[i]);
        if (!w[i].ok) {
            if (ap->on) fwd_teardown(ap);
            snprintf(o[i].state, sizeof o[i].state, "error");
            snprintf(o[i].code, sizeof o[i].code, "%s", w[i].code);
            snprintf(o[i].msg, sizeof o[i].msg, "%s", w[i].msg);
        } else if (!s[i].reopen && !bridge_dead(ap) &&
                   (same_place(ap, c, &w[i]) || (!ap->on && s[i].errored && !s[i].dirty && !periodic))) {
            act[i] = 0; /* as it is (a failed one is tried again on the timer, or when it is changed) */
        } else {
            if (ap->on) fwd_teardown(ap);
            act[i] = 2;
        }
    }
    for (int i = 0; i < MAX_RULES; i++)
        if (act[i] == 2) fwd_apply(&s[i].c, &w[i], &rules[i].ap, &o[i]);

    pthread_mutex_lock(&fwd_mu);
    for (int i = 0; i < MAX_RULES; i++) {
        Rule *r = &rules[i];
        if (!act[i] || !r->used || r->serial != s[i].serial) continue;
        if (s[i].removed) {
            free_rule(r);
            continue;
        }
        set_state(r, o[i].state, o[i].code, o[i].msg);
        snprintf(r->warn, sizeof r->warn, "%s", o[i].warn);
        memcpy(r->listen, o[i].listen, sizeof r->listen);
        r->nlisten = o[i].nlisten;
    }
    if (gen > fwd_done_gen) fwd_done_gen = gen;
    pthread_cond_broadcast(&fwd_cond);
    pthread_mutex_unlock(&fwd_mu);

    for (int i = 0; i < MAX_RULES; i++) { /* the log: one line when a forward's state changes */
        if (!act[i] || (!strcmp(s[i].state, o[i].state) && !strcmp(s[i].msg, o[i].msg) && !strcmp(s[i].warn, o[i].warn) &&
                        !strcmp(s[i].listen0, o[i].nlisten ? o[i].listen[0] : "")))
            continue;
        const HvFwdRule *c = &s[i].c;
        if (s[i].removed)
            fprintf(stderr, "winvm: net: forward \"%s\" removed\n", c->name);
        else if (!strcmp(o[i].state, "listening"))
            fprintf(stderr, "winvm: net: forward \"%s\" %s %s%s%s -> 10.0.2.15:%d%s%s\n", c->name, proto_name(c->proto),
                    o[i].listen[0], o[i].nlisten > 1 ? " " : "", o[i].nlisten > 1 ? o[i].listen[1] : "", c->guest_port,
                    o[i].warn[0] ? "; " : "", o[i].warn);
        else if (!strcmp(o[i].state, "error"))
            fprintf(stderr, "winvm: net: forward \"%s\" not open: %s\n", c->name, o[i].msg);
        else if (strcmp(s[i].state, "waiting"))
            fprintf(stderr, "winvm: net: forward \"%s\" off\n", c->name);
    }
}

/* ---- the network thread ---- */

static void *net_thread(void *unused) {
    (void)unused;
    int64_t fwd_last = now_ms();
    for (;;) {
        uint32_t timeout = 1000;
        int64_t now = now_ms();
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire_ms >= 0) {
                int64_t left = timers[i].expire_ms - now;
                if (left < 0) left = 0;
                if ((uint64_t)left < timeout) timeout = (uint32_t)left;
            }
        npfd = 0;
        pfds[npfd++] = (struct pollfd){wake_pipe[0], POLLIN, 0};
        slirp_pollfds_fill_socket(slirp, &timeout, add_poll, NULL);
        int r = poll(pfds, (nfds_t)npfd, (int)timeout);
        if (pfds[0].revents & POLLIN) {
            char buf[64];
            while (read(wake_pipe[0], buf, sizeof buf) > 0) {}
        }
        pthread_mutex_lock(&fwd_mu);
        int fwd_changed = fwd_change_gen != fwd_done_gen;
        pthread_mutex_unlock(&fwd_mu);
        int64_t t = now_ms();
        int periodic = t - fwd_last >= FWD_PERIOD_MS;
        if (periodic) fwd_last = t;
        if (fwd_changed || periodic) fwd_reconcile(periodic);
        slirp_pollfds_poll(slirp, r < 0, get_revents, NULL);
        now = now_ms();
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire_ms >= 0 && timers[i].expire_ms <= now) {
                timers[i].expire_ms = -1;
                slirp_handle_timer(slirp, timers[i].id, timers[i].cb_opaque);
            }
        /* What the guest sent since. */
        for (;;) {
            pthread_mutex_lock(&to_host.mu);
            Frame f = {0, NULL};
            if (to_host.head != to_host.tail) f = to_host.f[to_host.head++ % QUEUE];
            pthread_mutex_unlock(&to_host.mu);
            if (!f.data) break;
            slirp_input(slirp, f.data, (int)f.len);
            free(f.data);
        }
    }
    return NULL;
}

/* A DNS lookup's thread (dns_proxy.c): its answer for the guest, or the query back for libslirp. */
static void dns_send(const uint8_t *frame, uint32_t len, int guest) {
    if (guest) {
        log_frame("rx dns", frame, len);
        if (push(&to_guest, frame, len)) hv_machine_wake(machine);
    } else if (push(&to_host, frame, len)) {
        char c = 0;
        (void)!write(wake_pipe[1], &c, 1);
    }
}

/* CPU thread: the guest sent a frame. */
static void transmit(void *opaque, const uint8_t *frame, uint32_t len) {
    (void)opaque;
    hv_net_tx_frames++;
    log_frame("tx", frame, len);
    if (hv_dns_proxy_take(frame, len, dns_send)) return;
    if (push(&to_host, frame, len)) {
        char c = 0;
        (void)!write(wake_pipe[1], &c, 1);
    }
}

void hv_net_poll(void) {
    if (!net) return;
    for (;;) {
        pthread_mutex_lock(&to_guest.mu);
        Frame f = {0, NULL};
        if (to_guest.head != to_guest.tail) f = to_guest.f[to_guest.head % QUEUE];
        pthread_mutex_unlock(&to_guest.mu);
        if (!f.data) return;
        if (!hv_virtio_net_receive(net, f.data, f.len)) return; /* no buffer posted yet: try again later */
        hv_net_rx_frames++;
        pthread_mutex_lock(&to_guest.mu);
        to_guest.head++;
        pthread_mutex_unlock(&to_guest.mu);
        free(f.data);
    }
}

int hv_net_attach(HvMachine *m, HvVirtioNet *n) {
    machine = m;
    pthread_mutex_init(&to_guest.mu, NULL);
    pthread_mutex_init(&to_host.mu, NULL);
    if (pipe(wake_pipe) != 0) return -1;
    fcntl(wake_pipe[0], F_SETFL, O_NONBLOCK);
    fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK);
    SlirpConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.version = 6; /* below 6 it calls the old register_poll_fd, which we leave unset */
    cfg.in_enabled = true;
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork);
    inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost);
    inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    const char *v6env = getenv("HV_IPV6");
    int v6 = !v6env || atoi(v6env) != 0; /* on unless 0 */
    struct in6_addr dns6;
    inet_pton(AF_INET6, V6_DNS, &dns6);
    if (v6) {
        cfg.in6_enabled = true;
        inet_pton(AF_INET6, V6_PREFIX, &cfg.vprefix_addr6);
        cfg.vprefix_len = 64;
        inet_pton(AF_INET6, V6_HOST, &cfg.vhost6);
        cfg.vnameserver6 = dns6;
    }
    cfg.vhostname = "hengevm";
    cfg.if_mtu = 1500;
    cfg.if_mru = 1500;
    slirp = slirp_new(&cfg, &callbacks, NULL);
    if (!slirp) return -1;
    hv_dns_proxy_set_nameserver6(v6 ? dns6.s6_addr : NULL);
    hv_dns_proxy_start(); /* before the guest can transmit: queries to 10.0.2.3 (and ::3) go to the host's resolver */
    fprintf(stderr, "winvm: net: IPv4 10.0.2.15/24%s\n", v6 ? ", IPv6 " V6_PREFIX "/64 (SLAAC)" : ", IPv6 off (HV_IPV6=0)");
    pthread_mutex_lock(&fwd_mu);
    int have_store = store_path[0] != 0;
    pthread_mutex_unlock(&fwd_mu);
    if (!have_store && getenv("HV_NET_FWD_FILE")) hv_net_fwd_set_store(getenv("HV_NET_FWD_FILE")); /* the Mac tool */
    if (getenv("HV_NET_FWD")) {
        /* TCP forwards into the guest for this session, comma-separated: "hostport:guestport" listens on the
           host's loopback, "lan:hostport:guestport" on every interface (other devices on the Wi-Fi or a VPN can
           connect; iOS asks for Local Network access), "vpn:hostport:guestport" on the VPN's address; these are
           session forwards in the list (IPv4 and IPv6). "a.b.c.d:hostport:guestport" listens on one IPv4
           address, outside the list. */
        char spec[256];
        snprintf(spec, sizeof spec, "%s", getenv("HV_NET_FWD"));
        char *save = NULL;
        for (char *item = strtok_r(spec, ", ", &save); item; item = strtok_r(NULL, ", ", &save)) {
            char bind[64] = "loopback";
            int hp = 0, gp = 0;
            if (sscanf(item, "%d:%d", &hp, &gp) == 2 && !strchr(strchr(item, ':') + 1, ':')) {
                /* loopback */
            } else if (sscanf(item, "%63[^:]:%d:%d", bind, &hp, &gp) != 3) {
                fprintf(stderr, "winvm: net: HV_NET_FWD: cannot read \"%s\"\n", item);
                continue;
            }
            int scope = !strcmp(bind, "loopback") ? HV_FWD_LOOPBACK : !strcmp(bind, "lan") ? HV_FWD_LAN
                      : !strcmp(bind, "vpn") ? HV_FWD_VPN : -1;
            struct in_addr h, g;
            if (hp < 1 || hp > 65535 || gp < 1 || gp > 65535 || (scope < 0 && inet_pton(AF_INET, bind, &h) != 1)) {
                fprintf(stderr, "winvm: net: HV_NET_FWD: bad forward \"%s\"\n", item);
                continue;
            }
            if (scope >= 0) {
                HvFwdRule r = {.proto = HV_FWD_TCP, .host_port = hp, .guest_port = gp, .scope = scope, .enabled = 1};
                char err[160];
                snprintf(r.name, sizeof r.name, "HV_NET_FWD %s%s%d", scope ? bind : "", scope ? ":" : "", hp);
                if (hv_net_fwd_put(&r, HV_FWD_SESSION, err, sizeof err) != 0)
                    fprintf(stderr, "winvm: net: HV_NET_FWD: no forward for \"%s\": %s\n", item, err);
                continue;
            }
            inet_pton(AF_INET, "10.0.2.15", &g);
            if (slirp_add_hostfwd(slirp, 0, h, hp, g, gp) != 0)
                fprintf(stderr, "winvm: net: no forward for %s:%d (port in use?)\n", bind, hp);
            else
                fprintf(stderr, "winvm: net: forwarded %s:%d -> 10.0.2.15:%d (HV_NET_FWD)\n", bind, hp, gp);
        }
    }
    if (share_socket[0]) { /* 10.0.2.4:80 is the shared folder and clipboard: see share.c */
        struct in_addr addr;
        inet_pton(AF_INET, HV_SHARE_ADDR, &addr);
        if (slirp_add_unix(slirp, share_socket, &addr, 80) != 0) fprintf(stderr, "hengevm: net: no route to the shared folder\n");
    }
    pthread_mutex_lock(&fwd_mu);
    net_running = 1; /* from here on the network thread opens and closes the forwards */
    fwd_changed_locked();
    pthread_mutex_unlock(&fwd_mu);
    net = n;
    n->transmit = transmit;
    pthread_t t;
    pthread_create(&t, NULL, net_thread, NULL);
    return 0;
}
