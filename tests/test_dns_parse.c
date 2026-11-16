/* The DNS proxy's parser and reply builder against malformed and oversized guest frames, with a stand-in resolver
   that answers at once with as much as it can (many answers, the largest records). Built with
   -fsanitize=address,undefined: every guest frame lives in a buffer of exactly its length and is freed as soon as
   hv_dns_proxy_take returns, so a read past it, a use after it, or a reply written past its own buffer aborts. */
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
    r->mode = k % 5;
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
    static const uint16_t sizes[] = {4, 1024, 300, 1025}; /* 1025: more than a record the proxy keeps */
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
    check("reply no bigger than one frame", len >= 54 && len <= MAX_REPLY);
    check("reply no bigger than the guest asked for", !max || len <= 14 + 20 + 8 + max);
    if (len >= 54) {
        const uint8_t *ip = frame + 14, *udp = ip + 20, *dns = udp + 8;
        check("reply IP length", rd16(ip + 2) == len - 14);
        check("reply UDP length", rd16(udp + 4) == len - 34);
        check("reply from port 53", rd16(udp) == 53);
        check("reply is a response with one question", (dns[2] & 0x80) && rd16(dns + 4) == 1);
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
    for (int mode = 0; mode < 5; mode++) {
        atomic_store(&lookups, mode);
        check("EDNS query taken", one(f, build(f, ab, sizeof ab, 1, 65535, 0, 0, 0), 1472));
        atomic_store(&lookups, mode);
        check("ANY query taken", one(f, build(f, ab, sizeof ab, 255, 4096, 0, 0, 0), 1472));
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
    int taken = 0;
    for (int it = 0; it < 30000; it++) {
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
        uint32_t len = build(f, name, n, qtype, edns, pad, eth_pad, (uint8_t)rnd());
        if (rnd() % 3 == 0) f[14] = (uint8_t)(0x40 | (5 + rnd() % 11)); /* IP options: the header grows */
        int damage = rnd() % 3 ? (int)(rnd() % 4) : 0;
        for (int d = 0; d < damage; d++) {
            uint32_t at = rnd() % 8 ? 14 + 20 + 8 + rnd() % (len > 42 ? len - 42 : 1) : rnd() % len;
            if (at < len) f[at] ^= (uint8_t)(1u << (rnd() % 8));
        }
        if (rnd() % 8 == 0) f[16] = (uint8_t)rnd(), f[17] = (uint8_t)rnd();   /* IP total length */
        if (rnd() % 8 == 0) f[38] = (uint8_t)rnd(), f[39] = (uint8_t)rnd();   /* UDP length */
        if (rnd() % 8 == 0) f[45] = (uint8_t)rnd();                           /* header flags */
        if (rnd() % 10 == 0) len = rnd() % (len + 1);                         /* cut short */
        else if (rnd() % 20 == 0) len += rnd() % 3000;                        /* or longer than it says */
        taken += take(f, len);
        if (it % 48 == 47) {
            hv_dns_proxy_stop();
            check("every lookup released", atomic_load(&active) == 0);
            hv_dns_proxy_start();
        }
    }
    hv_dns_proxy_stop();
    check("every lookup released", atomic_load(&active) == 0);
    check("fuzz reached the resolver", taken > 1000);
    check("some lookups handed back", atomic_load(&handbacks) > 0);
    check("resolver never gave up", hv_dns_proxy_on());
    printf("DNS parse: %d taken in the fuzz, %d replies, %d handed back, %d failures\n", taken,
           atomic_load(&replies), atomic_load(&handbacks), atomic_load(&failures));
    return atomic_load(&failures) != 0;
}
