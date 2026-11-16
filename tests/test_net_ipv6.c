/* The guest's network end to end: host/net_slirp.c and host/dns_proxy.c over the real libslirp (Homebrew's, the
   same 4.9 line as the iOS build), with a stand-in virtio-net (frames for the guest are collected here) and a
   stand-in system resolver (answers *.test at once). No network is needed.

   libslirp is shown a resolver configuration without IPv6 name servers (resolv_no_ipv6.c), so whatever this
   Mac's own configuration lists, the advertisements test the case the proxy's announcement exists for: an iPhone
   on an IPv4-only network, or a configuration the app cannot read.

   Each scenario runs in its own process, since net_slirp.c attaches once:
   - default (IPv6 on): a Router Solicitation gets a Router Advertisement for fd2d:7064:6c3f:2::/64 (on-link,
     autonomous: SLAAC) naming fd2d:7064:6c3f:2::3 as DNS server (RDNSS, the proxy's announcement, told from
     libslirp's own by its lifetime); neighbour discovery of the host answers; an AAAA query to ::3 is answered through the resolver with a correct UDP checksum; a TCP connection
     to a closed port is refused at once (RST); TCP and UDP to an address the host cannot route fail at once
     (ICMPv6 unreachable, checked when this Mac has no route for 100::/64, the discard prefix); and IPv4 (ARP,
     DHCP, DNS to 10.0.2.3) still works.
   - HV_IPV6=0: no IPv6 at all (no advertisement, no answers), IPv4 as before.
   - HV_DNS_PROXY=0: the advertisement names no DNS server (libslirp has no IPv6 one to forward to, and the proxy,
     being off, announces none). test_dns_parse covers the announcement itself. */
#include "dns_proxy.h"
#include "net_slirp.h"

#include <arpa/inet.h>
#include <dns_sd.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
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
static void wr16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 8), p[1] = (uint8_t)v; }

/* ---- stand-ins for the machine, the virtio-net device and the system resolver ---- */

void hv_machine_wake(HvMachine *m) { (void)m; }

#define MAX_RX 4096
static uint8_t *rx[MAX_RX];
static uint32_t rx_len[MAX_RX];
static int nrx, cursor;

int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *frame, uint32_t len) {
    (void)n;
    if (nrx == MAX_RX) return 1;
    rx[nrx] = malloc(len);
    if (!rx[nrx]) exit(2);
    memcpy(rx[nrx], frame, len);
    rx_len[nrx++] = len;
    return 1;
}

typedef struct {
    int pipe[2];
    DNSServiceQueryRecordReply callback;
    void *context;
    uint16_t type;
} Resolver;
static atomic_int lookups;
static pthread_mutex_t name_mu = PTHREAD_MUTEX_INITIALIZER;
static char asked[256];
static uint16_t asked_type;

DNSServiceErrorType DNSServiceQueryRecord(DNSServiceRef *ref, DNSServiceFlags flags, uint32_t interface,
                                          const char *name, uint16_t type, uint16_t cls,
                                          DNSServiceQueryRecordReply callback, void *context) {
    (void)flags, (void)interface, (void)cls;
    Resolver *r = calloc(1, sizeof *r);
    if (!r || pipe(r->pipe)) exit(2);
    r->callback = callback, r->context = context, r->type = type;
    pthread_mutex_lock(&name_mu);
    snprintf(asked, sizeof asked, "%s", name);
    asked_type = type;
    pthread_mutex_unlock(&name_mu);
    atomic_fetch_add(&lookups, 1);
    *ref = (DNSServiceRef)r;
    (void)!write(r->pipe[1], "x", 1);
    return kDNSServiceErr_NoError;
}
int DNSServiceRefSockFD(DNSServiceRef ref) { return ((Resolver *)ref)->pipe[0]; }
DNSServiceErrorType DNSServiceProcessResult(DNSServiceRef ref) {
    Resolver *r = (Resolver *)ref;
    char byte;
    (void)!read(r->pipe[0], &byte, 1);
    static const uint8_t a[4] = {192, 0, 2, 1};
    static const uint8_t aaaa[16] = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    if (r->type == 1) r->callback(ref, kDNSServiceFlagsAdd, 0, 0, "x.test.", 1, 1, 4, a, 60, r->context);
    else if (r->type == 28) r->callback(ref, kDNSServiceFlagsAdd, 0, 0, "x.test.", 28, 1, 16, aaaa, 60, r->context);
    else r->callback(ref, 0, 0, kDNSServiceErr_NoSuchRecord, "x.test.", r->type, 1, 0, NULL, 0, r->context);
    return kDNSServiceErr_NoError;
}
void DNSServiceRefDeallocate(DNSServiceRef ref) {
    Resolver *r = (Resolver *)ref;
    close(r->pipe[0]), close(r->pipe[1]), free(r);
}

