#ifndef HENGEVM_DNS_PROXY_H
#define HENGEVM_DNS_PROXY_H

#include <stdint.h>

/* The guest's DNS queries to 10.0.2.3 (and, with IPv6, to the IPv6 name server), answered through the host's
   resolver (dns_proxy.c; from Henge). On unless HV_DNS_PROXY=0, read by hv_dns_proxy_start. send(frame, len,
   to_guest): the answer for the guest (to_guest 1), or the query handed back for libslirp to send on as before (0);
   called from the lookup's own thread. */
typedef void (*HvDnsSend)(const uint8_t *frame, uint32_t len, int to_guest);

/* On for this session: started, HV_DNS_PROXY not 0, and the resolver has not given up (8 unanswered in a row). */
int hv_dns_proxy_on(void);
/* Start a fresh network session, or stop and wait for every lookup callback.
   The caller keeps its send queues alive until stop returns. */
void hv_dns_proxy_start(void);
void hv_dns_proxy_stop(void);
/* The guest's IPv6 name server (libslirp's vnameserver6), or NULL for none (IPv4 only, the default). Queries over
   IPv6 to this address are answered too. Set before the guest can transmit. */
void hv_dns_proxy_set_nameserver6(const uint8_t *addr16);
/* A frame the guest sent: 1 if it was a DNS query this took (its answer comes through send), 0 to pass it on. */
int hv_dns_proxy_take(const uint8_t *frame, uint32_t len, HvDnsSend send);
/* A frame libslirp sends the guest: if it is a Router Advertisement without a DNS server (RDNSS) option, and the
   proxy is on with an IPv6 name server, writes the advertisement with one naming that server to out and returns its
   length. 0: send the frame as it is. */
uint32_t hv_dns_proxy_announce(const uint8_t *frame, uint32_t len, uint8_t *out, uint32_t cap);
void hv_dns_proxy_stats(uint64_t *answered, uint64_t *handed_back, uint64_t *timed_out);

#endif
