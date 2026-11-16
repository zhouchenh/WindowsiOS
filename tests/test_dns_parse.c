/* The DNS proxy's parser and reply builder against malformed and oversized guest frames, with a stand-in resolver
   that answers at once with as much as it can (many answers, the largest records). Built with
   -fsanitize=address,undefined: every guest frame lives in a buffer of exactly its length and is freed as soon as
   hv_dns_proxy_take returns, so a read past it, a use after it, or a reply written past its own buffer aborts.
   Queries come over IPv4 (to 10.0.2.3) and IPv6 (to the IPv6 name server); every IPv6 reply's UDP checksum is
   checked, and IPv6 frames with extension headers, other destinations, or payload lengths that disagree with the
   frame or the UDP datagram must stay with libslirp. */
#include "dns_proxy.h"
#include <dns_sd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_REPLY (14 + 20 + 8 + 1472) /* one unfragmented frame: the most an EDNS query may ask for */
#define MAX_HANDBACK (14 + 60 + 8 + 512)

static atomic_int failures, replies, handbacks, outputs, lookups, active;
static atomic_uint expect_max; /* the most the next reply may be (its query's UDP size), 0: any up to MAX_REPLY */
static pthread_mutex_t name_mu = PTHREAD_MUTEX_INITIALIZER;
static char last_name[1100];

static void check(const char *what, int ok) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        atomic_fetch_add(&failures, 1);
    }
}
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

/* The guest's IPv6 name server (as net_slirp.c configures it) and the guest's address. */
static const uint8_t NS6[16] = {0xfd, 0x2d, 0x70, 0x64, 0x6c, 0x3f, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3};
static const uint8_t GUEST6[16] = {0xfd, 0x2d, 0x70, 0x64, 0x6c, 0x3f, 0, 2, 0x50, 0x54, 0, 0xff, 0xfe, 0x12, 0x34, 0x56};
static uint8_t last_reply[MAX_REPLY]; /* under name_mu */
static uint32_t last_reply_len;

/* RFC 1071 sum of a UDP datagram over IPv6 with its pseudo-header: 0xffff when its checksum is right. */
static uint32_t sum16(uint32_t s, const uint8_t *p, uint32_t n) {
    for (uint32_t i = 0; i + 1 < n; i += 2) s += (uint32_t)(p[i] << 8 | p[i + 1]);
    if (n & 1) s += (uint32_t)p[n - 1] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return s;
}
static uint32_t udp6_sum(const uint8_t *ip, const uint8_t *udp, uint32_t udplen) {
    return sum16(sum16(0, ip + 8, 32) + (udplen >> 16) + (udplen & 0xffff) + 17, udp, udplen);
}
/* Sets the checksum of the UDP datagram after an IPv6 header from its UDP length field. */
static void fix_udp6(uint8_t *ip) {
    uint8_t *udp = ip + 40;
    uint32_t udplen = rd16(udp + 4);
    udp[6] = udp[7] = 0;
    uint16_t c = (uint16_t)~udp6_sum(ip, udp, udplen);
    if (!c) c = 0xffff;
    udp[6] = (uint8_t)(c >> 8), udp[7] = (uint8_t)c;
}

/* The stand-in resolver: ready at once; answers with a burst chosen per lookup. */
typedef struct {
    int pipe[2];
    DNSServiceQueryRecordReply callback;
    void *context;
    uint16_t type;
    int mode;
} Resolver;

