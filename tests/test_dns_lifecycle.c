/* The DNS proxy's session lifecycle and its fall-back to libslirp, against a stand-in resolver.
   Ported from Henge 6aefa03 (tests/test_dns_lifecycle.c); the switch is HV_DNS_PROXY, read at each start,
   instead of Henge's engine knob. */
#include "dns_proxy.h"
#include <dns_sd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* A controllable host resolver: exercise cancellation and callback ordering
   without depending on DNS servers or their response times. */
typedef struct {
    int pipe[2];
    DNSServiceQueryRecordReply callback;
    void *context;
} Resolver;
static atomic_int immediate, active, started, sent, block_send, release_send, stopped;
static atomic_int fail_lookup;
static int failures;

DNSServiceErrorType DNSServiceQueryRecord(DNSServiceRef *ref, DNSServiceFlags flags,
        uint32_t interface, const char *name, uint16_t type, uint16_t cls,
        DNSServiceQueryRecordReply callback, void *context) {
    (void)flags; (void)interface; (void)name; (void)type; (void)cls;
    Resolver *r = calloc(1, sizeof *r);
    if (!r || pipe(r->pipe)) exit(1);
    r->callback = callback;
    r->context = context;
    *ref = (DNSServiceRef)r;
    atomic_fetch_add(&active, 1);
    if (atomic_load(&immediate)) (void)!write(r->pipe[1], "x", 1);
    atomic_fetch_add(&started, 1);
    return kDNSServiceErr_NoError;
}
int DNSServiceRefSockFD(DNSServiceRef ref) { return ((Resolver *)ref)->pipe[0]; }
DNSServiceErrorType DNSServiceProcessResult(DNSServiceRef ref) {
    Resolver *r = (Resolver *)ref;
    char byte;
    (void)!read(r->pipe[0], &byte, 1);
    if (atomic_load(&fail_lookup)) return kDNSServiceErr_Unknown;
    uint8_t address[] = {127, 0, 0, 1};
    r->callback(ref, kDNSServiceFlagsAdd, 0, kDNSServiceErr_NoError,
                "shutdown.test.", 1, 1, sizeof address, address, 60, r->context);
    return kDNSServiceErr_NoError;
}
void DNSServiceRefDeallocate(DNSServiceRef ref) {
    Resolver *r = (Resolver *)ref;
    close(r->pipe[0]); close(r->pipe[1]); free(r);
    atomic_fetch_sub(&active, 1);
}
static void send_frame(const uint8_t *frame, uint32_t len, int to_guest) {
    if (!to_guest || len < 54 || !(frame[44] & 0x80)) exit(1);
    atomic_fetch_add(&sent, 1);
    while (atomic_load(&block_send) && !atomic_load(&release_send)) usleep(1000);
}
static void check(const char *what, int ok) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); failures++; }
}
static void wait_for(atomic_int *value, int target) {
    for (int i = 0; i < 2000 && atomic_load(value) < target; i++) usleep(1000);
    if (atomic_load(value) < target) { fprintf(stderr, "Timed out waiting for resolver\n"); exit(1); }
}
static void query_reply(const uint8_t *packet, uint32_t len) {
    int target = atomic_load(&sent) + 1;
    int accepted = hv_dns_proxy_take(packet, len, send_frame);
    check("resolver accepts query", accepted);
    if (accepted) wait_for(&sent, target);
}
static void *stop(void *unused) {
    (void)unused;
    hv_dns_proxy_stop();
    atomic_store(&stopped, 1);
    return NULL;
}
/* A copy of the query frame `base` asking for `dotted` (A, IN) instead; returns its length. */
static uint32_t query_for(uint8_t *out, const uint8_t *base, const char *dotted) {
    memcpy(out, base, 14 + 20 + 8 + 12);
    uint8_t *dns = out + 14 + 20 + 8;
    uint32_t n = 12;
    while (*dotted) {
        const char *dot = strchr(dotted, '.');
        size_t l = dot ? (size_t)(dot - dotted) : strlen(dotted);
        dns[n++] = (uint8_t)l;
        memcpy(dns + n, dotted, l);
        n += (uint32_t)l;
        dotted += l + (dot ? 1 : 0);
    }
    dns[n++] = 0;
    dns[n++] = 0, dns[n++] = 1, dns[n++] = 0, dns[n++] = 1;
    uint32_t iplen = 20 + 8 + n;
    out[14 + 2] = (uint8_t)(iplen >> 8), out[14 + 3] = (uint8_t)iplen;
    out[14 + 20 + 4] = (uint8_t)((8 + n) >> 8), out[14 + 20 + 5] = (uint8_t)(8 + n);
    return 14 + iplen;
}

