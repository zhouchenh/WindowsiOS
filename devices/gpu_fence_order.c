/* SPDX-License-Identifier: GPL-2.0-or-later */
/* In-order answers for fenced virtio-gpu commands. See gpu_fence_order.h. */
#include "gpu_fence_order.h"

#include <stddef.h>

static void mark(HvFenceQueue *q, HvFenceNode *n) {
    n->retired = 1;
    if (n->ring_idx == HV_FENCE_GLOBAL) q->unretired_global--;
    for (HvFenceNode *p = q->head; p != n; p = p->next)
        if (!p->retired) {
            q->held++; /* an older one is still running: this one waits for it */
            break;
        }
}

void hv_fence_q_push(HvFenceQueue *q, HvFenceNode *n, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id,
                     int retired, uint64_t now_ns) {
    n->next = NULL;
    n->seq = ++q->last_seq;
    n->parked_ns = now_ns;
    n->fence_id = fence_id;
    n->ctx_id = ctx_id;
    n->ring_idx = ring_idx;
    n->retired = 0;
    if (q->tail) q->tail->next = n;
    else q->head = n;
    q->tail = n;
    if (ring_idx == HV_FENCE_GLOBAL) q->unretired_global++;
    if (retired) mark(q, n);
}

int hv_fence_q_retire(HvFenceQueue *q, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id) {
    int n = 0;
    for (HvFenceNode *p = q->head; p; p = p->next) {
        if (p->retired || p->ring_idx != ring_idx || p->fence_id > fence_id) continue;
        if (ring_idx != HV_FENCE_GLOBAL && p->ctx_id != ctx_id) continue;
        mark(q, p);
        n++;
    }
    return n;
}

int hv_fence_q_retire_ctx(HvFenceQueue *q, uint32_t ctx_id) {
    int n = 0;
    for (HvFenceNode *p = q->head; p; p = p->next)
        if (!p->retired && p->ring_idx != HV_FENCE_GLOBAL && p->ctx_id == ctx_id) {
            mark(q, p);
            n++;
        }
    return n;
}

HvFenceNode *hv_fence_q_pop(HvFenceQueue *q, uint64_t now_ns, uint64_t hold_ns) {
    HvFenceNode *h = q->head;
    if (!h) return NULL;
    HvFenceNode **pp = &q->head, *prev = NULL;
    if (!h->retired) {
        if (hold_ns && now_ns - h->parked_ns < hold_ns) return NULL;
        /* the oldest outstayed the hold (or there is no ordering): the first retired one behind it */
        prev = h;
        pp = &h->next;
        while (*pp && !(*pp)->retired) prev = *pp, pp = &(*pp)->next;
        if (!*pp) return NULL;
        if (hold_ns) q->forced++;
    }
    HvFenceNode *n = *pp;
    *pp = n->next;
    if (q->tail == n) q->tail = prev;
    n->next = NULL;
    return n;
}

uint64_t hv_fence_q_deadline(const HvFenceQueue *q, uint64_t hold_ns) {
    const HvFenceNode *h = q->head;
    if (!h || h->retired || !hold_ns) return 0;
    for (const HvFenceNode *p = h->next; p; p = p->next)
        if (p->retired) return h->parked_ns + hold_ns;
    return 0;
}

int hv_fence_q_done_through(const HvFenceQueue *q, uint64_t seq) {
    for (const HvFenceNode *p = q->head; p && p->seq <= seq; p = p->next)
        if (!p->retired) return 0;
    return 1;
}

HvFenceNode *hv_fence_q_take_all(HvFenceQueue *q) {
    HvFenceNode *all = q->head;
    q->head = q->tail = NULL;
    q->unretired_global = 0;
    return all;
}