DNSServiceErrorType DNSServiceQueryRecord(DNSServiceRef *ref, DNSServiceFlags flags, uint32_t interface,
                                          const char *name, uint16_t type, uint16_t cls,
                                          DNSServiceQueryRecordReply callback, void *context) {
    (void)flags, (void)interface, (void)cls;
    check("name for the resolver is a terminated string that fits", strlen(name) < 1025);
    int k = atomic_fetch_add(&lookups, 1);
    if (k % 7 == 6) return kDNSServiceErr_BadParam; /* cannot even start: the query goes back to libslirp */
    Resolver *r = calloc(1, sizeof *r);
    if (!r || pipe(r->pipe)) exit(1);
    r->callback = callback, r->context = context, r->type = type;
    r->mode = k % 6;
    pthread_mutex_lock(&name_mu);
    snprintf(last_name, sizeof last_name, "%s", name);
    pthread_mutex_unlock(&name_mu);
    *ref = (DNSServiceRef)r;
    atomic_fetch_add(&active, 1);
    (void)!write(r->pipe[1], "x", 1);
    return kDNSServiceErr_NoError;
}
int DNSServiceRefSockFD(DNSServiceRef ref) { return ((Resolver *)ref)->pipe[0]; }
DNSServiceErrorType DNSServiceProcessResult(DNSServiceRef ref) {
    Resolver *r = (Resolver *)ref;
    char byte;
    (void)!read(r->pipe[0], &byte, 1);
    if (r->mode == 4) { /* nothing there */
        r->callback(ref, 0, 0, kDNSServiceErr_NoSuchName, "x.", r->type, 1, 0, NULL, 0, r->context);
        return kDNSServiceErr_NoError;
    }
    /* 1025: more than a record the proxy keeps; 700: two fit in 1472 bytes (an IPv4 frame) but not in 1452 (IPv6) */
    static const uint16_t sizes[] = {4, 1024, 300, 1025, 0, 700};
    uint16_t rdlen = sizes[r->mode];
    uint8_t *rdata = malloc(rdlen); /* exactly rdlen: the proxy must copy no more */
    if (!rdata) exit(1);
    memset(rdata, 0xa5, rdlen);
    uint8_t cname[] = {1, 'c', 0};
    r->callback(ref, kDNSServiceFlagsAdd | kDNSServiceFlagsMoreComing, 0, kDNSServiceErr_NoError, "x.", 5, 1,
                sizeof cname, cname, 60, r->context); /* a CNAME on the way, left out */
    for (int i = 0; i < 70; i++) /* more than MAX_ANSWERS */
        r->callback(ref, kDNSServiceFlagsAdd | (i < 69 ? kDNSServiceFlagsMoreComing : 0), 0, kDNSServiceErr_NoError,
                    "x.", r->type, 1, rdlen, rdata, 60, r->context);
    if (rdlen > 1024) /* nothing kept: end the lookup with an empty answer */
        r->callback(ref, 0, 0, kDNSServiceErr_NoSuchRecord, "x.", r->type, 1, 0, NULL, 0, r->context);
    free(rdata);
    return kDNSServiceErr_NoError;
}
void DNSServiceRefDeallocate(DNSServiceRef ref) {
    Resolver *r = (Resolver *)ref;
    close(r->pipe[0]), close(r->pipe[1]), free(r);
    atomic_fetch_sub(&active, 1);
}

/* Every byte of what comes out is read (ASan checks the bounds), and its lengths must agree with each other. */
static void send_frame(const uint8_t *frame, uint32_t len, int to_guest) {
    unsigned sum = 0;
    for (uint32_t i = 0; i < len; i++) sum += frame[i];
    (void)sum;
    if (!to_guest) {
        check("handed-back query fits the proxy's frame", len >= 54 && len <= MAX_HANDBACK);
        atomic_fetch_add(&handbacks, 1);
        atomic_fetch_add(&outputs, 1);
        return;
    }
    unsigned max = atomic_load(&expect_max);
    int v6 = len >= 14 && frame[12] == 0x86 && frame[13] == 0xdd;
    uint32_t hl = v6 ? 40 : 20;
    check("reply no bigger than one frame", len >= 14 + hl + 8 + 12 && len <= MAX_REPLY);
    check("reply no bigger than the guest asked for", !max || len <= 14 + hl + 8 + max);
    if (len >= 14 + hl + 8 + 12) {
        const uint8_t *ip = frame + 14, *udp = ip + hl, *dns = udp + 8;
        if (v6) {
            check("IPv6 reply version", ip[0] == 0x60);
            check("IPv6 reply payload length", rd16(ip + 4) == len - 54);
            check("IPv6 reply carries UDP", ip[6] == 17);
            check("IPv6 reply from the name server", !memcmp(ip + 8, NS6, 16));
            check("IPv6 reply UDP checksum", rd16(udp + 6) && udp6_sum(ip, udp, len - 54) == 0xffff);
        } else {
            check("reply is IPv4", frame[12] == 8 && frame[13] == 0 && ip[0] == 0x45);
            check("reply IP length", rd16(ip + 2) == len - 14);
        }
        check("reply UDP length", rd16(udp + 4) == len - 14 - hl);
        check("reply from port 53", rd16(udp) == 53);
        check("reply is a response with one question", (dns[2] & 0x80) && rd16(dns + 4) == 1);
        pthread_mutex_lock(&name_mu);
        last_reply_len = len < sizeof last_reply ? len : (uint32_t)sizeof last_reply;
        memcpy(last_reply, frame, last_reply_len);
        pthread_mutex_unlock(&name_mu);
    }
    atomic_fetch_add(&replies, 1);
    atomic_fetch_add(&outputs, 1);
}

static void wait_for(atomic_int *value, int target) {
    for (int i = 0; i < 3000 && atomic_load(value) < target; i++) usleep(1000);
}

