/* The guest's DNS through the host's own resolver (issue #34).

   libslirp answers the guest's queries to 10.0.2.3 by sending them on to the host's first IPv4 name server, which
   fails where there is none (IPv6-only networks) or where the right one is somewhere else (a VPN's split DNS, iOS's
   per-interface resolvers). Here each UDP query is answered from DNSServiceQueryRecord instead, the resolver every
   iOS and macOS app uses: it knows the system's whole DNS configuration and caches.

   One query, one short-lived thread. The answer goes back as the frame 10.0.2.3 would have sent. A query this does
   not understand, or one whose lookup cannot even start, goes to libslirp as before; so do .local names (asking for
   those on iOS brings up the local network privacy prompt).

   Ported from Henge (Leviidev/Henge 2eb9b77, 17e9ed9, b537dbb, 6aefa03). Here the on/off switch is this file's own
   (HV_DNS_PROXY, read at each hv_dns_proxy_start) instead of one of Henge's engine knobs, and the reverse names of
   link-local addresses also stay with libslirp.

   IPv6: queries to the guest's IPv6 name server (hv_dns_proxy_set_nameserver6) are answered the same way. Only the
   plain form is taken: UDP right after the fixed IPv6 header (no extension headers), a payload length that the frame
   holds and that is exactly the UDP datagram, and a correct UDP checksum (mandatory over IPv6); anything else goes
   to libslirp untouched. The answer carries its own UDP checksum. */
#include "dns_proxy.h"

#include <dns_sd.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define MAX_QUERY 512
#define MAX_ANSWERS 64
#define MAX_RDATA 1024
#define MAX_INFLIGHT 64
#define TIMEOUT_MS 4000
#define MAX_UDP4 1472 /* the largest answer in one unfragmented 1500-byte frame: 1500 - 20 (IPv4) - 8 (UDP) */
#define MAX_UDP6 1452 /* 1500 - 40 (IPv6) - 8 */

typedef struct {
    uint16_t type, rclass, rdlen;
    uint32_t ttl;
    uint8_t rdata[MAX_RDATA];
} Answer;

typedef struct {
    HvDnsSend send;
    uint8_t frame[14 + 60 + 8 + MAX_QUERY]; /* the guest's query, for its addresses (and to hand back) */
    uint32_t len;
    uint32_t ip_off, udp_off, dns_off, qend; /* offsets into frame; qend: the end of the question */
    uint16_t qtype, qclass, udp_max;
    int edns, v6;
    char name[1025];
    Answer ans[MAX_ANSWERS];
    int nans, nodata, failed, done;
} Query;

static atomic_int inflight, unanswered_in_a_row;
static atomic_ullong answered, handed_back, timed_out;
#define GIVE_UP 8 /* lookups in a row the resolver took but never answered: back to libslirp for the session */
static atomic_int stopping;
static atomic_int enabled; /* this session: HV_DNS_PROXY (on unless 0), until the resolver gives up (GIVE_UP) */
static pthread_mutex_t lifecycle_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t lifecycle_cv = PTHREAD_COND_INITIALIZER;
static uint8_t nameserver6[16]; /* the guest's IPv6 name server, if ns6_set */
static atomic_int ns6_set;

void hv_dns_proxy_set_nameserver6(const uint8_t *addr16) {
    atomic_store(&ns6_set, 0);
    if (!addr16) return;
    memcpy(nameserver6, addr16, 16);
    atomic_store(&ns6_set, 1); /* sequentially consistent: the address is visible to whoever sees the flag */
}

static void lookup_finished(void) {
    pthread_mutex_lock(&lifecycle_mu);
    atomic_fetch_sub(&inflight, 1);
    pthread_cond_broadcast(&lifecycle_cv);
    pthread_mutex_unlock(&lifecycle_mu);
}

void hv_dns_proxy_start(void) {
    pthread_mutex_lock(&lifecycle_mu);
    atomic_store(&stopping, 0);
    const char *env = getenv("HV_DNS_PROXY");
    atomic_store(&enabled, env ? atoi(env) != 0 : 1);
    atomic_store(&answered, 0);
    atomic_store(&handed_back, 0);
    atomic_store(&timed_out, 0);
    atomic_store(&unanswered_in_a_row, 0);
    pthread_mutex_unlock(&lifecycle_mu);
}