/* In resolv_no_ipv6.c (a library of its own, as dyld honours interposing only there): how often libslirp has read
   its name servers through the list without IPv6 ones. */
int hv_test_getservers_calls(void);

/* ---- the guest ---- */

static HvVirtioNet net;
static const uint8_t GUEST_MAC[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56};
static const uint8_t HOST_MAC[6] = {0x52, 0x55, 10, 0, 2, 2}; /* any unicast MAC: libslirp answers whatever it is */
static uint8_t PREFIX[16], HOST6[16], DNS6[16], GUEST6[16], GUEST_LL[16];

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void send_guest(const uint8_t *f, uint32_t len) { net.transmit(net.opaque, f, len); }

typedef int (*Match)(const uint8_t *f, uint32_t len);
/* The next frame for the guest that matches, within ms; frames that do not match are passed over. */
static const uint8_t *wait_frame(Match match, int ms, uint32_t *len) {
    int64_t end = now_ms() + ms;
    for (;;) {
        hv_net_poll();
        while (cursor < nrx) {
            int i = cursor++;
            if (match(rx[i], rx_len[i])) {
                *len = rx_len[i];
                return rx[i];
            }
        }
        if (now_ms() > end) return NULL;
        usleep(1000);
    }
}

/* RFC 1071 sums; over IPv6 with the pseudo-header for next header nh. */
static uint32_t sum16(uint32_t s, const uint8_t *p, uint32_t n) {
    for (uint32_t i = 0; i + 1 < n; i += 2) s += (uint32_t)(p[i] << 8 | p[i + 1]);
    if (n & 1) s += (uint32_t)p[n - 1] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return s;
}
static uint32_t sum6(const uint8_t *ip, uint8_t nh, const uint8_t *l4, uint32_t n) {
    return sum16(sum16(0, ip + 8, 32) + (n >> 16) + (n & 0xffff) + nh, l4, n);
}

/* An IPv6 frame from the guest: header for payload n with next header nh; returns the payload's start. */
static uint8_t *ip6_frame(uint8_t *f, const uint8_t *dst_mac, const uint8_t *src, const uint8_t *dst, uint8_t nh,
                          uint8_t hops, uint32_t n) {
    memset(f, 0, 14 + 40 + n);
    memcpy(f, dst_mac, 6), memcpy(f + 6, GUEST_MAC, 6);
    f[12] = 0x86, f[13] = 0xdd;
    uint8_t *ip = f + 14;
    ip[0] = 0x60, wr16(ip + 4, n), ip[6] = nh, ip[7] = hops;
    memcpy(ip + 8, src, 16), memcpy(ip + 24, dst, 16);
    return ip + 40;
}
static void finish6(uint8_t *f, uint32_t csum_at) { /* the checksum of the payload, at csum_at within it */
    uint8_t *ip = f + 14, *l4 = ip + 40;
    uint32_t n = rd16(ip + 4);
    wr16(l4 + csum_at, 0);
    uint16_t c = (uint16_t)~sum6(ip, ip[6], l4, n);
    if (ip[6] == 17 && !c) c = 0xffff;
    wr16(l4 + csum_at, c);
}

