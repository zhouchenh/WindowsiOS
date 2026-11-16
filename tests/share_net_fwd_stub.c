// SPDX-License-Identifier: GPL-2.0-or-later
/* Stand-ins for the port-forward engine (host/net_slirp.c) that host/share.c's /.henge/forwards calls,
   so tests that build share.c on its own (test_share_clip, test_share_focus) need neither libslirp nor
   the network thread. The forwards endpoint is tested with the real engine in tests/test_net_fwd.c. */
#include "net_slirp.h"

#include <stdlib.h>
#include <string.h>

int hv_net_fwd_put(HvFwdRule *r, int session, char *err, size_t errlen) {
    (void)r;
    (void)session;
    if (err && errlen) {
        strncpy(err, "no network in this test", errlen - 1);
        err[errlen - 1] = 0;
    }
    return -1;
}

int hv_net_fwd_remove(const char *id, int session_only) {
    (void)id;
    (void)session_only;
    return -1;
}

int hv_net_fwd_sync(int timeout_ms) {
    (void)timeout_ms;
    return 0;
}

char *hv_net_fwd_list_json(void) { return strdup("{\"running\":false,\"rules\":[]}"); }

int hv_net_fwd_parse_rule(const char *json, size_t len, HvFwdRule *r) {
    (void)json;
    (void)len;
    (void)r;
    return -1;
}