void hv_dns_proxy_stop(void) {
    pthread_mutex_lock(&lifecycle_mu);
    atomic_store(&stopping, 1);
    while (atomic_load(&inflight)) pthread_cond_wait(&lifecycle_cv, &lifecycle_mu);
    pthread_mutex_unlock(&lifecycle_mu);
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static void wr16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 8), p[1] = (uint8_t)v; }

/* The question's name in the form DNSServiceQueryRecord takes ("a.b.c.", dots and backslashes in labels escaped,
   other unprintable bytes as \DDD). Returns the offset after the name's terminating zero, or 0. */
static uint32_t read_name(const uint8_t *m, uint32_t len, uint32_t off, char *out, size_t cap, int *local) {
    size_t n = 0;
    const uint8_t *last = NULL;
    uint8_t lastlen = 0;
    for (;;) {
        if (off >= len) return 0;
        uint8_t l = m[off++];
        if (!l) break;
        if (l & 0xc0) return 0; /* no compression in a question we take */
        if (off + l > len) return 0;
        last = m + off, lastlen = l;
        for (uint8_t i = 0; i < l; i++) {
            uint8_t c = m[off + i];
            if (n + 5 >= cap) return 0;
            if (c == '.' || c == '\\') out[n++] = '\\', out[n++] = (char)c;
            else if (c <= ' ' || c >= 0x7f) n += (size_t)snprintf(out + n, cap - n, "\\%03u", c);
            else out[n++] = (char)c;
        }
        off += l;
        if (n + 2 >= cap) return 0;
        out[n++] = '.';
    }
    if (!n) out[n++] = '.';
    out[n] = 0;
    *local = last && lastlen == 5 && !strncasecmp((const char *)last, "local", 5);
    return off;
}

/* Reverse names of link-local addresses (169.254/16, fe80::/10): mDNSResponder answers those by multicast too
   (RFC 6762 section 4), so like .local they stay with libslirp and never bring up the local network prompt. */
static int link_local_reverse(const char *name) {
    static const char *const zones[] = {"254.169.in-addr.arpa.", "8.e.f.ip6.arpa.", "9.e.f.ip6.arpa.",
                                        "a.e.f.ip6.arpa.", "b.e.f.ip6.arpa."};
    size_t n = strlen(name);
    for (size_t i = 0; i < sizeof zones / sizeof zones[0]; i++) {
        size_t z = strlen(zones[i]);
        if ((n == z || (n > z && name[n - z - 1] == '.')) && !strcasecmp(name + n - z, zones[i])) return 1;
    }
    return 0;
}

static void DNSSD_API on_record(DNSServiceRef ref, DNSServiceFlags flags, uint32_t ifindex, DNSServiceErrorType err,
                                const char *fullname, uint16_t rrtype, uint16_t rrclass, uint16_t rdlen,
                                const void *rdata, uint32_t ttl, void *ctx) {
    (void)ref, (void)ifindex, (void)fullname;
    Query *q = ctx;
    int more = (flags & kDNSServiceFlagsMoreComing) != 0;
    if (err == kDNSServiceErr_NoSuchRecord || err == kDNSServiceErr_NoSuchName) {
        q->nodata = 1; /* no such name, or nothing of this type: either way an empty answer */
    } else if (err) {
        q->failed = 1;
        q->done = 1;
        return;
    } else if (flags & kDNSServiceFlagsAdd) {
        /* Records of the type asked for, under the name asked for: a CNAME chain on the way (an intermediate
           result) is left out, the guest only needs what is at its end. */
        int wanted = rrtype == q->qtype || (q->qtype == 255 && rrtype != 5);
        if (wanted && q->nans < MAX_ANSWERS && rdlen <= MAX_RDATA) {
            Answer *a = &q->ans[q->nans++];
            a->type = rrtype, a->rclass = rrclass, a->rdlen = rdlen, a->ttl = ttl;
            memcpy(a->rdata, rdata, rdlen);
        }
    }
    /* Done at the end of a batch that answered (or said there is nothing); a batch of CNAMEs alone is not the end. */
    if (!more && (q->nans || q->nodata)) q->done = 1;
}