int main(void) {
    alarm(10);
    uint8_t packet[96] = {0};
    uint8_t *ip = packet + 14, *udp = ip + 20, *dns = udp + 8;
    const uint8_t question[] = {8,'s','h','u','t','d','o','w','n',4,'t','e','s','t',0,0,1,0,1};
    unsigned dnslen = 12 + sizeof question, iplen = 20 + 8 + dnslen;
    packet[12] = 8;
    ip[0] = 0x45; ip[3] = iplen; ip[9] = 17;
    ip[12] = 10; ip[14] = 2; ip[15] = 15;
    ip[16] = 10; ip[18] = 2; ip[19] = 3;
    udp[0] = 0x80; udp[3] = 53; udp[5] = 8 + dnslen;
    dns[0] = 1; dns[2] = 1; dns[5] = 1;
    memcpy(dns + 12, question, sizeof question);

    check("not started: queries pass through", !hv_dns_proxy_take(packet, 14 + iplen, send_frame));
    setenv("HV_DNS_PROXY", "0", 1);
    hv_dns_proxy_start();
    check("HV_DNS_PROXY=0 passes queries through", !hv_dns_proxy_on() && !hv_dns_proxy_take(packet, 14 + iplen, send_frame));
    hv_dns_proxy_stop();
    unsetenv("HV_DNS_PROXY");
    hv_dns_proxy_start();
    check("on by default", hv_dns_proxy_on());
    {
        /* Names mDNSResponder would ask about by multicast stay with libslirp (no local network prompt). */
        static const char *const libslirps[] = {"printer.local", "LOCAL", "4.3.254.169.in-addr.arpa",
                                                "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa",
                                                "b.e.f.ip6.arpa"};
        static const char *const ours[] = {"example.com", "local.example.com", "3.2.0.10.in-addr.arpa",
                                           "1254.169.in-addr.arpa"};
        uint8_t other[600];
        for (size_t i = 0; i < sizeof libslirps / sizeof libslirps[0]; i++)
            check(libslirps[i], !hv_dns_proxy_take(other, query_for(other, packet, libslirps[i]), send_frame));
        for (size_t i = 0; i < sizeof ours / sizeof ours[0]; i++) /* taken; never answered, cancelled below */
            check(ours[i], hv_dns_proxy_take(other, query_for(other, packet, ours[i]), send_frame));
        hv_dns_proxy_stop();
        atomic_store(&started, 0);
        hv_dns_proxy_start();
    }
    check("pending query accepted", hv_dns_proxy_take(packet, 14 + iplen, send_frame));
    wait_for(&started, 1);
    hv_dns_proxy_stop();
    check("pending resolver released", atomic_load(&active) == 0);
    check("cancelled reply not delivered", atomic_load(&sent) == 0);
    check("stopped session rejects queries", !hv_dns_proxy_take(packet, 14 + iplen, send_frame));
    uint64_t answered, handed_back, timed_out;
    hv_dns_proxy_stats(&answered, &handed_back, &timed_out);
    check("shutdown cancellation is not a resolver failure", timed_out == 0 && hv_dns_proxy_on());

    hv_dns_proxy_start();
    atomic_store(&immediate, 1);
    atomic_store(&block_send, 1);
    check("new session accepts query", hv_dns_proxy_take(packet, 14 + iplen, send_frame));
    wait_for(&sent, 1);
    pthread_t thread;
    if (pthread_create(&thread, NULL, stop, NULL)) return 1;
    usleep(20000);
    check("stop waits for callback to finish", !atomic_load(&stopped));
    atomic_store(&release_send, 1);
    pthread_join(thread, NULL);
    check("callback drained", atomic_load(&stopped) && atomic_load(&active) == 0);

    hv_dns_proxy_start();
    atomic_store(&block_send, 0);
    check("DNS works after restart", hv_dns_proxy_take(packet, 14 + iplen, send_frame));
    wait_for(&sent, 2);
    hv_dns_proxy_stop();
    check("new resolver released", atomic_load(&active) == 0);

    hv_dns_proxy_start();
    atomic_store(&fail_lookup, 1);
    for (int i = 0; i < 7; i++) query_reply(packet, 14 + iplen);
    check("resolver stays on before fallback threshold", hv_dns_proxy_on());
    hv_dns_proxy_stop();

    hv_dns_proxy_start();
    query_reply(packet, 14 + iplen);
    check("new session clears the previous failure streak", hv_dns_proxy_on());
    atomic_store(&fail_lookup, 0);
    query_reply(packet, 14 + iplen);
    atomic_store(&fail_lookup, 1);
    for (int i = 0; i < 7; i++) query_reply(packet, 14 + iplen);
    check("successful lookup clears the failure streak", hv_dns_proxy_on());
    query_reply(packet, 14 + iplen);
    check("resolver falls back after consecutive failures", !hv_dns_proxy_on());
    check("fallback passes queries to libslirp", !hv_dns_proxy_take(packet, 14 + iplen, send_frame));
    hv_dns_proxy_stop();

    /* A new network session reads HV_DNS_PROXY again. */
    hv_dns_proxy_start();
    query_reply(packet, 14 + iplen);
    check("restart after fallback gets a fresh failure streak", hv_dns_proxy_on());
    hv_dns_proxy_stop();
    check("fallback session releases every resolver", atomic_load(&active) == 0);
    printf("DNS lifecycle: %d failures\n", failures);
    return failures != 0;
}