/* Takes a copy of the frame in a buffer of exactly len bytes, freed as soon as take returns. */
static int take(const uint8_t *frame, uint32_t len) {
    uint8_t *copy = malloc(len ? len : 1);
    if (!copy) exit(1);
    memcpy(copy, frame, len);
    int taken = hv_dns_proxy_take(copy, len, send_frame);
    memset(copy, 0xee, len);
    free(copy);
    return taken;
}

/* A well-formed A query for `labels` (a.b.c as {1,'a',1,'b',1,'c',0}), with an OPT record asking for `edns` bytes if
   not 0, `pad` bytes after the UDP datagram inside the IP packet and `eth_pad` after the IP packet. */
static uint32_t build(uint8_t *f, const uint8_t *qname, uint32_t qnlen, uint16_t qtype, unsigned edns, uint32_t pad,
                      uint32_t eth_pad, uint8_t fill) {
    memset(f, 0, 14 + 20 + 8);
    f[12] = 8;
    uint8_t *ip = f + 14, *udp = ip + 20, *dns = udp + 8;
    ip[0] = 0x45, ip[8] = 64, ip[9] = 17;
    ip[12] = 10, ip[14] = 2, ip[15] = 15;
    ip[16] = 10, ip[18] = 2, ip[19] = 3;
    udp[0] = 0xc0, udp[1] = 0x01, udp[3] = 53;
    memset(dns, 0, 12);
    dns[0] = 0x12, dns[1] = 0x34, dns[2] = 1, dns[5] = 1;
    uint32_t n = 12;
    memcpy(dns + n, qname, qnlen), n += qnlen;
    dns[n++] = (uint8_t)(qtype >> 8), dns[n++] = (uint8_t)qtype, dns[n++] = 0, dns[n++] = 1;
    if (edns) {
        dns[11] = 1;
        uint8_t opt[] = {0, 0, 41, (uint8_t)(edns >> 8), (uint8_t)edns, 0, 0, 0, 0, 0, 0};
        memcpy(dns + n, opt, sizeof opt), n += sizeof opt;
    }
    uint32_t udplen = 8 + n, iplen = 20 + udplen + pad;
    memset(dns + n, fill, pad + eth_pad);
    ip[2] = (uint8_t)(iplen >> 8), ip[3] = (uint8_t)iplen;
    udp[4] = (uint8_t)(udplen >> 8), udp[5] = (uint8_t)udplen;
    return 14 + iplen + eth_pad;
}

/* The same query over IPv6, from GUEST6 to NS6 with a correct UDP checksum; `pad` bytes after the UDP datagram are
   counted in the payload length (not in the UDP length), `eth_pad` bytes follow the packet. */
static uint32_t build6(uint8_t *f, const uint8_t *qname, uint32_t qnlen, uint16_t qtype, unsigned edns, uint32_t pad,
                       uint32_t eth_pad, uint8_t fill) {
    uint8_t tmp[14 + 20 + 8 + 1400];
    uint32_t len4 = build(tmp, qname, qnlen, qtype, edns, 0, 0, 0);
    uint32_t udplen = len4 - 34;
    static const uint8_t guest_mac[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56}, ns_mac[6] = {0x52, 0x56, 0, 0, 0, 3};
    memcpy(f, ns_mac, 6), memcpy(f + 6, guest_mac, 6);
    f[12] = 0x86, f[13] = 0xdd;
    uint8_t *ip = f + 14, *udp = ip + 40;
    memset(ip, 0, 40);
    ip[0] = 0x60, ip[6] = 17, ip[7] = 64;
    memcpy(ip + 8, GUEST6, 16), memcpy(ip + 24, NS6, 16);
    memcpy(udp, tmp + 34, udplen);
    uint32_t plen = udplen + pad;
    ip[4] = (uint8_t)(plen >> 8), ip[5] = (uint8_t)plen;
    fix_udp6(ip);
    memset(udp + udplen, fill, pad + eth_pad);
    return 14 + 40 + plen + eth_pad;
}

/* One query, waited for: 1 if taken (and its reply, or the query handed back, came), 0 if left to libslirp. */
static int one(const uint8_t *f, uint32_t len, unsigned max) {
    atomic_store(&expect_max, max);
    int target = atomic_load(&outputs) + 1;
    int taken = take(f, len);
    if (taken) {
        wait_for(&outputs, target);
        check("taken query answered", atomic_load(&outputs) >= target);
    }
    hv_dns_proxy_stop();
    hv_dns_proxy_start();
    atomic_store(&expect_max, 0);
    return taken;
}