/* A DNS question for name (dotted, e.g. "v6.test") of type qtype, with ID 0x4242; returns its length. */
static uint32_t dns_query(uint8_t *d, const char *name, uint16_t qtype) {
    memset(d, 0, 12);
    d[0] = 0x42, d[1] = 0x42, d[2] = 1, d[5] = 1;
    uint32_t n = 12;
    for (const char *s = name; *s;) {
        const char *dot = strchr(s, '.');
        size_t l = dot ? (size_t)(dot - s) : strlen(s);
        d[n++] = (uint8_t)l;
        memcpy(d + n, s, l), n += (uint32_t)l;
        s += l + (dot ? 1 : 0);
    }
    d[n++] = 0;
    wr16(d + n, qtype), wr16(d + n + 2, 1);
    return n + 4;
}

static int is_v6(const uint8_t *f, uint32_t len) { return len >= 54 && f[12] == 0x86 && f[13] == 0xdd; }
static int is_ra(const uint8_t *f, uint32_t len) { return is_v6(f, len) && f[20] == 58 && len >= 70 && f[54] == 134; }
static int is_na_host(const uint8_t *f, uint32_t len) {
    return is_v6(f, len) && f[20] == 58 && len >= 78 && f[54] == 136 && !memcmp(f + 62, HOST6, 16);
}
static int is_dns6_reply(const uint8_t *f, uint32_t len) {
    return is_v6(f, len) && f[20] == 17 && len >= 62 && rd16(f + 54) == 53 && rd16(f + 56) == 40000;
}
static int is_tcp6_to_40001(const uint8_t *f, uint32_t len) {
    return is_v6(f, len) && f[20] == 6 && len >= 74 && rd16(f + 56) == 40001;
}
static int is_unreach6_40002(const uint8_t *f, uint32_t len) { /* ICMPv6 unreachable quoting our SYN from 40002 */
    return is_v6(f, len) && f[20] == 58 && len >= 54 + 8 + 40 + 4 && f[54] == 1 && f[62 + 6] == 6 &&
           rd16(f + 62 + 40) == 40002;
}
static int is_unreach6_40004(const uint8_t *f, uint32_t len) { /* the same for a UDP datagram from 40004 */
    return is_v6(f, len) && f[20] == 58 && len >= 54 + 8 + 40 + 4 && f[54] == 1 && f[62 + 6] == 17 &&
           rd16(f + 62 + 40) == 40004;
}
static int any_v6(const uint8_t *f, uint32_t len) { return is_v6(f, len); }
static int is_arp_reply(const uint8_t *f, uint32_t len) {
    return len >= 42 && f[12] == 8 && f[13] == 6 && rd16(f + 20) == 2 && f[28] == 10 && f[29] == 0 && f[30] == 2 &&
           f[31] == 2;
}
static int is_dhcp_offer(const uint8_t *f, uint32_t len) {
    return len >= 14 + 20 + 8 + 240 && f[12] == 8 && f[13] == 0 && f[23] == 17 && rd16(f + 36) == 68;
}
static int is_dns4_reply(const uint8_t *f, uint32_t len) {
    return len >= 14 + 20 + 8 + 12 && f[12] == 8 && f[13] == 0 && f[23] == 17 && rd16(f + 34) == 53 &&
           rd16(f + 36) == 40003;
}

/* ---- IPv6 ---- */

/* The lifetime of the proxy's RDNSS option, in seconds (RDNSS_LIFETIME in dns_proxy.c); libslirp's own differs
   (2 * NDP_MaxRtrAdvInterval, which it keeps in milliseconds: 1,200,000). */
#define PROXY_RDNSS_LIFETIME 1200u

