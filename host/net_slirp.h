#ifndef HENGEVM_NET_SLIRP_H
#define HENGEVM_NET_SLIRP_H

#include <stddef.h>

#include "machine.h"
#include "virtio_net.h"

/* Before hv_net_attach: the Unix socket behind the guest's 10.0.2.4:80 (share.c). */
void hv_net_set_share_socket(const char *path);
/* User-mode NAT for the guest's virtio-net (see net_slirp.c). Returns 0 on success. */
int hv_net_attach(HvMachine *m, HvVirtioNet *n);
/* CPU thread, from the board's tick: hand frames for the guest to the device. */
void hv_net_poll(void);
/* Any thread: forward [::1]/127.0.0.1:host_port -> 10.0.2.15:guest_port over TCP for this session (expose-port,
   OAuth callbacks). It shows up in hv_net_fwd_list_json as a session forward; it is never saved. */
void hv_net_add_hostfwd(int host_port, int guest_port);

extern uint64_t hv_net_tx_frames, hv_net_rx_frames;

/* ---- port forwards (net_slirp.c, "Port forwards"; docs/networking.md) ----
   A forward takes connections on the device and hands them to the guest's 10.0.2.15. All of these may be called
   from any thread, before or after hv_net_attach; the network thread applies the changes. */

#define HV_FWD_TCP 1
#define HV_FWD_UDP 2
#define HV_FWD_BOTH (HV_FWD_TCP | HV_FWD_UDP)

/* Who can connect: */
#define HV_FWD_LOOPBACK 0 /* apps on this device only: 127.0.0.1 and [::1] */
#define HV_FWD_LAN 1      /* the local network: the Wi-Fi, wired and Personal Hotspot addresses, IPv4 and IPv6 (unique
                             local, and global unless the rule's no_global6 or HV_NET_LAN_GLOBAL6=0; never link-local,
                             never cellular), followed as they change, and loopback */
#define HV_FWD_VPN 2      /* every address of the active VPN interface (utun...): IPv4, and IPv6 unique local and
                             global (not link-local), followed when they change */

typedef struct HvFwdRule {
    char id[48];   /* letters, digits, '-', '_', '.'; empty: one is made up */
    char name[64]; /* for people */
    int proto;     /* HV_FWD_TCP, HV_FWD_UDP or both */
    int host_port; /* 1..65535, on the device */
    int guest_port;
    int scope; /* HV_FWD_LOOPBACK, HV_FWD_LAN or HV_FWD_VPN */
    int enabled;
    int no_global6; /* HV_FWD_LAN: leave the local network's global IPv6 addresses out (JSON "ipv6Global": false).
                       A global address may be reachable from the internet where the router lets IPv6 in. */
} HvFwdRule;

/* The file the machine's forwards are kept in (JSON, see net_slirp.c). Loads it, replacing the saved forwards
   (session ones stay); a missing file is no forwards. The same path again does nothing. Returns 0, or -1 when the
   file could not be read (it is renamed to <path>.bad and the list starts empty). HV_NET_FWD_FILE names it on the
   Mac. */
int hv_net_fwd_set_store(const char *path);
/* Adds the forward, or replaces the one with the same id. session: HV_FWD_SAVED (kept in the store),
   HV_FWD_SESSION (until the app quits), or HV_FWD_GUEST (as SESSION, asked for by the guest: this device's
   loopback only, ports from 1024, and it cannot replace a saved one). Returns 0, or -1 with why in err (bad values,
   or another enabled forward already has this port and protocol). On success *r holds what was stored (its id). */
#define HV_FWD_SAVED 0
#define HV_FWD_SESSION 1
#define HV_FWD_GUEST 2
int hv_net_fwd_put(HvFwdRule *r, int session, char *err, size_t errlen);
/* Removes a forward by id (only a session one if session_only). Returns 0, or -1 if there is none. */
int hv_net_fwd_remove(const char *id, int session_only);
/* Interfaces changed: the VPN's address is looked up again and forwards that failed are tried again. */
void hv_net_fwd_refresh(void);
/* Closes and opens every forward again (iOS may take a suspended app's listening sockets away: call this when the
   app comes back to the foreground). */
void hv_net_fwd_reopen(void);
/* Waits up to timeout_ms until the network thread has applied every change made so far. 0 when done (or when the
   network is not running), -1 on timeout. */
int hv_net_fwd_sync(int timeout_ms);
/* The forwards with their state, as JSON (malloc'd):
   {"running":bool,"rules":[{"id","name","protocol":"tcp"|"udp"|"tcp+udp","hostPort","guestPort",
     "scope":"loopback"|"lan"|"vpn","ipv6Global":bool,"enabled","session",
     "state":"off"|"waiting"|"listening"|"error","code","message","warning",
     "listen":["127.0.0.1:3389","[fd00::1]:3389",...],
     "ipv4":{"state":"listening"|"error"|"none"|"off","message"},"ipv6":{...}}]}
   ipv4 / ipv6: each family on its own. "none": the scope has no address of that family now (the message says
   why); "error": none of its listeners opened; "listening" with a message: some of its addresses failed. */
char *hv_net_fwd_list_json(void);
/* The device's addresses others can connect to, as JSON (malloc'd):
   {"lan":[{"interface","address","family":4|6,"global":bool}],"vpn":[...]} (global: a global IPv6 address) */
char *hv_net_fwd_addresses_json(void);
/* Where a forward would listen with these interfaces (a getifaddrs list), for tests and diagnostics, as JSON
   (malloc'd): {"ok":bool,"code","listen":["a.b.c.d:port","[v6]:port",...],"relay":"a.b.c.d","note4","note6"}.
   listen leaves out the IPv4 loopback an IPv6-only VPN keeps as the relays' way in. */
struct ifaddrs;
char *hv_net_fwd_plan_json(const struct ifaddrs *ifa, const HvFwdRule *r);
/* One forward from JSON (the keys hv_net_fwd_list_json uses; missing ones keep *r's values). 0, or -1. */
int hv_net_fwd_parse_rule(const char *json, size_t len, HvFwdRule *r);

#endif
