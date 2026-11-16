/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Fenced virtio-gpu commands answered in the order they came in, as one in-order GPU engine would.

   Windows' viogpu3d driver has a single node: every DMA buffer gets the next fence id of one sequence,
   and the driver reports "completed up to N" to dxgkrnl with the highest id the device has answered
   (it skips lower ids answered later as "regressing"). dxgkrnl then treats every DMA buffer up to N as
   finished: it signals the sync objects waiting on them, which is how DWM learns that another process
   (the Start menu, say) has finished drawing a surface it is about to compose.

   virglrenderer retires fences per timeline: each context's rings, and the global ctx-0 (vrend) one,
   "in any order" between timelines (virglrenderer.h). Answered as they retire, a quick fence of one
   context (or a ctx-0 fence, which waits only for vrend's GL work) lets the guest's "completed" pass
   work of another context that is still running on the host GPU. DWM then composes a surface before
   its producer has finished it, keeps the stale picture, and redraws only the rectangles that change
   later (where the pointer goes): the Start menu without its background and labels, and the white
   trail along the pointer's path.

   So a retired fence is answered only once every fenced command parked before it has retired too.
   A fence that stays unretired longer than the hold (a context the host lost, a stalled worker) stops
   holding the ones behind it, which are then answered as they retire, as before. */
#ifndef WINVM_GPU_FENCE_ORDER_H
#define WINVM_GPU_FENCE_ORDER_H

#include <stdint.h>

#define HV_FENCE_GLOBAL UINT32_MAX /* ring of a fence on virgl's global (ctx 0) timeline */

typedef struct HvFenceNode {
    struct HvFenceNode *next;
    uint64_t seq;       /* arrival order, from 1 */
    uint64_t parked_ns; /* when it was parked (monotonic) */
    uint64_t fence_id;
    uint32_t ctx_id, ring_idx; /* ring_idx HV_FENCE_GLOBAL: the ctx-0 timeline */
    int retired;
} HvFenceNode;

typedef struct {
    HvFenceNode *head, *tail; /* oldest first */
    uint64_t last_seq;
    uint32_t unretired_global; /* still waiting on the ctx-0 timeline (virgl must be polled for them) */
    uint64_t held;             /* retired while an older one had not: answered later than they retired */
    uint64_t forced;           /* answered ahead of an older one that outstayed the hold */
} HvFenceQueue;

/* Park n (a fenced command); retired 1 if nothing is left to wait for (it is still answered in order). */
void hv_fence_q_push(HvFenceQueue *q, HvFenceNode *n, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id,
                     int retired, uint64_t now_ns);
/* A timeline reached fence_id: ring HV_FENCE_GLOBAL retires the global fences up to it (any context),
   another ring the fences of that context and ring up to it. Returns how many retired now. */
int hv_fence_q_retire(HvFenceQueue *q, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id);
/* The context is gone: its ring fences will never be written, count them retired. */
int hv_fence_q_retire_ctx(HvFenceQueue *q, uint32_t ctx_id);
/* The next one to answer, unlinked, or NULL: the oldest if it has retired; while the oldest has not, a
   retired younger one only once the oldest has waited hold_ns (0: no ordering at all). */
HvFenceNode *hv_fence_q_pop(HvFenceQueue *q, uint64_t now_ns, uint64_t hold_ns);
/* When pop could next give something without another fence retiring (the oldest's hold running out
   with a retired one behind it), or 0 if only a retirement can. */
uint64_t hv_fence_q_deadline(const HvFenceQueue *q, uint64_t hold_ns);
/* 1 when everything parked up to seq has retired (answered or not). */
int hv_fence_q_done_through(const HvFenceQueue *q, uint64_t seq);
/* Unlink everything (a reset); returns the list, oldest first, for the caller to free. */
HvFenceNode *hv_fence_q_take_all(HvFenceQueue *q);

#endif
