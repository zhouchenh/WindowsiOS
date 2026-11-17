/* SPDX-License-Identifier: GPL-2.0-or-later */
/* A made-up getifaddrs list for the port forwards' address choice (hv_net_fwd_plan_json): interfaces with
   addresses of either family, up or down, so the choice can be tested without the interfaces existing. Only
   documentation addresses (192.0.2.0/24, 198.51.100.0/24, 2001:db8::/32) and private ones are used. */
#ifndef TESTS_FAKE_IFADDRS_H
#define TESTS_FAKE_IFADDRS_H

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>

#define FAKE_IFS_MAX 24

typedef struct FakeIfs {
    int n;
    struct ifaddrs ifa[FAKE_IFS_MAX];
    struct sockaddr_storage sa[FAKE_IFS_MAX];
    char name[FAKE_IFS_MAX][IFNAMSIZ];
} FakeIfs;

/* One address on an interface (up: IFF_UP; lo0 is also IFF_LOOPBACK). */
static inline void fake_if(FakeIfs *f, const char *name, const char *addr, int up) {
    if (f->n >= FAKE_IFS_MAX) return;
    int k = f->n++;
    memset(&f->ifa[k], 0, sizeof f->ifa[k]);
    memset(&f->sa[k], 0, sizeof f->sa[k]);
    strncpy(f->name[k], name, IFNAMSIZ - 1);
    if (strchr(addr, ':')) {
        struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&f->sa[k];
        s6->sin6_len = sizeof *s6;
        s6->sin6_family = AF_INET6;
        inet_pton(AF_INET6, addr, &s6->sin6_addr);
    } else {
        struct sockaddr_in *s4 = (struct sockaddr_in *)&f->sa[k];
        s4->sin_len = sizeof *s4;
        s4->sin_family = AF_INET;
        inet_pton(AF_INET, addr, &s4->sin_addr);
    }
    f->ifa[k].ifa_name = f->name[k];
    f->ifa[k].ifa_addr = (struct sockaddr *)&f->sa[k];
    f->ifa[k].ifa_flags = (up ? IFF_UP | IFF_RUNNING : 0) | (!strncmp(name, "lo", 2) ? IFF_LOOPBACK : 0);
    for (int i = 0; i < f->n; i++) f->ifa[i].ifa_next = i + 1 < f->n ? &f->ifa[i + 1] : NULL;
}

#endif