static void router_discovery(int v6, int expect_rdnss) {
    uint8_t f[200];
    static const uint8_t all_routers[16] = {0xff, 2, [15] = 2}, mac[6] = {0x33, 0x33, 0, 0, 0, 2};
    uint8_t *icmp = ip6_frame(f, mac, GUEST_LL, all_routers, 58, 255, 16);
    icmp[0] = 133;                                         /* Router Solicitation */
    icmp[8] = 1, icmp[9] = 1, memcpy(icmp + 10, GUEST_MAC, 6); /* source link-layer address */
    finish6(f, 2);
    send_guest(f, 14 + 40 + 16);
    uint32_t len;
    const uint8_t *ra = wait_frame(is_ra, 2000, &len);
    if (!v6) {
        check("HV_IPV6=0: no Router Advertisement", !ra);
        return;
    }
    check("Router Advertisement for the solicitation", ra != NULL);
    if (!ra) return;
    const uint8_t *ip = ra + 14, *ra_icmp = ip + 40;
    uint32_t plen = rd16(ip + 4);
    check("RA fits its frame", 54 + plen <= len && plen >= 16);
    if (54 + plen > len || plen < 16) return;
    check("RA checksum", sum6(ip, 58, ra_icmp, plen) == 0xffff);
    check("RA hop limit 255", ip[7] == 255);
    check("RA router lifetime (a default route)", rd16(ra_icmp + 6) > 0);
    check("RA: no DHCPv6 needed (M and O clear)", (ra_icmp[5] & 0xc0) == 0);
    int prefixes = 0, rdnss = 0, rdnss_ok = 0;
    uint32_t rdnss_lifetime = 0;
    for (uint32_t off = 16; off + 2 <= plen;) {
        uint32_t olen = ra_icmp[off + 1] * 8u;
        if (!olen || off + olen > plen) {
            check("RA options well formed", 0);
            break;
        }
        const uint8_t *o = ra_icmp + off;
        if (o[0] == 3 && olen == 32) {
            prefixes++;
            check("RA prefix /64", o[2] == 64);
            check("RA prefix on-link and autonomous (SLAAC)", (o[3] & 0xc0) == 0xc0);
            check("RA prefix fd2d:7064:6c3f:2::", !memcmp(o + 16, PREFIX, 16));
            check("RA prefix lifetimes", rd16(o + 4) | rd16(o + 6) && (rd16(o + 8) | rd16(o + 10)));
        } else if (o[0] == 25 && olen >= 24) {
            rdnss++;
            rdnss_ok = !memcmp(o + 8, DNS6, 16);
            rdnss_lifetime = (uint32_t)rd16(o + 4) << 16 | rd16(o + 6);
        }
        off += olen;
    }
    check("RA has one prefix", prefixes == 1);
    if (expect_rdnss) {
        check("RA has one RDNSS", rdnss == 1);
        check("RDNSS names fd2d:7064:6c3f:2::3", rdnss_ok);
        check("RDNSS is the proxy's announcement (its lifetime)", rdnss_lifetime == PROXY_RDNSS_LIFETIME);
    } else {
        check("RA names no DNS server it cannot answer for", rdnss == 0);
    }
}

static void neighbour_discovery(int v6) {
    uint8_t f[200];
    uint8_t solicited[16] = {0xff, 2, [11] = 1, [12] = 0xff};
    memcpy(solicited + 13, HOST6 + 13, 3);
    static const uint8_t mac[6] = {0x33, 0x33, 0xff, 0, 0, 2};
    uint8_t *icmp = ip6_frame(f, mac, GUEST6, solicited, 58, 255, 32);
    icmp[0] = 135; /* Neighbor Solicitation for the host, from the guest's SLAAC address */
    memcpy(icmp + 8, HOST6, 16);
    icmp[24] = 1, icmp[25] = 1, memcpy(icmp + 26, GUEST_MAC, 6);
    finish6(f, 2);
    send_guest(f, 14 + 40 + 32);
    uint32_t len;
    const uint8_t *na = wait_frame(is_na_host, 2000, &len);
    if (!v6) {
        check("HV_IPV6=0: no Neighbor Advertisement", !na);
        return;
    }
    check("Neighbor Advertisement for the host", na != NULL);
    if (na) check("NA to the guest's MAC", !memcmp(na, GUEST_MAC, 6));
}