/* One's-complement sum of n bytes (RFC 1071), added to s; folded to 16 bits. */
static uint32_t sum16(uint32_t s, const uint8_t *p, uint32_t n) {
    for (uint32_t i = 0; i + 1 < n; i += 2) s += (uint32_t)(p[i] << 8 | p[i + 1]);
    if (n & 1) s += (uint32_t)p[n - 1] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return s;
}

static uint16_t ip_checksum(const uint8_t *p, uint32_t n) {
    return (uint16_t)~sum16(0, p, n);
}

/* The sum of a UDP datagram over IPv6 with its pseudo-header (RFC 8200 section 8.1): ip is the IPv6 header, for its
   addresses. 0xffff when the datagram's own checksum field is right. */
static uint32_t udp6_sum(const uint8_t *ip, const uint8_t *udp, uint32_t udplen) {
    uint32_t s = sum16(0, ip + 8, 32); /* source and destination */
    s += (udplen >> 16) + (udplen & 0xffff) + 17;
    return sum16(s, udp, udplen);
}

/* The reply frame, from the name server the guest asked (10.0.2.3, or the IPv6 one) port 53 to the guest's port,
   with rcode and the answers that fit. */
static void reply(Query *q, int rcode) {
    const uint32_t hl = q->v6 ? 40 : 20;
    const size_t cap = 14 + hl + 8 + 4096;
    uint8_t *f = calloc(1, cap);
    if (!f) return;
    const uint8_t *in = q->frame;
    memcpy(f, in + 6, 6);     /* to the guest's MAC */
    memcpy(f + 6, in, 6);     /* from the one it sent to */
    f[12] = q->v6 ? 0x86 : 0x08, f[13] = q->v6 ? 0xdd : 0x00;
    uint8_t *ip = f + 14, *udp = ip + hl, *dns = udp + 8;
    uint32_t qlen = q->qend - q->dns_off;  /* header and question, as asked */
    memcpy(dns, in + q->dns_off, qlen);
    const uint8_t *qh = in + q->dns_off;
    dns[2] = (uint8_t)(0x80 | (qh[2] & 0x79)); /* QR, the opcode and RD as asked; not authoritative, not truncated */
    dns[3] = (uint8_t)(0x80 | (rcode & 15));   /* RA */
    wr16(dns + 4, 1);
    wr16(dns + 8, 0);
    uint32_t limit = q->udp_max, n = qlen, nans = 0;
    if (limit > cap - 14 - hl - 8) limit = (uint32_t)(cap - 14 - hl - 8); /* never past the buffer above */
    int truncated = 0;
    for (int i = 0; i < q->nans; i++) {
        const Answer *a = &q->ans[i];
        uint32_t need = 2 + 10 + a->rdlen;
        if (n + need + (q->edns ? 11 : 0) > limit) {
            truncated = 1;
            break;
        }
        uint8_t *r = dns + n;
        wr16(r, 0xc00c); /* the question's name */
        wr16(r + 2, a->type);
        wr16(r + 4, a->rclass);
        r[6] = (uint8_t)(a->ttl >> 24), r[7] = (uint8_t)(a->ttl >> 16), r[8] = (uint8_t)(a->ttl >> 8), r[9] = (uint8_t)a->ttl;
        wr16(r + 10, a->rdlen);
        memcpy(r + 12, a->rdata, a->rdlen);
        n += need;
        nans++;
    }
    if (truncated) dns[2] |= 0x02;
    wr16(dns + 6, nans);
    if (q->edns) { /* an OPT record back, as the guest sent one */
        uint8_t *r = dns + n;
        r[0] = 0;
        wr16(r + 1, 41);
        wr16(r + 3, 1232);
        memset(r + 5, 0, 6);
        n += 11;
        wr16(dns + 10, 1);
    } else {
        wr16(dns + 10, 0);
    }
    uint32_t udplen = 8 + n, iplen = hl + udplen;
    const uint8_t *qip = in + q->ip_off, *qudp = in + q->udp_off;
    wr16(udp, 53);
    memcpy(udp + 2, qudp, 2);
    wr16(udp + 4, udplen);
    wr16(udp + 6, 0);
    if (q->v6) {
        ip[0] = 0x60;                  /* version 6, traffic class and flow label 0 */
        wr16(ip + 4, udplen);          /* payload length */
        ip[6] = 17;                    /* next header: UDP */
        ip[7] = 64;                    /* hop limit */
        memcpy(ip + 8, qip + 24, 16);  /* from the name server */
        memcpy(ip + 24, qip + 8, 16);  /* to the guest */
        uint16_t c = (uint16_t)~udp6_sum(ip, udp, udplen);
        wr16(udp + 6, c ? c : 0xffff); /* mandatory over IPv6; a computed 0 is sent as 0xffff (RFC 768) */
    } else {
        ip[0] = 0x45;
        wr16(ip + 2, iplen);
        ip[8] = 64;
        ip[9] = 17;
        memcpy(ip + 12, qip + 16, 4); /* from 10.0.2.3 */
        memcpy(ip + 16, qip + 12, 4); /* to the guest */
        wr16(ip + 10, ip_checksum(ip, 20));
        /* no UDP checksum: allowed over IPv4 */
    }
    q->send(f, 14 + iplen, 1);
    free(f);
}

