/* For test_net_ipv6: libslirp's view of this Mac's name servers without the IPv6 ones, whatever this Mac lists.
   libslirp learns its IPv6 name server from res_ninit and res_getservers (get_dns6_addr); with none, its Router
   Advertisements carry no RDNSS option, and only the DNS proxy's announcement can name one. That is the case the
   announcement exists for (an iPhone on an IPv4-only network, or a configuration the app cannot read), and on a
   Mac whose resolver lists an IPv6 server it would otherwise never be tested.

   dyld applies the interposing below to every other image, libslirp's included, but only from a library loaded at
   launch, not from the main executable: hence this library. Its own call reaches libresolv. */
#include <netinet/in.h>
#include <resolv.h>
#include <stdatomic.h>

static atomic_int calls;

int hv_test_getservers_calls(void) { return atomic_load(&calls); }

static int servers_without_ipv6(res_state st, union res_sockaddr_union *set, int cnt) {
    atomic_fetch_add(&calls, 1);
    int n = res_getservers(st, set, cnt), kept = 0;
    for (int i = 0; i < n; i++)
        if (set[i].sin6.sin6_family != AF_INET6) set[kept++] = set[i];
    return kept;
}

__attribute__((used)) static const struct {
    const void *replacement, *replacee;
} interpose __attribute__((section("__DATA,__interpose"))) = {(const void *)servers_without_ipv6,
                                                               (const void *)res_getservers};