static void dns6(int v6) {
    uint8_t f[300], q[200];
    uint32_t qn = dns_query(q, "v6.test", 28);
    static const uint8_t dns_mac[6] = {0x52, 0x56, 0, 0, 0, 3};
    uint8_t *udp = ip6_frame(f, dns_mac, GUEST6, DNS6, 17, 64, 8 + qn);
    wr16(udp, 40000), wr16(udp + 2, 53), wr16(udp + 4, 8 + qn);
    memcpy(udp + 8, q, qn);
    finish6(f, 6);
    int before = atomic_load(&lookups);
    send_guest(f, 14 + 40 + 8 + qn);
    uint32_t len;
    const uint8_t *r = wait_frame(is_dns6_reply, 3000, &len);
    if (!v6) {
        check("HV_IPV6=0: no IPv6 DNS answer", !r);
        check("HV_IPV6=0: the resolver was not asked over IPv6", atomic_load(&lookups) == before);
        return;
    }
    check("AAAA query over IPv6 answered", r != NULL);
    if (!r) return;
    const uint8_t *ip = r + 14, *ru = ip + 40, *d = ru + 8;
    uint32_t plen = rd16(ip + 4);
    check("IPv6 DNS answer fits its frame", 54 + plen <= len && plen >= 8 + 12);
    if (54 + plen > len || plen < 20) return;
    check("IPv6 DNS answer from fd2d:7064:6c3f:2::3", !memcmp(ip + 8, DNS6, 16));
    check("IPv6 DNS answer to the guest", !memcmp(ip + 24, GUEST6, 16) && !memcmp(r, GUEST_MAC, 6));
    check("IPv6 DNS answer UDP length", rd16(ru + 4) == plen);
    check("IPv6 DNS answer UDP checksum", rd16(ru + 6) && sum6(ip, 17, ru, plen) == 0xffff);
    check("IPv6 DNS answer: response, ID, one answer", d[0] == 0x42 && d[1] == 0x42 && (d[2] & 0x80) &&
                                                          (d[3] & 15) == 0 && rd16(d + 6) == 1);
    static const uint8_t aaaa[16] = {0x20, 0x01, 0x0d, 0xb8, [15] = 1};
    check("IPv6 DNS answer carries the resolver's AAAA", plen >= 16 && !memcmp(ru + plen - 16, aaaa, 16));
    pthread_mutex_lock(&name_mu);
    check("resolver asked for v6.test. AAAA", !strcmp(asked, "v6.test.") && asked_type == 28);
    pthread_mutex_unlock(&name_mu);
}

/* A TCP SYN from the guest's port sport to dst:dport. */
static void syn6(const uint8_t *dst, uint16_t sport, uint16_t dport) {
    uint8_t f[200];
    uint8_t *tcp = ip6_frame(f, HOST_MAC, GUEST6, dst, 6, 64, 20);
    wr16(tcp, sport), wr16(tcp + 2, dport);
    tcp[4] = 0x12, tcp[5] = 0x34, tcp[6] = 0x56, tcp[7] = 0x78; /* sequence */
    tcp[12] = 5 << 4, tcp[13] = 0x02;                           /* SYN */
    wr16(tcp + 14, 65535);
    finish6(f, 16);
    send_guest(f, 14 + 40 + 20);
}

static void fail_fast(int v6) {
    /* A port nothing listens on, on the host's loopback (libslirp maps the prefix's addresses to [::1]). */
    int s = socket(AF_INET6, SOCK_STREAM, 0);
    struct sockaddr_in6 a = {.sin6_family = AF_INET6, .sin6_addr = IN6ADDR_LOOPBACK_INIT};
    socklen_t al = sizeof a;
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) || getsockname(s, (struct sockaddr *)&a, &al)) exit(2);
    uint16_t closed = ntohs(a.sin6_port);
    close(s);
    int64_t t0 = now_ms();
    syn6(HOST6, 40001, closed);
    uint32_t len;
    const uint8_t *r = wait_frame(is_tcp6_to_40001, 2000, &len);
    if (!v6) {
        check("HV_IPV6=0: no TCP over IPv6", !r);
        return;
    }
    check("TCP to a closed port: answered within 1 s", r && now_ms() - t0 < 1000);
    if (r) check("TCP to a closed port: refused (RST)", (r[54 + 13] & 0x04) != 0);

    /* An address this host cannot route (100::/64, RFC 6666's discard prefix): when connect() here fails at once,
       as it does without IPv6 connectivity, the guest must hear so at once, not wait for its SYN to time out. */
    static const uint8_t discard[16] = {1, 0, [15] = 1};
    s = socket(AF_INET6, SOCK_STREAM, 0);
    fcntl(s, F_SETFL, O_NONBLOCK);
    struct sockaddr_in6 d = {.sin6_family = AF_INET6, .sin6_port = htons(80)};
    memcpy(&d.sin6_addr, discard, 16);
    int rc = connect(s, (struct sockaddr *)&d, sizeof d), err = errno;
    close(s);
    if (rc == 0 || err == EINPROGRESS) {
        printf("net: this Mac routes 100::/64, so the unreachable-IPv6 check is skipped\n");
        return;
    }
    t0 = now_ms();
    syn6(discard, 40002, 80);
    r = wait_frame(is_unreach6_40002, 2000, &len);
    check("TCP to an unroutable IPv6 address: ICMPv6 unreachable within 1 s", r && now_ms() - t0 < 1000);
    uint8_t f[200];
    uint8_t *udp = ip6_frame(f, HOST_MAC, GUEST6, discard, 17, 64, 8 + 4);
    wr16(udp, 40004), wr16(udp + 2, 9), wr16(udp + 4, 8 + 4);
    memcpy(udp + 8, "ping", 4);
    finish6(f, 6);
    t0 = now_ms();
    send_guest(f, 14 + 40 + 12);
    r = wait_frame(is_unreach6_40004, 2000, &len);
    check("UDP to an unroutable IPv6 address: ICMPv6 unreachable within 1 s", r && now_ms() - t0 < 1000);
}