static void *lookup(void *arg) {
    Query *q = arg;
    if (atomic_load(&stopping)) {
        free(q);
        lookup_finished();
        return NULL;
    }
    DNSServiceRef ref = NULL;
    DNSServiceErrorType err = DNSServiceQueryRecord(&ref, kDNSServiceFlagsReturnIntermediates, 0, q->name, q->qtype,
                                                    q->qclass, on_record, q);
    if (err != kDNSServiceErr_NoError) {
        if (!atomic_load(&stopping)) {
            q->send(q->frame, q->len, 0); /* libslirp, as before */
            atomic_fetch_add(&handed_back, 1);
        }
    } else {
        int fd = DNSServiceRefSockFD(ref);
        int64_t end = now_ms() + TIMEOUT_MS;
        while (!q->done && !atomic_load(&stopping)) {
            int64_t left = end - now_ms();
            if (left <= 0) break;
            struct pollfd p = {fd, POLLIN, 0};
            int r = poll(&p, 1, (int)(left < 100 ? left : 100));
            if (r > 0 && DNSServiceProcessResult(ref) != kDNSServiceErr_NoError) {
                q->failed = 1;
                break;
            }
        }
        DNSServiceRefDeallocate(ref);
        if (!atomic_load(&stopping)) {
            if (!q->done || q->failed) {
                atomic_fetch_add(&timed_out, 1);
                if (atomic_fetch_add(&unanswered_in_a_row, 1) + 1 == GIVE_UP && atomic_exchange(&enabled, 0))
                    fprintf(stderr, "winvm: dns: %d lookups in a row unanswered by the system resolver: libslirp answers from now on\n", GIVE_UP);
            } else {
                atomic_store(&unanswered_in_a_row, 0);
            }
            reply(q, q->done && !q->failed ? 0 : 2); /* SERVFAIL when nothing came */
            atomic_fetch_add(&answered, 1);
        }
    }
    free(q);
    lookup_finished();
    return NULL;
}

int hv_dns_proxy_on(void) {
    return atomic_load(&enabled) != 0;
}

/* An IPv6 query's frame: the IPv6 and UDP headers checked, its IP packet length (header and payload) in *iplen.
   Returns 0 for anything to leave with libslirp. */