/* A Router Advertisement as libslirp sends it (source link-layer address and prefix options), with an RDNSS
   option for `rdnss` if not NULL. */
static uint32_t build_ra(uint8_t *f, const uint8_t *rdnss) {
    static const uint8_t dst_mac[6] = {0x33, 0x33, 0, 0, 0, 1}, src_mac[6] = {0x52, 0x56, 0, 0, 0, 2};
    memset(f, 0, 14 + 40 + 16 + 8 + 32 + 24);
    memcpy(f, dst_mac, 6), memcpy(f + 6, src_mac, 6);
    f[12] = 0x86, f[13] = 0xdd;
    uint8_t *ip = f + 14, *icmp = ip + 40;
    ip[0] = 0x60, ip[6] = 58, ip[7] = 255;
    ip[8] = 0xfe, ip[9] = 0x80, ip[23] = 2;                 /* from fe80::2 */
    ip[24] = 0xff, ip[25] = 0x02, ip[39] = 1;               /* to ff02::1 */
    icmp[0] = 134, icmp[4] = 64, icmp[6] = 0x07, icmp[7] = 0x08; /* hop limit 64, router lifetime 1800 s */
    uint32_t n = 16;
    icmp[n] = 1, icmp[n + 1] = 1, memcpy(icmp + n + 2, src_mac, 6), n += 8;
    icmp[n] = 3, icmp[n + 1] = 4, icmp[n + 2] = 64, icmp[n + 3] = 0xc0; /* prefix, /64, on-link + autonomous */
    icmp[n + 7] = 0x80, icmp[n + 11] = 0x40;
    memcpy(icmp + n + 16, NS6, 8), n += 32;
    if (rdnss) {
        icmp[n] = 25, icmp[n + 1] = 3, icmp[n + 7] = 0xb0;
        memcpy(icmp + n + 8, rdnss, 16), n += 24;
    }
    ip[4] = (uint8_t)(n >> 8), ip[5] = (uint8_t)n;
    uint32_t sum = sum16(sum16(0, ip + 8, 32) + n + 58, icmp, n);
    icmp[2] = (uint8_t)(~sum >> 8), icmp[3] = (uint8_t)~sum;
    return 14 + 40 + n;
}

/* Announces f (copied to a buffer of exactly len bytes) into a buffer of exactly cap bytes; checks what comes out. */
static uint32_t announce(const uint8_t *f, uint32_t len, uint32_t cap) {
    uint8_t *in = malloc(len ? len : 1), *out = malloc(cap ? cap : 1);
    if (!in || !out) exit(1);
    memcpy(in, f, len);
    uint32_t n = hv_dns_proxy_announce(in, len, out, cap);
    if (n) {
        check("announced RA within its buffer", n <= cap && n == len + 24);
        const uint8_t *ip = out + 14, *icmp = ip + 40;
        uint32_t plen = rd16(ip + 4);
        check("announced RA payload length", plen == n - 54);
        check("announced RA keeps the rest", !memcmp(out, in, 14 + 4) && !memcmp(out + 20, in + 20, 34 + 2) &&
                                              !memcmp(out + 58, in + 58, len - 58));
        check("announced RA checksum", sum16(sum16(0, ip + 8, 32) + plen + 58, icmp, plen) == 0xffff);
        const uint8_t *o = out + len;
        check("announced RDNSS option", o[0] == 25 && o[1] == 3 && rd16(o + 2) == 0 && !memcmp(o + 8, NS6, 16));
        check("announced RDNSS lifetime", rd16(o + 4) == 0 && rd16(o + 6) == 1200);
    }
    free(in), free(out);
    return n;
}

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint32_t rnd(void) {
    rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
    return (uint32_t)(rng >> 16);
}

