/* Fenced virtio-gpu commands answered in order (devices/gpu_fence_order.h).

   The guest (Windows' viogpu3d) numbers every DMA buffer from one sequence and reports the highest fence
   the device answered as "everything up to here is done". virglrenderer retires the fences of different
   contexts, and of its global ctx-0 timeline, in any order. The regression: the Start menu's drawing
   (one context) was still running when DWM's fence (another context) or a ctx-0 fence retired; answering
   that one first told Windows the Start menu was finished, DWM composed it half drawn and kept the stale
   picture. Built with -fsanitize=address,undefined. */
#include "gpu_fence_order.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void check(const char *what, int ok) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    }
}

#define MS 1000000ull

typedef struct {
    HvFenceNode node;
    int tag;
} Cmd;

static Cmd *park(HvFenceQueue *q, uint32_t ctx, uint32_t ring, uint64_t fence, int retired, uint64_t now) {
    Cmd *c = calloc(1, sizeof *c);
    c->tag = (int)fence;
    hv_fence_q_push(q, &c->node, ctx, ring, fence, retired, now);
    return c;
}

/* Pops everything ready now; the fence ids in answer order go to out (-1 terminated). */
static int drain(HvFenceQueue *q, uint64_t now, uint64_t hold, int *out) {
    int n = 0;
    HvFenceNode *f;
    while ((f = hv_fence_q_pop(q, now, hold))) {
        out[n++] = ((Cmd *)f)->tag;
        free(f);
    }
    out[n] = -1;
    return n;
}

static void free_all(HvFenceQueue *q) {
    for (HvFenceNode *n = hv_fence_q_take_all(q); n;) {
        HvFenceNode *next = n->next;
        free(n);
        n = next;
    }
}

/* The screenshots' case: Start (ctx 2) fence 100, DWM (ctx 3) 101, a ctx-0 flush 102. */
static void test_start_menu_case(void) {
    HvFenceQueue q;
    memset(&q, 0, sizeof q);
    int out[16];
    park(&q, 2, 0, 100, 0, 0);
    park(&q, 3, 0, 101, 0, 0);
    park(&q, 0, HV_FENCE_GLOBAL, 102, 0, 0);
    check("one global fence waits on ctx 0", q.unretired_global == 1);
    /* vrend's timeline and DWM's context finish first */
    check("global retire", hv_fence_q_retire(&q, 0, HV_FENCE_GLOBAL, 102) == 1);
    check("global fence counted retired", q.unretired_global == 0);
    check("dwm retire", hv_fence_q_retire(&q, 3, 0, 101) == 1);
    check("nothing answered while Start's fence runs", drain(&q, 1 * MS, 500 * MS, out) == 0);
    check("both retired behind it are held", q.held == 2);
    check("not done through 101", !hv_fence_q_done_through(&q, 2));
    check("the hold's deadline is set", hv_fence_q_deadline(&q, 500 * MS) == 500 * MS);
    /* the Start menu's drawing finishes: all three, oldest first */
    check("start retire", hv_fence_q_retire(&q, 2, 0, 100) == 1);
    check("done through everything", hv_fence_q_done_through(&q, 3));
    check("three answered", drain(&q, 2 * MS, 500 * MS, out) == 3);
    check("in order", out[0] == 100 && out[1] == 101 && out[2] == 102);
    check("nothing forced", q.forced == 0);
    check("queue empty", !q.head && !q.tail);

    /* with no ordering (hold 0, the old behaviour) the later ones would have gone first */
    park(&q, 2, 0, 200, 0, 0);
    park(&q, 3, 0, 201, 0, 0);
    hv_fence_q_retire(&q, 3, 0, 201);
    check("hold 0 answers as retired", drain(&q, 0, 0, out) == 1 && out[0] == 201);
    check("hold 0 counts nothing forced", q.forced == 0);
    hv_fence_q_retire(&q, 2, 0, 200);
    check("then the other", drain(&q, 0, 0, out) == 1 && out[0] == 200);
    free_all(&q);
}

/* Timelines: a ring fence needs its own context and ring; ids up to the written one retire (merged). */
static void test_matching(void) {
    HvFenceQueue q;
    memset(&q, 0, sizeof q);
    int out[16];
    park(&q, 2, 0, 10, 0, 0);
    park(&q, 2, 1, 11, 0, 0);
    park(&q, 4, 0, 12, 0, 0);
    park(&q, 2, 0, 13, 0, 0);
    park(&q, 4, HV_FENCE_GLOBAL, 14, 0, 0);
    check("global does not retire ring fences", hv_fence_q_retire(&q, 0, HV_FENCE_GLOBAL, 100) == 1);
    check("other ctx same ring", hv_fence_q_retire(&q, 3, 0, 100) == 0);
    check("ctx 2 ring 0 up to 13 (merged)", hv_fence_q_retire(&q, 2, 0, 13) == 2);
    check("already retired ones are not counted twice", hv_fence_q_retire(&q, 2, 0, 13) == 0);
    check("10 answered, 11 still runs", drain(&q, 0, 500 * MS, out) == 1 && out[0] == 10);
    check("ctx 2 ring 1 below its id", hv_fence_q_retire(&q, 2, 1, 10) == 0);
    check("ctx 2 ring 1", hv_fence_q_retire(&q, 2, 1, 11) == 1);
    check("11 answered, 12 still runs", drain(&q, 0, 500 * MS, out) == 1 && out[0] == 11);
    check("ctx 4 destroyed: its ring fence goes", hv_fence_q_retire_ctx(&q, 4) == 1);
    check("the rest in order", drain(&q, 0, 500 * MS, out) == 3 && out[0] == 12 && out[1] == 13 && out[2] == 14);
    free_all(&q);
}