static int ipv6_query(const uint8_t *p, uint32_t len, uint32_t *iplen) {
    if (!atomic_load(&ns6_set) || len < 14 + 40 + 8 + 12) return 0;
    if (p[0] & 1) return 0;                       /* to a multicast MAC: not ours to answer from */
    const uint8_t *ip = p + 14;
    if ((ip[0] >> 4) != 6) return 0;
    if (ip[6] != 17) return 0;                    /* UDP right after the header: extension headers are libslirp's */
    if (memcmp(ip + 24, nameserver6, 16)) return 0; /* to the IPv6 name server */
    static const uint8_t unspecified[16];
    if (ip[8] == 0xff || !memcmp(ip + 8, unspecified, 16)) return 0; /* from a multicast or no address */
    uint32_t plen = rd16(ip + 4);                 /* 0 would be a jumbogram, which needs a hop-by-hop header */
    if (plen < 8 + 12 || plen > len - 14 - 40) return 0;
    /* As over IPv4: the whole packet is kept (to hand back as it came), so it must fit Query.frame. */
    if (14 + 40 + plen > sizeof ((Query *)0)->frame) return 0;
    const uint8_t *udp = ip + 40;
    if (rd16(udp + 4) != plen) return 0;          /* the payload is the UDP datagram, nothing before or after it */
    if (!rd16(udp + 6) || udp6_sum(ip, udp, plen) != 0xffff) return 0; /* no or a wrong checksum: libslirp drops it */
    *iplen = 40 + plen;
    return 1;
}

int hv_dns_proxy_take(const uint8_t *p, uint32_t len, HvDnsSend send) {
    if (!hv_dns_proxy_on() || len < 14 + 20 + 8 + 12) return 0;
    const uint8_t *ip = p + 14;
    uint32_t ihl, iplen;
    int v6 = p[12] == 0x86 && p[13] == 0xdd;
    if (v6) {
        if (!ipv6_query(p, len, &iplen)) return 0;
        ihl = 40;
    } else {
        if (p[12] != 0x08 || p[13] != 0x00) return 0;
        ihl = (uint32_t)(ip[0] & 15) * 4;
        if ((ip[0] >> 4) != 4 || ihl < 20 || ip[9] != 17) return 0;
        if (ip[16] != 10 || ip[17] != 0 || ip[18] != 2 || ip[19] != 3) return 0; /* to 10.0.2.3 */
        if ((rd16(ip + 6) & 0x3fff) != 0) return 0;                            /* fragments: libslirp's */
        iplen = rd16(ip + 2);
        if (iplen > len - 14 || iplen < ihl + 8 + 12) return 0;
    }
    /* The whole IP packet is kept (to hand back as it came), so it must fit Query.frame: a total length past the
       UDP datagram's end would otherwise run over the fields after it. Real queries end with their UDP payload. */
    if (14 + iplen > sizeof ((Query *)0)->frame) return 0;
    const uint8_t *udp = ip + ihl;
    if (rd16(udp + 2) != 53) return 0;
    uint32_t udplen = rd16(udp + 4);
    if (udplen < 8 + 12 || udplen > iplen - ihl || udplen - 8 > MAX_QUERY) return 0;
    const uint8_t *dns = udp + 8;
    uint32_t dlen = udplen - 8;
    /* A standard query with one question and nothing else but maybe an OPT record. */
    if ((dns[2] & 0xf8) != 0 || rd16(dns + 4) != 1 || rd16(dns + 6) || rd16(dns + 8) || rd16(dns + 10) > 1) return 0;
    Query *q = calloc(1, sizeof *q);
    if (!q) return 0;
    int local = 0;
    uint32_t off = read_name(dns, dlen, 12, q->name, sizeof q->name, &local);
    if (!off || off + 4 > dlen || local || link_local_reverse(q->name)) {
        free(q);
        return 0;
    }
    q->qtype = rd16(dns + off), q->qclass = rd16(dns + off + 2);
    uint32_t qend = off + 4;
    q->udp_max = 512;
    if (rd16(dns + 10) == 1) { /* EDNS: its OPT record says how big an answer may be */
        if (qend + 11 > dlen || dns[qend] != 0 || rd16(dns + qend + 1) != 41) {
            free(q);
            return 0;
        }
        q->edns = 1;
        uint32_t size = rd16(dns + qend + 3);
        uint32_t most = v6 ? MAX_UDP6 : MAX_UDP4;  /* one unfragmented frame */
        q->udp_max = (uint16_t)(size < 512 ? 512 : size > most ? most : size);
    }
    if (q->qclass != 1 || q->qtype == 0 || q->qtype == 252 || q->qtype == 251) { /* IN only; no zone transfers */
        free(q);
        return 0;
    }
    pthread_mutex_lock(&lifecycle_mu);
    if (atomic_load(&stopping) || atomic_load(&inflight) >= MAX_INFLIGHT) {
        pthread_mutex_unlock(&lifecycle_mu);
        free(q);
        return 0;
    }
    atomic_fetch_add(&inflight, 1);
    pthread_mutex_unlock(&lifecycle_mu);
    memcpy(q->frame, p, 14 + iplen);
    q->len = 14 + iplen;
    q->ip_off = 14, q->udp_off = 14 + ihl, q->dns_off = 14 + ihl + 8, q->qend = q->dns_off + qend;
    q->v6 = v6;
    q->send = send;
    pthread_t t;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&at, 256 * 1024);
    int ok = pthread_create(&t, &at, lookup, q) == 0;
    pthread_attr_destroy(&at);
    if (!ok) {
        free(q);
        lookup_finished();
        return 0;
    }
    return 1;
}