int main(void) {
    alarm(60);
    static uint8_t f[70000];
    static const uint8_t ab[] = {1, 'a', 1, 'b', 0};
    unsetenv("HV_DNS_PROXY");
    hv_dns_proxy_set_nameserver6(NS6);
    hv_dns_proxy_start();

    /* A plain query works, and the reply is within 512 bytes. */
    check("plain query taken", one(f, build(f, ab, sizeof ab, 1, 0, 0, 0, 0), 512));
    /* Ethernet padding after the IP packet is fine. */
    check("padded frame taken", one(f, build(f, ab, sizeof ab, 1, 0, 0, 1400, 0xff), 512));

    /* The review's case: IP total length 1500 around a 37-byte UDP query, the rest 0xff. Copying the whole IP
       packet ran over the Query fields after its frame (qtype, udp_max, the name), so the reply grew to 64 records
       of 1 KiB past its 4 KiB buffer. Either it stays with libslirp or its answer is the 512 bytes asked for, for
       the name asked for. */
    for (int mode = 0; mode < 5; mode++) {
        atomic_store(&lookups, mode);
        uint32_t len = build(f, ab, sizeof ab, 1, 0, 1500 - 20 - 8 - 12 - sizeof ab - 4, 0, 0xff);
        if (one(f, len, 512)) {
            pthread_mutex_lock(&name_mu);
            check("long IP packet: resolver asked for the guest's name", !strcmp(last_name, "a.b."));
            pthread_mutex_unlock(&name_mu);
        }
    }
    /* The largest IP total length, and one far past the frame's end. */
    for (uint32_t pad = 0; pad < 2000; pad += 37) one(f, build(f, ab, sizeof ab, 1, 0, pad, 0, 0xff), 512);
    f[16] = 0xff, f[17] = 0xff;
    check("IP length past the frame", !take(f, 1500));

    /* EDNS asking for everything: at most one frame, 64 KiB of answers or not. */
    for (int mode = 0; mode < 6; mode++) {
        atomic_store(&lookups, mode);
        check("EDNS query taken", one(f, build(f, ab, sizeof ab, 1, 65535, 0, 0, 0), 1472));
        atomic_store(&lookups, mode);
        check("ANY query taken", one(f, build(f, ab, sizeof ab, 255, 4096, 0, 0, 0), 1472));
    }

    /* IPv6: a plain query to the IPv6 name server is answered from it, to the guest's address and MAC, with a
       right UDP checksum (send_frame checks the checksum and lengths of every IPv6 reply). */
    for (int mode = 0; mode < 6; mode++) {
        atomic_store(&lookups, mode);
        int r0 = atomic_load(&replies);
        check("IPv6 query taken", one(f, build6(f, ab, sizeof ab, 28, 0, 0, 0, 0), 512));
        if (atomic_load(&replies) > r0) {
            pthread_mutex_lock(&name_mu);
            check("IPv6 reply to the guest's MAC", last_reply_len > 74 && !memcmp(last_reply, f + 6, 6));
            check("IPv6 reply from the name server's MAC", !memcmp(last_reply + 6, f, 6));
            check("IPv6 reply to the guest's address", !memcmp(last_reply + 14 + 24, GUEST6, 16));
            check("IPv6 reply to the guest's port", rd16(last_reply + 54 + 2) == 0xc001);
            check("IPv6 reply keeps the query ID", rd16(last_reply + 62) == 0x1234);
            check("IPv6 reply for the name asked", !strcmp(last_name, "a.b."));
            pthread_mutex_unlock(&name_mu);
        }
    }
    check("IPv6 query with Ethernet padding taken", one(f, build6(f, ab, sizeof ab, 1, 0, 0, 300, 0xff), 512));
    /* EDNS over IPv6: at most one frame, 1452 bytes of DNS (1500 - 40 - 8). */
    for (int mode = 0; mode < 6; mode++) {
        atomic_store(&lookups, mode);
        check("IPv6 EDNS query taken", one(f, build6(f, ab, sizeof ab, 1, 65535, 0, 0, 0), 1452));
        atomic_store(&lookups, mode);
        check("IPv6 ANY query taken", one(f, build6(f, ab, sizeof ab, 255, 4096, 0, 0, 0), 1452));
    }
    {
        atomic_store(&lookups, 0);
        uint32_t len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        uint8_t *ip = f + 14;
        /* Not to the IPv6 name server: the host, another address in the prefix, one bit off, link-local ::3. */
        static const uint8_t tails[] = {2, 4, 0x83};
        for (size_t i = 0; i < sizeof tails; i++) {
            ip[24 + 15] = tails[i], fix_udp6(ip);
            check("IPv6 query to another address left", !take(f, len));
        }
        ip[24 + 15] = 3, ip[24] = 0xfe, ip[25] = 0x80, memset(ip + 26, 0, 6), fix_udp6(ip);
        check("IPv6 query to link-local ::3 left", !take(f, len));
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        check("IPv6 baseline taken", one(f, len, 512));
        /* No IPv6 name server set: nothing over IPv6 is taken. */
        hv_dns_proxy_set_nameserver6(NULL);
        check("IPv6 query without a name server left", !take(f, len));
        hv_dns_proxy_set_nameserver6(NS6);
        /* Extension headers (hop-by-hop, routing, fragment, destination options), ICMPv6, TCP, no next header:
           only UDP right after the fixed header is taken. The datagram is left as it is behind the header. */
        static const uint8_t nhs[] = {0, 43, 44, 60, 58, 6, 59, 51, 50};
        for (size_t i = 0; i < sizeof nhs; i++) {
            len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
            ip[6] = nhs[i];
            check("IPv6 query behind an extension header left", !take(f, len));
        }
        /* A real hop-by-hop header (8 bytes, PadN) in front of the UDP datagram: still left. */
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        memmove(ip + 48, ip + 40, len - 54);
        ip[6] = 0, ip[40] = 17, ip[41] = 0, ip[42] = 1, ip[43] = 4, memset(ip + 44, 0, 4);
        ip[5] = (uint8_t)(ip[5] + 8);
        check("IPv6 hop-by-hop query left", !take(f, len + 8));
        /* Payload length against the frame's length and the UDP length. */
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        uint32_t plen = len - 54;
        for (uint32_t cut = 1; cut < plen; cut++) check("IPv6 frame cut short left", !take(f, len - cut));
        check("IPv6 frame without the payload left", !take(f, 54));
        check("IPv6 frame without the header left", !take(f, 40));
        ip[4] = 0, ip[5] = 0;
        check("IPv6 payload length 0 (jumbogram) left", !take(f, len));
        ip[4] = 0xff, ip[5] = 0xff;
        check("IPv6 payload length past the frame left", !take(f, len));
        ip[4] = (uint8_t)((plen + 1) >> 8), ip[5] = (uint8_t)(plen + 1);
        check("IPv6 payload length one past the frame left", !take(f, len));
        ip[4] = (uint8_t)((plen - 1) >> 8), ip[5] = (uint8_t)(plen - 1);
        check("IPv6 payload length shorter than the UDP datagram left", !take(f, len));
        /* Payload longer than the UDP datagram (bytes after it inside the packet): with the checksum over the
           datagram, and with one that is right over the whole payload instead. */
        for (uint32_t pad = 1; pad < 2000; pad += 97) {
            len = build6(f, ab, sizeof ab, 28, 0, pad, 0, 0xff);
            check("IPv6 payload past the UDP datagram left", !take(f, len));
            uint32_t whole = len - 54;
            f[54 + 6] = f[54 + 7] = 0;
            uint16_t c = (uint16_t)~udp6_sum(ip, ip + 40, whole);
            f[54 + 6] = (uint8_t)(c >> 8), f[54 + 7] = (uint8_t)c;
            check("IPv6 payload past the UDP datagram, summed whole, left", !take(f, len));
        }
        /* The UDP length past the payload, with the checksum computed over it as the guest says. */
        len = build6(f, ab, sizeof ab, 28, 0, 64, 0, 0);
        uint8_t *udp = ip + 40;
        uint32_t udplen = rd16(udp + 4) + 64;
        udp[4] = (uint8_t)(udplen >> 8), udp[5] = (uint8_t)udplen, fix_udp6(ip);
        ip[4] = (uint8_t)((udplen - 64) >> 8), ip[5] = (uint8_t)(udplen - 64);
        check("IPv6 UDP length past the payload left", !take(f, len));
        /* The largest queries: a datagram over MAX_QUERY, and one over Query.frame, each in a frame that holds it. */
        for (uint32_t extra = 0; extra < 700; extra += 50) {
            uint8_t name[1300];
            uint32_t n = 0;
            while (n + 64 < 470 + extra) {
                name[n++] = 63;
                memset(name + n, 'y', 63), n += 63;
            }
            name[n++] = 0;
            len = build6(f, name, n, 1, 0, 0, 0, 0);
            int taken = take(f, len);
            if (len - 62 > 512) check("IPv6 query over 512 bytes left", !taken);
            if (taken) {
                hv_dns_proxy_stop();
                hv_dns_proxy_start();
            }
        }
        /* Checksum: none (0, not allowed over IPv6), one bit off, or one's-complement -0 for +0. */
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        udp[6] = udp[7] = 0;
        check("IPv6 query without a UDP checksum left", !take(f, len));
        fix_udp6(ip), udp[7] ^= 1;
        check("IPv6 query with a wrong checksum left", !take(f, len));
        fix_udp6(ip), f[len - 1] ^= 0x40;
        check("IPv6 query with a damaged payload left", !take(f, len));
        /* From a multicast or the unspecified address, or sent to a multicast MAC: left. */
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        ip[8] = 0xff, fix_udp6(ip);
        check("IPv6 query from a multicast address left", !take(f, len));
        memset(ip + 8, 0, 16), fix_udp6(ip);
        check("IPv6 query from :: left", !take(f, len));
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        f[0] = 0x33, f[1] = 0x33;
        check("IPv6 query to a multicast MAC left", !take(f, len));
        /* An IPv6 header in an IPv4 frame and the other way round. */
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        f[12] = 0x08, f[13] = 0;
        check("IPv6 packet as IPv4 left", !take(f, len));
        len = build(f, ab, sizeof ab, 1, 0, 0, 0, 0);
        f[12] = 0x86, f[13] = 0xdd;
        check("IPv4 packet as IPv6 left", !take(f, len));
        len = build6(f, ab, sizeof ab, 28, 0, 0, 0, 0);
        ip[0] = 0x40;
        check("IPv6 frame with version 4 left", !take(f, len));
    }

    /* Router Advertisements: one without an RDNSS option gets one naming the IPv6 name server; one with an RDNSS
       already, or anything else, stays as it is. */
    {
        uint32_t len = build_ra(f, NULL);
        check("RA without RDNSS announced", announce(f, len, len + 24) == len + 24);
        check("RA announced into a larger buffer", announce(f, len, 2000) == len + 24);
        check("RA not announced into a buffer too small", !announce(f, len, len + 23));
        check("RA cut short not announced", !announce(f, len - 1, len + 24));
        check("RA with Ethernet padding not announced", !announce(f, len + 1, len + 25));
        uint8_t other[16];
        memcpy(other, NS6, 16), other[15] = 9;
        len = build_ra(f, other);
        check("RA with an RDNSS left", !announce(f, len, len + 24));
        len = build_ra(f, NULL);
        f[14 + 40] = 133;
        check("Router Solicitation left", !announce(f, len, len + 24));
        len = build_ra(f, NULL);
        f[14 + 6] = 17;
        check("UDP left", !announce(f, len, len + 24));
        len = build_ra(f, NULL);
        f[14 + 40 + 16 + 1] = 0;
        check("RA with a zero-length option left", !announce(f, len, len + 24));
        len = build_ra(f, NULL);
        f[14 + 40 + 16 + 8 + 1] = 5;
        check("RA with an option past its end left", !announce(f, len, len + 24));
        len = build_ra(f, NULL);
        f[12] = 0x08, f[13] = 0;
        check("RA as IPv4 left", !announce(f, len, len + 24));
        hv_dns_proxy_set_nameserver6(NULL);
        len = build_ra(f, NULL);
        check("RA without an IPv6 name server left", !announce(f, len, len + 24));
        hv_dns_proxy_set_nameserver6(NS6);
        /* HV_DNS_PROXY=0: no announcement, and IPv6 queries stay with libslirp too. */
        setenv("HV_DNS_PROXY", "0", 1);
        hv_dns_proxy_stop();
        hv_dns_proxy_start();
        check("RA left with the proxy off", !announce(f, len, len + 24));
        check("IPv6 query left with the proxy off", !take(f, build6(f, ab, sizeof ab, 28, 0, 0, 0, 0)));
        unsetenv("HV_DNS_PROXY");
        hv_dns_proxy_stop();
        hv_dns_proxy_start();
        /* Damaged advertisements, in buffers of exactly their size. */
        int announced = 0;
        for (int it = 0; it < 20000; it++) {
            len = build_ra(f, rnd() % 4 ? NULL : NS6);
            int damage = (int)(rnd() % 4);
            for (int d = 0; d < damage; d++) {
                uint32_t at = rnd() % 4 ? 14 + 40 + rnd() % (len - 54) : rnd() % len;
                f[at] ^= (uint8_t)(1u << (rnd() % 8));
            }
            if (rnd() % 8 == 0) f[18] = (uint8_t)rnd(), f[19] = (uint8_t)rnd();
            if (rnd() % 6 == 0) len = rnd() % (len + 1);
            else if (rnd() % 10 == 0) len += rnd() % 64;
            announced += announce(f, len, rnd() % 2 ? len + 24 : rnd() % (len + 48)) != 0;
        }
        check("damaged RAs announced too", announced > 1000);
    }

    /* Names at their limits: 63-byte labels up to the 512-byte message, all printable or all escaped (\DDD,
       four bytes each, so the 1025-byte name runs out). */
    for (int kind = 0; kind < 3; kind++) {
        uint8_t name[600];
        uint32_t n = 0;
        while (n + 64 < 512 - 12 - 4 - 1) {
            name[n++] = 63;
            for (int i = 0; i < 63; i++) name[n++] = kind == 0 ? 'x' : kind == 1 ? 0 : (i & 1 ? '.' : '\\');
        }
        name[n++] = 0;
        one(f, build(f, name, n, 1, 0, 0, 0, 0), 512);
        name[n - 1] = 7; /* no end */
        check("unterminated name", !take(f, build(f, name, n, 1, 0, 0, 0, 0)));
    }

    /* Fuzz: well-formed queries with random names, types, EDNS sizes and padding, then random damage to any byte,
       to the IP and UDP lengths and to the frame's length. */
    int taken = 0, taken6 = 0;
    for (int it = 0; it < 30000; it++) {
        int v6 = rnd() % 3 == 0;
        uint8_t name[300];
        uint32_t n = 0, labels = rnd() % 6;
        for (uint32_t l = 0; l < labels; l++) {
            uint32_t ll = rnd() % 8 ? 1 + rnd() % 12 : rnd() % 64;
            if (n + 1 + ll + 1 > sizeof name) break;
            name[n++] = (uint8_t)ll;
            for (uint32_t i = 0; i < ll; i++) name[n++] = (uint8_t)(rnd() % 4 ? 'a' + rnd() % 26 : rnd());
        }
        name[n++] = 0;
        static const uint16_t types[] = {1, 28, 255, 5, 16, 33, 65, 12, 0, 252, 251, 0xffff};
        uint16_t qtype = rnd() % 4 ? types[rnd() % 12] : (uint16_t)rnd();
        unsigned edns = rnd() % 3 ? 0 : rnd() % 3 ? 512 + rnd() % 4096 : (uint16_t)rnd();
        uint32_t pad = rnd() % 4 ? 0 : rnd() % 4 ? rnd() % 64 : rnd() % 3000;
        uint32_t eth_pad = rnd() % 4 ? 0 : rnd() % 128;
        uint8_t fill = (uint8_t)rnd();
        if (v6 && rnd() % 2) pad = 0; /* mostly well-formed: a payload with bytes after the datagram is never taken */
        uint32_t len = v6 ? build6(f, name, n, qtype, edns, pad, eth_pad, fill)
                          : build(f, name, n, qtype, edns, pad, eth_pad, fill);
        uint32_t hdr = v6 ? 14 + 40 + 8 : 14 + 20 + 8; /* where the DNS message starts */
        if (!v6 && rnd() % 3 == 0) f[14] = (uint8_t)(0x40 | (5 + rnd() % 11)); /* IP options: the header grows */
        int damage = rnd() % 3 ? (int)(rnd() % 4) : 0;
        for (int d = 0; d < damage; d++) {
            uint32_t at = rnd() % 8 ? hdr + rnd() % (len > hdr ? len - hdr : 1) : rnd() % len;
            if (at < len) f[at] ^= (uint8_t)(1u << (rnd() % 8));
        }
        if (v6) {
            if (rnd() % 8 == 0) f[18] = (uint8_t)rnd(), f[19] = (uint8_t)rnd(); /* payload length */
            if (rnd() % 8 == 0) f[58] = (uint8_t)rnd(), f[59] = (uint8_t)rnd(); /* UDP length */
            if (rnd() % 16 == 0) f[20] = (uint8_t)rnd();                        /* next header */
            if (rnd() % 8 == 0) f[65] = (uint8_t)rnd();                         /* header flags */
            /* Most damage would only break the checksum: half the time it is made right again over what the UDP
               length says, so the parser behind the checksum sees the damage too. */
            if (rnd() % 2) fix_udp6(f + 14);
        } else {
            if (rnd() % 8 == 0) f[16] = (uint8_t)rnd(), f[17] = (uint8_t)rnd(); /* IP total length */
            if (rnd() % 8 == 0) f[38] = (uint8_t)rnd(), f[39] = (uint8_t)rnd(); /* UDP length */
            if (rnd() % 8 == 0) f[45] = (uint8_t)rnd();                         /* header flags */
        }
        if (rnd() % 10 == 0) len = rnd() % (len + 1);                         /* cut short */
        else if (rnd() % 20 == 0) len += rnd() % 3000;                        /* or longer than it says */
        int t = take(f, len);
        taken += t;
        if (v6) taken6 += t;
        if (it % 48 == 47) {
            hv_dns_proxy_stop();
            check("every lookup released", atomic_load(&active) == 0);
            hv_dns_proxy_start();
        }
    }
    hv_dns_proxy_stop();
    check("every lookup released", atomic_load(&active) == 0);
    check("fuzz reached the resolver", taken > 1000);
    check("IPv6 fuzz reached the resolver", taken6 > 300);
    check("some lookups handed back", atomic_load(&handbacks) > 0);
    check("resolver never gave up", hv_dns_proxy_on());
    printf("DNS parse: %d taken in the fuzz (%d over IPv6), %d replies, %d handed back, %d failures\n", taken, taken6,
           atomic_load(&replies), atomic_load(&handbacks), atomic_load(&failures));
    return atomic_load(&failures) != 0;
}