/* Nothing to wait for (a failed command, a dead context): answered at once only if it is the oldest. */
static void test_retired_at_park(void) {
    HvFenceQueue q;
    memset(&q, 0, sizeof q);
    int out[16];
    park(&q, 2, 0, 1, 1, 0);
    check("alone: answered", drain(&q, 0, 500 * MS, out) == 1 && out[0] == 1);
    park(&q, 2, 0, 2, 0, 0);
    park(&q, 0, HV_FENCE_GLOBAL, 3, 1, 0);
    check("pre-retired global does not wait on ctx 0", q.unretired_global == 0);
    check("behind a running one: held", drain(&q, 0, 500 * MS, out) == 0);
    hv_fence_q_retire(&q, 2, 0, 2);
    check("then both", drain(&q, 0, 500 * MS, out) == 2 && out[0] == 2 && out[1] == 3);
    free_all(&q);
}

/* A fence that never retires holds the others only for the hold, then they go as they retire. */
static void test_hold_runs_out(void) {
    HvFenceQueue q;
    memset(&q, 0, sizeof q);
    int out[16];
    park(&q, 2, 0, 1, 0, 0);
    park(&q, 3, 0, 2, 0, 10 * MS);
    park(&q, 3, 0, 3, 0, 20 * MS);
    check("no deadline with nothing retired behind", hv_fence_q_deadline(&q, 500 * MS) == 0);
    hv_fence_q_retire(&q, 3, 0, 2);
    check("deadline from the oldest", hv_fence_q_deadline(&q, 500 * MS) == 500 * MS);
    check("held before the hold runs out", drain(&q, 499 * MS, 500 * MS, out) == 0);
    check("let through after it", drain(&q, 500 * MS, 500 * MS, out) == 1 && out[0] == 2);
    check("counted forced", q.forced == 1);
    check("the stuck one stays at the head", q.head && ((Cmd *)q.head)->tag == 1);
    check("tail still right", q.tail && ((Cmd *)q.tail)->tag == 3);
    hv_fence_q_retire(&q, 3, 0, 3);
    check("the last one too, and the tail follows", drain(&q, 600 * MS, 500 * MS, out) == 1 && out[0] == 3);
    check("tail is the stuck one", q.tail == q.head && q.head && ((Cmd *)q.head)->tag == 1);
    park(&q, 3, 0, 4, 0, 700 * MS); /* appended after a forced pop took the old tail */
    check("appended behind it", q.head->next && ((Cmd *)q.head->next)->tag == 4);
    hv_fence_q_retire(&q, 2, 0, 1);
    check("the stuck one goes", drain(&q, 700 * MS, 500 * MS, out) == 1 && out[0] == 1);
    hv_fence_q_retire(&q, 3, 0, 4);
    check("and the new one", drain(&q, 700 * MS, 500 * MS, out) == 1 && out[0] == 4);
    check("empty", !q.head && !q.tail);
    free_all(&q);
}

/* Many contexts retiring in random order: whenever the guest's "highest answered" fence reaches N, every
   fence up to N has retired (the in-order engine Windows assumes), and every fence is answered once. */
static void test_random_model(void) {
    enum { N = 4000, CTXS = 5 };
    static int retired[N + 1], answered[N + 1];
    static uint32_t ctx_of[N + 1];
    static uint64_t last_written[CTXS + 1];
    HvFenceQueue q;
    memset(&q, 0, sizeof q);
    srand(12345);
    uint64_t next = 1, completed = 0;
    int out[N + 1];
    unsigned answers = 0;
    while (answers < N) {
        int r = rand() % 3;
        if (r == 0 && next <= N) {
            uint32_t ctx = (uint32_t)(rand() % (CTXS + 1)); /* 0: a ctx-0 (global) fence */
            ctx_of[next] = ctx;
            park(&q, ctx, ctx ? 0 : HV_FENCE_GLOBAL, next, 0, 0);
            next++;
        } else {
            /* a timeline writes its newest fence (earlier ones merged into it) */
            uint32_t ctx = (uint32_t)(rand() % (CTXS + 1));
            uint64_t newest = 0;
            for (uint64_t f = last_written[ctx] + 1; f < next; f++)
                if (ctx_of[f] == ctx) newest = f;
            if (newest) {
                hv_fence_q_retire(&q, ctx, ctx ? 0 : HV_FENCE_GLOBAL, newest);
                for (uint64_t f = 1; f <= newest; f++)
                    if (ctx_of[f] == ctx) retired[f] = 1;
                last_written[ctx] = newest;
            }
        }
        int n = drain(&q, 0, 1000 * MS, out);
        for (int i = 0; i < n; i++) {
            int f = out[i];
            check("answered once", !answered[f]);
            check("only after it retired", retired[f]);
            answered[f] = 1;
            answers++;
            if ((uint64_t)f > completed) completed = (uint64_t)f;
        }
        for (uint64_t f = 1; f <= completed; f++)
            if (!retired[f]) {
                check("completed never passes running work", 0);
                break;
            }
        if (failures) break;
    }
    check("nothing forced", q.forced == 0);
    check("drained", !q.head && q.unretired_global == 0);
    free_all(&q);
}

int main(void) {
    test_start_menu_case();
    test_matching();
    test_retired_at_park();
    test_hold_runs_out();
    test_random_model();
    if (failures) {
        fprintf(stderr, "test_gpu_fence_order: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_gpu_fence_order: ok\n");
    return 0;
}