/* libslirp's Router Advertisements name its IPv6 name server (RDNSS, RFC 8106) only when the host's own resolver
   configuration lists an IPv6 server (get_dns6_addr, res_ninit on Apple), and they do not set the O flag, so the
   guest asks no DHCPv6 server either. Where that list has no IPv6 server (IPv4-only networks, or a resolver
   configuration an iOS app cannot read), the guest would never learn of the IPv6 name server this proxy answers
   for. While the proxy is on, each advertisement without an RDNSS option gets one, as libslirp's own would be. */
#define RDNSS_LIFETIME 1200 /* seconds: libslirp's (twice its longest interval between advertisements) */

uint32_t hv_dns_proxy_announce(const uint8_t *p, uint32_t len, uint8_t *out, uint32_t cap) {
    if (!hv_dns_proxy_on() || !atomic_load(&ns6_set)) return 0;
    if (len < 14 + 40 + 16 || p[12] != 0x86 || p[13] != 0xdd) return 0;
    const uint8_t *ip = p + 14, *icmp = ip + 40;
    if ((ip[0] >> 4) != 6 || ip[6] != 58 || icmp[0] != 134 || icmp[1] != 0) return 0; /* ICMPv6 RA */
    uint32_t plen = rd16(ip + 4);
    if (plen < 16 || 14 + 40 + plen != len) return 0;
    for (uint32_t off = 16; off < plen;) { /* the options after the RA's 16 bytes */
        if (off + 2 > plen) return 0;
        uint32_t olen = icmp[off + 1] * 8u;
        if (!olen || off + olen > plen) return 0;
        if (icmp[off] == 25) return 0; /* has an RDNSS already */
        off += olen;
    }
    if (len + 24 > cap || plen + 24 > 0xffff) return 0;
    memcpy(out, p, len);
    uint8_t *oip = out + 14, *oicmp = oip + 40, *o = out + len;
    o[0] = 25, o[1] = 3, o[2] = o[3] = 0; /* RDNSS, 3 x 8 bytes, reserved */
    o[4] = (uint8_t)(RDNSS_LIFETIME >> 24), o[5] = (uint8_t)(RDNSS_LIFETIME >> 16);
    o[6] = (uint8_t)(RDNSS_LIFETIME >> 8), o[7] = (uint8_t)RDNSS_LIFETIME;
    memcpy(o + 8, nameserver6, 16);
    plen += 24;
    wr16(oip + 4, plen);
    wr16(oicmp + 2, 0);
    uint32_t s = sum16(0, oip + 8, 32) + (plen >> 16) + (plen & 0xffff) + 58;
    wr16(oicmp + 2, (uint16_t)~sum16(s, oicmp, plen));
    return len + 24;
}

void hv_dns_proxy_stats(uint64_t *n_answered, uint64_t *n_handed_back, uint64_t *n_timed_out) {
    *n_answered = atomic_load(&answered);
    *n_handed_back = atomic_load(&handed_back);
    *n_timed_out = atomic_load(&timed_out);
}