/* ---- IPv4, unchanged ---- */

static uint16_t ip4_sum(const uint8_t *ip) { return (uint16_t)~sum16(0, ip, 20); }
static uint8_t *ip4_frame(uint8_t *f, const uint8_t *dst_mac, uint32_t src, uint32_t dst, uint32_t udplen) {
    memset(f, 0, 14 + 20 + udplen);
    memcpy(f, dst_mac, 6), memcpy(f + 6, GUEST_MAC, 6);
    f[12] = 8;
    uint8_t *ip = f + 14;
    ip[0] = 0x45, wr16(ip + 2, 20 + udplen), ip[8] = 64, ip[9] = 17;
    ip[12] = (uint8_t)(src >> 24), ip[13] = (uint8_t)(src >> 16), ip[14] = (uint8_t)(src >> 8), ip[15] = (uint8_t)src;
    ip[16] = (uint8_t)(dst >> 24), ip[17] = (uint8_t)(dst >> 16), ip[18] = (uint8_t)(dst >> 8), ip[19] = (uint8_t)dst;
    wr16(ip + 10, ip4_sum(ip));
    return ip + 20;
}

static void ipv4(void) {
    uint8_t f[600];
    static const uint8_t bcast[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    /* DHCP: the guest gets 10.0.2.15. */
    uint8_t *udp = ip4_frame(f, bcast, 0, 0xffffffff, 8 + 300);
    wr16(udp, 68), wr16(udp + 2, 67), wr16(udp + 4, 8 + 300);
    uint8_t *b = udp + 8;
    b[0] = 1, b[1] = 1, b[2] = 6, b[4] = 0xde, b[5] = 0xad, b[6] = 0xbe, b[7] = 0xef;
    memcpy(b + 28, GUEST_MAC, 6);
    b[236] = 99, b[237] = 130, b[238] = 83, b[239] = 99; /* magic cookie */
    b[240] = 53, b[241] = 1, b[242] = 1, b[243] = 255;   /* DHCPDISCOVER */
    send_guest(f, 14 + 20 + 8 + 300);
    uint32_t len;
    const uint8_t *r = wait_frame(is_dhcp_offer, 2000, &len);
    check("DHCP offer", r != NULL);
    if (r) check("DHCP offers 10.0.2.15", r[42 + 16] == 10 && r[42 + 17] == 0 && r[42 + 18] == 2 && r[42 + 19] == 15);

    /* ARP for the gateway. */
    memset(f, 0, 42);
    memcpy(f, bcast, 6), memcpy(f + 6, GUEST_MAC, 6);
    f[12] = 8, f[13] = 6;
    uint8_t *arp = f + 14;
    wr16(arp, 1), wr16(arp + 2, 0x800), arp[4] = 6, arp[5] = 4, wr16(arp + 6, 1);
    memcpy(arp + 8, GUEST_MAC, 6);
    arp[14] = 10, arp[16] = 2, arp[17] = 15, arp[24] = 10, arp[26] = 2, arp[27] = 2;
    send_guest(f, 42);
    check("ARP reply for 10.0.2.2", wait_frame(is_arp_reply, 2000, &len) != NULL);

    /* DNS to 10.0.2.3, through the proxy. */
    uint8_t q[200];
    uint32_t qn = dns_query(q, "v4.test", 1);
    udp = ip4_frame(f, HOST_MAC, 0x0a00020f, 0x0a000203, 8 + qn);
    wr16(udp, 40003), wr16(udp + 2, 53), wr16(udp + 4, 8 + qn);
    memcpy(udp + 8, q, qn);
    send_guest(f, 14 + 20 + 8 + qn);
    r = wait_frame(is_dns4_reply, 3000, &len);
    check("A query over IPv4 answered", r != NULL);
    static const uint8_t a[4] = {192, 0, 2, 1};
    if (r) check("IPv4 DNS answer carries the resolver's A", !memcmp(r + len - 4, a, 4) && rd16(r + 42 + 6) == 1);
}

enum { IPV6_ON, IPV6_OFF, PROXY_OFF };
static const char *const scenario_names[] = {"IPv6 on", "HV_IPV6=0", "HV_DNS_PROXY=0"};

static int scenario(int which) {
    int v6 = which != IPV6_OFF;
    alarm(30);
    inet_pton(AF_INET6, "fd2d:7064:6c3f:2::", PREFIX);
    inet_pton(AF_INET6, "fd2d:7064:6c3f:2::2", HOST6);
    inet_pton(AF_INET6, "fd2d:7064:6c3f:2::3", DNS6);
    inet_pton(AF_INET6, "fd2d:7064:6c3f:2:5054:ff:fe12:3456", GUEST6); /* the guest's SLAAC (EUI-64) address */
    inet_pton(AF_INET6, "fe80::5054:ff:fe12:3456", GUEST_LL);
    if (v6) unsetenv("HV_IPV6");
    else setenv("HV_IPV6", "0", 1);
    if (which == PROXY_OFF) setenv("HV_DNS_PROXY", "0", 1);
    else unsetenv("HV_DNS_PROXY");
    unsetenv("HV_NET_FWD");
    if (hv_net_attach(NULL, &net) != 0) {
        fprintf(stderr, "FAIL: hv_net_attach\n");
        return 1;
    }
    if (which == PROXY_OFF) {
        /* Without the proxy, nothing names a DNS server (and no query is sent here: libslirp would send it to this
           Mac's real name server). */
        router_discovery(v6, 0);
    } else {
        router_discovery(v6, 1);
        neighbour_discovery(v6);
        dns6(v6);
        fail_fast(v6);
        ipv4();
    }
    /* Else the advertisements would show this Mac's own resolver configuration, not the case tested here. */
    if (v6) check("libslirp read its name servers through the interposed res_getservers",
                  hv_test_getservers_calls() > 0);
    if (!v6) {
        uint32_t len;
        usleep(200 * 1000);
        cursor = 0; /* everything the guest was sent, from the start */
        check("HV_IPV6=0: nothing over IPv6 at all", !wait_frame(any_v6, 0, &len));
    }
    printf("net (%s): %d failures\n", scenario_names[which], failures);
    fflush(stdout); /* the child leaves by _exit */
    return failures != 0;
}

int main(void) {
    int bad = 0;
    for (int which = IPV6_ON; which <= PROXY_OFF; which++) {
        fflush(stdout);
        pid_t pid = fork();
        if (pid < 0) return 2;
        if (pid == 0) _exit(scenario(which));
        int status = 0;
        waitpid(pid, &status, 0);
        if (!WIFEXITED(status) || WEXITSTATUS(status)) {
            fprintf(stderr, "FAIL: scenario %s (status %d)\n", scenario_names[which], status);
            bad = 1;
        }
    }
    printf("net: %s\n", bad ? "FAILED" : "ok");
    return bad;
}
