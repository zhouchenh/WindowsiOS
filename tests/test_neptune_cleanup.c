/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Standalone deterministic lifetime/queue tests. No Metal, guest or renderer.
 * cc -std=c11 -Wall -Wextra -Werror -pthread tests/test_neptune_cleanup.c -o /tmp/test-neptune-cleanup
 */
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static _Atomic uint64_t fake_time;
static _Atomic int fail_alloc, fail_thread;
static void *test_calloc(size_t n, size_t s) {
    if (atomic_exchange(&fail_alloc, 0)) return NULL;
    return calloc(n, s);
}
static int test_pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*f)(void *), void *p) {
    if (atomic_exchange(&fail_thread, 0)) return 11;
    return pthread_create(t, a, f, p);
}
static uint64_t test_now_ns(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec + atomic_load(&fake_time);
}
#define NPT_NOW_NS() test_now_ns()
#define calloc test_calloc
#define pthread_create test_pthread_create
#include "../devices/neptune_cleanup.c"
#undef calloc
#undef pthread_create

static void pause_ms(void) { struct timespec t = {.tv_nsec = 1000000}; nanosleep(&t, NULL); }
static void await_value(_Atomic unsigned *p, unsigned value) {
    for (unsigned i = 0; i < 3000; i++) { if (atomic_load(p) >= value) return; pause_ms(); }
    assert(!"worker did not reach expected state");
}
static void await_idle(void) {
    for (unsigned i = 0; i < 3000; i++) {
        enter(); int idle = !waiting && !current && !device_waiting && !device_current; leave();
        if (idle) return;
        pause_ms();
    }
    assert(!"worker did not become idle");
}
static void advance(uint64_t ns) { atomic_fetch_add(&fake_time, ns); hv_npt_cleanup_poll(); }

typedef struct FakeDevice FakeDevice;
struct FakeDevice {
    void **vtable;
    uint32_t pub, priv;
    _Atomic uint64_t main_goal, main_done, init_goal, init_done;
    _Atomic unsigned destroyed, event_entered, block_event, fail_event, fail_snapshot;
    _Atomic unsigned destroy_entered, block_destroy, fail_destroy, transient_refs;
    _Atomic unsigned barrier_entered, barrier_polls, barrier_released, barrier_status;
    _Atomic unsigned barrier_nil, block_barrier, block_barrier_poll, barrier_poll_entered, pause_on_barrier_success;
    FakeDevice *hidden;
};
_Static_assert(offsetof(FakeDevice, pub) == 8, "fake public counter");
_Static_assert(offsetof(FakeDevice, priv) == 12, "fake private counter");

static int32_t fake_qi(void *p, const void *iid, void **out) {
    FakeDevice *d = p;
    if (iid) {
        /* Alias path reenters hooked AddRef. */
        hv_npt_device_addref(d);
    } else {
        /* Container QI's original inline public/private increment. */
        if (!__atomic_fetch_add(&d->pub, 1, __ATOMIC_SEQ_CST))
            __atomic_fetch_add(&d->priv, 1, __ATOMIC_SEQ_CST);
    }
    *out = d;
    return 0;
}
static int fake_snapshot(void *p, struct HvNptDeviceSnapshot *out) {
    FakeDevice *d = p;
    assert(count_load(&d->pub) == 0);
    if (atomic_load(&d->fail_snapshot)) return 0;
    out->main_goal = atomic_load(&d->main_goal);
    out->main_done = atomic_load(&d->main_done);
    out->initializer_goal = atomic_load(&d->init_goal);
    out->event = d; out->initializer_queue = d;
    return 1;
}
static int fake_event(void *p, uint64_t *out) {
    FakeDevice *d = p;
    atomic_fetch_add(&d->event_entered, 1);
    while (atomic_load(&d->block_event)) pause_ms();
    if (atomic_load(&d->fail_event)) return 0;
    *out = atomic_load(&d->init_done);
    return 1;
}
static int fake_destroy(void *p) {
    FakeDevice *d = p;
    assert(count_load(&d->pub) == 0);
    assert(count_load(&d->priv) == NPT_PRIVATE_SENTINEL);
    atomic_fetch_add(&d->destroy_entered, 1);
    while (atomic_load(&d->block_destroy)) pause_ms();
    if (atomic_load(&d->fail_destroy)) return 0;
    if (atomic_load(&d->transient_refs)) {
        void *alias = NULL;
        assert(hv_npt_device_addref(d) == 1);
        assert(count_load(&d->priv) == NPT_PRIVATE_SENTINEL + 1);
        assert(hv_npt_device_release(d) == 0);
        assert(count_load(&d->priv) == NPT_PRIVATE_SENTINEL);
        assert(!hv_npt_device_query_interface(d, NULL, &alias) && alias == d);
        assert(count_load(&d->priv) == NPT_PRIVATE_SENTINEL + 1);
        assert(hv_npt_device_release(d) == 0);
        assert(count_load(&d->priv) == NPT_PRIVATE_SENTINEL);
        assert(!hv_npt_device_query_interface(d, d, &alias));
        assert(hv_npt_device_release(d) == 0);
        assert(count_load(&d->priv) == NPT_PRIVATE_SENTINEL);
    }
    if (d->hidden) hv_npt_device_release(d->hidden);
    atomic_fetch_add(&d->destroyed, 1);
    return 1;
}
static void *fake_barrier_begin(void *p) {
    FakeDevice *d = p;
    assert(hv_npt_cleanup_gpu_allowed());
    atomic_fetch_add(&d->barrier_entered, 1);
    while (atomic_load(&d->block_barrier)) pause_ms();
    if (!hv_npt_cleanup_gpu_allowed() || atomic_load(&d->barrier_nil)) return NULL;
    return d;
}
static int fake_barrier_status(void *p) {
    FakeDevice *d = p;
    assert(hv_npt_cleanup_gpu_allowed());
    atomic_fetch_add(&d->barrier_poll_entered, 1);
    while (atomic_load(&d->block_barrier_poll)) pause_ms();
    atomic_fetch_add(&d->barrier_polls, 1);
    unsigned status = atomic_load(&d->barrier_status);
    if (status == 1 && atomic_exchange(&d->pause_on_barrier_success, 0)) hv_npt_cleanup_set_active(0);
    return status == 1 ? 1 : status == 2 ? -1 : 0;
}
static void fake_barrier_release(void *p) {
    atomic_fetch_add(&((FakeDevice *)p)->barrier_released, 1);
}
static const struct HvNptDeviceOps ops = {
    .query_interface=fake_qi, .snapshot=fake_snapshot, .event_value=fake_event,
    .barrier_begin=fake_barrier_begin, .barrier_status=fake_barrier_status,
    .barrier_release=fake_barrier_release, .destroy=fake_destroy
};
static void setup(void) { assert(hv_npt_cleanup_set_device_ops(&ops)); hv_npt_cleanup_set_backend_verified(1); }
static FakeDevice *device(void) {
    FakeDevice *d = calloc(1, sizeof(*d)); assert(d);
    d->pub = d->priv = 1;
    return d;
}

typedef struct FakeObject {
    void **vtable;
    _Atomic unsigned refs, releases, entered, block;
    FakeDevice *hidden;
} FakeObject;
static uint32_t fake_release(void *p) {
    FakeObject *o = p;
    unsigned left = atomic_fetch_sub(&o->refs, 1) - 1;
    atomic_fetch_add(&o->entered, 1);
    while (atomic_load(&o->block)) pause_ms();
    if (!left && o->hidden) hv_npt_device_release(o->hidden);
    atomic_fetch_add(&o->releases, 1);
    return left;
}
static FakeObject *object(unsigned refs, FakeDevice *hidden) {
    static void *vtable[3];
    union { Release f; void *p; } cast = {.f = fake_release};
    vtable[2] = cast.p;
    FakeObject *o = calloc(1, sizeof(*o)); assert(o);
    o->vtable = vtable; atomic_store(&o->refs, refs); o->hidden = hidden;
    return o;
}
static NptRecord *record(void *o, unsigned refs) {
    NptRecord *r = calloc(1, sizeof(*r)); assert(r);
    r->object = o; r->regs = refs; return r;
}
static void submit(FakeObject *o, unsigned refs) { hv_npt_capture_object(record(o, refs)); hv_npt_cleanup_submit(); }

static void healthy_hidden_graph(void) {
    setup();
    FakeDevice *a = device(), *b = device();
    a->hidden = b; /* B survives ONLY through A's private COM graph. */
    FakeObject *factory = object(4, a);
    hv_npt_capture_object(record(factory, 2));
    hv_npt_capture_object(record(factory, 1));
    hv_npt_capture_object(record(NULL, 0));
    for (int i = 0; i < 10; i++) pause_ms();
    assert(!atomic_load(&factory->releases)); /* final context marker required */
    hv_npt_cleanup_submit();
    await_value(&factory->releases, 3); await_idle();
    assert(atomic_load(&factory->refs) == 1 && !atomic_load(&a->destroyed));
    submit(factory, 1);
    await_value(&a->destroyed, 1); await_value(&b->destroyed, 1); await_idle();
    enter(); assert(released_refs == 4 && retired_devices == 2 && !quarantined_pins); leave();
}
static void delayed_main_and_initializer(void) {
    setup(); FakeDevice *d = device();
    atomic_store(&d->main_goal, 4); atomic_store(&d->main_done, 2);
    atomic_store(&d->init_goal, 7); atomic_store(&d->init_done, 6);
    assert(hv_npt_device_release(d) == 0);
    for (int i = 0; i < 10; i++) pause_ms();
    assert(!atomic_load(&d->event_entered) && !atomic_load(&d->destroyed));
    atomic_store(&d->main_done, 4); hv_npt_cleanup_poll();
    await_value(&d->event_entered, 1); assert(!atomic_load(&d->destroyed));
    atomic_store(&d->init_done, 7); hv_npt_cleanup_poll();
    await_value(&d->destroyed, 1); await_idle();
}
static void long_counter_wait_remains_retryable(void) {
    setup(); FakeDevice *d = device();
    atomic_store(&d->main_goal, 10); atomic_store(&d->main_done, 9);
    atomic_store(&d->init_goal, 1);
    hv_npt_device_release(d);
    for (int i = 0; i < 20; i++) pause_ms();
    advance(UINT64_C(6000000000)); /* lifecycle gate intentionally unwired */
    assert(!atomic_load(&d->destroyed));
    enter(); assert(!quarantined_pins); leave();
    atomic_store(&d->main_done, 10); hv_npt_cleanup_poll();
    await_value(&d->event_entered, 1);
    /* Advance between getters: no single entered call is being stalled. */
    int advanced = 0;
    for (unsigned i = 0; i < 3000 && !advanced; i++) {
        enter();
        if (!device_current) { atomic_fetch_add(&fake_time, UINT64_C(6000000000)); advanced = 1; }
        leave();
        if (!advanced) pause_ms();
    }
    assert(advanced); hv_npt_cleanup_poll();
    for (int i = 0; i < 20; i++) pause_ms();
    enter(); assert(!quarantined_pins); leave();
    assert(count_load(&d->priv) == 1 && !atomic_load(&d->destroyed));
    atomic_store(&d->init_done, 1); hv_npt_cleanup_poll();
    await_value(&d->destroyed, 1); await_idle();
}
static void getter_error_retains(void) {
    setup(); FakeDevice *d = device();
    atomic_store(&d->init_goal, 1); atomic_store(&d->fail_event, 1);
    hv_npt_device_release(d); await_idle();
    assert(!atomic_load(&d->destroyed)); enter(); assert(quarantined_pins == 1); leave();
}
static void invalid_snapshot_retains(void) {
    setup(); FakeDevice *d = device(); atomic_store(&d->fail_snapshot, 1);
    hv_npt_device_release(d); await_idle();
    assert(!atomic_load(&d->destroyed) && count_load(&d->priv) == 1);
    enter(); assert(quarantined_pins == 1); leave();
}
static void resurrection_during_getter(void) {
    setup(); FakeDevice *d = device();
    atomic_store(&d->init_goal, 1); atomic_store(&d->init_done, 1); atomic_store(&d->block_event, 1);
    hv_npt_device_release(d); await_value(&d->event_entered, 1);
    void *alias = NULL;
    assert(hv_npt_device_query_interface(d, NULL, &alias) == 0 && alias == d);
    assert(hv_npt_device_query_interface(d, d, &alias) == 0); /* recursive AddRef */
    assert(count_load(&d->pub) == 2 && count_load(&d->priv) == 2);
    atomic_store(&d->main_goal, 9); atomic_store(&d->main_done, 8);
    assert(hv_npt_device_release(d) == 1);
    assert(hv_npt_device_release(d) == 0); /* new epoch owns the later work */
    atomic_store(&d->block_event, 0); hv_npt_cleanup_poll();
    for (int i = 0; i < 20; i++) pause_ms();
    assert(!atomic_load(&d->destroyed) && count_load(&d->priv) == 1);
    atomic_store(&d->main_done, 9); hv_npt_cleanup_poll();
    await_value(&d->destroyed, 1); await_idle();
}
static void many_zero_epochs(void) {
    setup(); hv_npt_cleanup_set_active(0); FakeDevice *d = device();
    for (unsigned i = 0; i < 5; i++) { assert(hv_npt_device_release(d) == 0); if (i < 4) assert(hv_npt_device_addref(d) == 1); }
    assert(count_load(&d->pub) == 0 && count_load(&d->priv) == 5);
    hv_npt_cleanup_set_active(1); await_value(&d->destroyed, 1); await_idle();
    assert(atomic_load(&d->destroyed) == 1);
}
static void blocked_getter_background(void) {
    setup(); FakeDevice *d = device();
    atomic_store(&d->init_goal, 1); atomic_store(&d->init_done, 1); atomic_store(&d->block_event, 1);
    hv_npt_device_release(d); await_value(&d->event_entered, 1);
    hv_npt_cleanup_set_active(0); advance(NPT_TIMEOUT_NS * 100);
    enter(); assert(device_current && !device_current->expired); leave();
    hv_npt_cleanup_set_active(1); advance(NPT_TIMEOUT_NS);
    char text[512]; hv_npt_cleanup_describe(text, sizeof(text));
    assert(strstr(text, "initializer event value") && strstr(text, "stalled_call=1"));
    atomic_store(&d->block_event, 0); hv_npt_cleanup_poll(); await_idle();
    assert(atomic_load(&d->destroyed) == 1);
    enter(); assert(!quarantined_pins && slow_calls == 1); leave();
}
static void paused_queue_does_not_age(void) {
    setup(); hv_npt_cleanup_set_active(0); FakeDevice *d = device();
    hv_npt_device_release(d); advance(NPT_TIMEOUT_NS * 100);
    assert(!atomic_load(&d->destroyed));
    hv_npt_cleanup_set_active(1); await_value(&d->destroyed, 1); await_idle();
}
static void blocked_release_no_followup(void) {
    setup(); FakeObject *next = object(1, NULL), *blocked = object(1, NULL);
    atomic_store(&blocked->block, 1);
    hv_npt_capture_object(record(next, 1)); hv_npt_capture_object(record(blocked, 1)); hv_npt_cleanup_submit();
    await_value(&blocked->entered, 1); advance(NPT_TIMEOUT_NS);
    atomic_store(&blocked->block, 0); hv_npt_cleanup_poll(); await_idle();
    assert(atomic_load(&blocked->releases) == 1 && !atomic_load(&next->releases));
    enter(); assert(quarantined_refs == 1); leave();
}
static void blocked_batch_does_not_block_device(void) {
    setup(); FakeObject *blocked = object(1, NULL);
    atomic_store(&blocked->block, 1); submit(blocked, 1);
    await_value(&blocked->entered, 1);
    advance(NPT_TIMEOUT_NS);
    FakeDevice *d = device(); hv_npt_device_release(d);
    await_value(&d->destroyed, 1);
    assert(!atomic_load(&blocked->releases));
    enter(); assert(current && current->expired && !quarantined_pins); leave();
    atomic_store(&blocked->block, 0); await_idle();
}
static void destructor_transient_references_do_not_enqueue(void) {
    setup(); FakeDevice *d = device(); atomic_store(&d->transient_refs, 1);
    hv_npt_device_release(d); await_value(&d->destroyed, 1); await_idle();
    enter(); assert(next_id == 1 && !quarantined_pins && retired_devices == 1); leave();
    assert(count_load(&d->pub) == 0 && count_load(&d->priv) == NPT_PRIVATE_SENTINEL);
}
static void destructor_outside_mutex(void) {
    setup(); FakeDevice *a = device(), *b = device();
    atomic_store(&a->block_destroy, 1);
    hv_npt_device_release(a); await_value(&a->destroy_entered, 1);
    /* This would deadlock if reaper held the lifetime mutex across destructor. */
    assert(hv_npt_device_addref(b) == 2); assert(hv_npt_device_release(b) == 1);
    hv_npt_cleanup_set_active(0); advance(NPT_TIMEOUT_NS * 10);
    hv_npt_cleanup_set_active(1); advance(NPT_TIMEOUT_NS);
    enter(); assert(device_current->destroying && !device_current->pin); leave();
    atomic_store(&a->block_destroy, 0); await_value(&a->destroyed, 1); await_idle();
    enter(); assert(!quarantined_pins); leave();
    hv_npt_device_release(b); await_value(&b->destroyed, 1); await_idle();
}
static void failed_finalizer_retains_sealed_device(void) {
    setup(); FakeDevice *d = device(); atomic_store(&d->fail_destroy, 1);
    hv_npt_device_release(d); await_idle();
    assert(!atomic_load(&d->destroyed));
    assert(count_load(&d->priv) == NPT_PRIVATE_SENTINEL);
    enter(); assert(failed_finalizers == 1 && !retired_devices && !quarantined_pins); leave();
    char text[512]; hv_npt_cleanup_describe(text, sizeof(text));
    assert(strstr(text, "failed_finalizers=1"));
}
static void queue_limits(void) {
    setup(); hv_npt_cleanup_set_active(0);
    FakeObject *o[NPT_BATCH_LIMIT + 1];
    for (unsigned i = 0; i <= NPT_BATCH_LIMIT; i++) { o[i] = object(1, NULL); submit(o[i], 1); }
    FakeDevice *d[81];
    for (unsigned i = 0; i < 81; i++) { d[i] = device(); hv_npt_device_release(d[i]); }
    enter(); assert(waiting_batches == NPT_BATCH_LIMIT && waiting_devices == 81);
    assert(quarantined_batches == 1 && quarantined_pins == 0); leave();
    hv_npt_cleanup_set_active(1); await_idle();
    assert(!atomic_load(&o[0]->releases) && atomic_load(&d[0]->destroyed));
    assert(atomic_load(&o[NPT_BATCH_LIMIT]->releases) && atomic_load(&d[80]->destroyed));
}
static void retry_does_not_evict_devices(void) {
    setup(); FakeDevice *pending = device();
    atomic_store(&pending->init_goal, 1); atomic_store(&pending->block_event, 1);
    hv_npt_device_release(pending); await_value(&pending->event_entered, 1);
    hv_npt_cleanup_set_active(0);
    FakeDevice *first = NULL;
    for (unsigned i = 0; i < 80; i++) {
        FakeDevice *d = device(); if (!i) first = d; hv_npt_device_release(d);
    }
    atomic_store(&pending->block_event, 0);
    for (unsigned i = 0; i < 3000; i++) {
        enter(); int requeued = device_current == NULL; leave();
        if (requeued) break;
        pause_ms();
    }
    enter(); assert(!device_current && waiting_devices == 81 && !quarantined_pins); leave();
    atomic_store(&pending->init_done, 1); hv_npt_cleanup_set_active(1); await_idle();
    assert(atomic_load(&pending->destroyed) && atomic_load(&first->destroyed));
}
static void allocation_failures(void) {
    setup(); FakeDevice *d = device(); atomic_store(&fail_alloc, 1);
    hv_npt_device_release(d); assert(count_load(&d->priv) == 1);
    FakeObject *o = object(1, NULL); hv_npt_capture_object(record(o, 1));
    atomic_store(&fail_alloc, 1); hv_npt_cleanup_submit();
    enter(); assert(quarantined_batches == 1 && quarantined_refs == 1 && quarantined_pins == 1); leave();
    assert(!atomic_load(&d->destroyed) && !atomic_load(&o->releases));
}
static void thread_failure(void) {
    setup(); FakeDevice *d = device(); atomic_store(&fail_thread, 1);
    hv_npt_device_release(d);
    enter(); assert(!quarantined_pins && !device_worker_started && waiting_devices == 1); leave();
    assert(count_load(&d->priv) == 1 && !atomic_load(&d->destroyed));
    hv_npt_cleanup_poll(); await_value(&d->destroyed, 1); await_idle();
}
static void unverified_and_malformed(void) {
    assert(hv_npt_cleanup_set_device_ops(&ops));
    FakeObject *o = object(1, NULL); submit(o, 1); await_idle();
    assert(!atomic_load(&o->releases)); enter(); assert(quarantined_refs == 1); leave();
}
static void malformed_record_retains(void) {
    setup(); FakeObject *o = object(1, NULL); submit(o, 0); await_idle();
    assert(!atomic_load(&o->releases)); enter(); assert(quarantined_objects == 1); leave();
}
typedef struct { FakeObject *o; _Atomic unsigned captured, submit, finished; } Producer;
static void *produce(void *p) {
    Producer *a = p; hv_npt_capture_object(record(a->o, 1)); atomic_store(&a->captured, 1);
    while (!atomic_load(&a->submit)) pause_ms();
    hv_npt_cleanup_submit(); atomic_store(&a->finished, 1); return NULL;
}
static void thread_local_markers(void) {
    setup(); Producer a = {.o = object(1, NULL)}, b = {.o = object(1, NULL)};
    pthread_t ta, tb; assert(!pthread_create(&ta, NULL, produce, &a)); assert(!pthread_create(&tb, NULL, produce, &b));
    await_value(&a.captured, 1); await_value(&b.captured, 1);
    hv_npt_cleanup_submit(); /* unrelated renderer thread cannot flush either */
    atomic_store(&a.submit, 1); await_value(&a.o->releases, 1);
    assert(!atomic_load(&b.o->releases));
    atomic_store(&b.submit, 1); await_value(&b.o->releases, 1);
    pthread_join(ta, NULL); pthread_join(tb, NULL); await_idle();
}
static void *count_racer(void *p) {
    for (unsigned i = 0; i < 1000; i++) {
        void *out;
        assert(!hv_npt_device_query_interface(p, i & 1 ? p : NULL, &out));
        assert(out == p);
        hv_npt_device_release(p);
    }
    return NULL;
}
static void concurrent_reference_transitions(void) {
    setup(); FakeDevice *d = device(); pthread_t threads[4];
    for (unsigned i = 0; i < 4; i++) assert(!pthread_create(&threads[i], NULL, count_racer, d));
    for (unsigned i = 0; i < 4; i++) pthread_join(threads[i], NULL);
    assert(count_load(&d->pub) == 1 && count_load(&d->priv) == 1);
    hv_npt_device_release(d); await_value(&d->destroyed, 1); await_idle();
}

static void await_initializer_retry(FakeDevice *d) {
    for (unsigned i = 0; i < 3000; i++) {
        enter(); int found = 0;
        for (Job *j = device_waiting; j; j = j->next)
            if (j->device == d && j->initializer_stalling) found = 1;
        leave();
        if (found) return;
        pause_ms();
    }
    assert(!"initializer did not become pending");
}
static FakeDevice *stalled_device(void) {
    FakeDevice *d = device();
    atomic_store(&d->init_goal, 5); atomic_store(&d->init_done, 4);
    hv_npt_device_release(d); await_initializer_retry(d);
    return d;
}
static void stale_event_recovers_after_hour(void) {
    setup(); FakeDevice *d = stalled_device();
    atomic_store(&d->barrier_status, 1);
    advance(UINT64_C(3600000000000));
    await_value(&d->destroyed, 1); await_idle();
    assert(atomic_load(&d->init_done) == 4 && atomic_load(&d->barrier_entered) == 1);
    assert(atomic_load(&d->barrier_released) == 1);
    enter(); assert(barrier_recoveries == 1 && !quarantined_pins); leave();
}
static void failed_barrier_retries(void) {
    setup(); FakeDevice *d = stalled_device(); atomic_store(&d->barrier_status, 2);
    advance(UINT64_C(6000000000)); await_value(&d->barrier_released, 1);
    assert(!atomic_load(&d->destroyed) && count_load(&d->priv) == 1);
    enter(); assert(!quarantined_pins && !barrier_recoveries); leave();
    atomic_store(&d->barrier_status, 1);
    await_value(&d->destroyed, 1); await_idle();
    assert(atomic_load(&d->barrier_entered) >= 2);
}
static void nil_barrier_backoff(void) {
    setup(); FakeDevice *d = stalled_device(); atomic_store(&d->barrier_nil, 1);
    for (unsigned i = 0; i < 10; i++) {
        unsigned calls = atomic_load(&d->event_entered);
        advance(UINT64_C(1000000000)); await_value(&d->event_entered, calls + 1);
        await_initializer_retry(d);
    }
    enter();
    assert(device_waiting && device_waiting->retry_ns == NPT_RETRY_MAX_NS);
    assert(!quarantined_pins);
    leave();
    unsigned calls = atomic_load(&d->event_entered);
    for (int i = 0; i < 30; i++) pause_ms();
    assert(atomic_load(&d->event_entered) == calls); /* no 100Hz endless polling */
    assert(!atomic_load(&d->destroyed) && atomic_load(&d->barrier_entered));
    atomic_store(&d->barrier_nil, 0); atomic_store(&d->barrier_status, 1);
    advance(NPT_RETRY_MAX_NS); await_value(&d->destroyed, 1); await_idle();
}
static void pending_barrier_single_ticket(void) {
    setup(); FakeDevice *d = stalled_device();
    advance(UINT64_C(6000000000)); await_value(&d->barrier_entered, 1);
    await_value(&d->barrier_polls, 1);
    for (unsigned i = 0; i < 4; i++) { advance(NPT_RETRY_MAX_NS); pause_ms(); }
    assert(atomic_load(&d->barrier_entered) == 1 && !atomic_load(&d->destroyed));
    atomic_store(&d->barrier_status, 1);
    advance(NPT_RETRY_MAX_NS); await_value(&d->destroyed, 1); await_idle();
    assert(atomic_load(&d->barrier_released) == 1);
}
static void background_blocks_barrier_factory(void) {
    setup(); FakeDevice *d = stalled_device();
    hv_npt_cleanup_set_active(0); advance(UINT64_C(3600000000000));
    for (int i = 0; i < 10; i++) pause_ms();
    assert(!atomic_load(&d->barrier_entered));
    hv_npt_cleanup_set_active(1); atomic_store(&d->barrier_status, 1);
    advance(UINT64_C(6000000000)); await_value(&d->destroyed, 1); await_idle();
}
static void factory_spans_background(void) {
    setup(); FakeDevice *d = stalled_device(); atomic_store(&d->block_barrier, 1);
    advance(UINT64_C(6000000000)); await_value(&d->barrier_entered, 1);
    hv_npt_cleanup_set_active(0); atomic_store(&d->block_barrier, 0);
    for (int i = 0; i < 10; i++) pause_ms();
    assert(!atomic_load(&d->barrier_polls) && !atomic_load(&d->destroyed));
    atomic_store(&d->barrier_status, 1); hv_npt_cleanup_set_active(1);
    advance(NPT_RETRY_MAX_NS); await_value(&d->destroyed, 1); await_idle();
    assert(atomic_load(&d->barrier_entered) == 2);
}
static void resurrection_during_barrier_poll(void) {
    setup(); FakeDevice *d = stalled_device();
    atomic_store(&d->barrier_status, 1); atomic_store(&d->block_barrier_poll, 1);
    advance(UINT64_C(6000000000)); await_value(&d->barrier_poll_entered, 1);
    void *alias; assert(!hv_npt_device_query_interface(d, NULL, &alias));
    atomic_store(&d->main_goal, 9); atomic_store(&d->main_done, 8);
    hv_npt_device_release(d); atomic_store(&d->block_barrier_poll, 0);
    await_value(&d->barrier_released, 1);
    for (int i = 0; i < 10; i++) pause_ms();
    assert(!atomic_load(&d->destroyed) && count_load(&d->priv) == 1);
    atomic_store(&d->main_done, 9); atomic_store(&d->init_done, 5);
    hv_npt_cleanup_poll(); await_value(&d->destroyed, 1); await_idle();
}
static void successful_barrier_survives_background(void) {
    setup(); FakeDevice *d = stalled_device();
    atomic_store(&d->barrier_status, 1); atomic_store(&d->pause_on_barrier_success, 1);
    advance(UINT64_C(6000000000)); await_value(&d->barrier_polls, 1);
    for (int i = 0; i < 10; i++) pause_ms();
    assert(!hv_npt_cleanup_gpu_allowed() && !atomic_load(&d->destroyed));
    hv_npt_cleanup_set_active(1); await_value(&d->destroyed, 1); await_idle();
    assert(atomic_load(&d->barrier_entered) == 1);
}
static void slow_getter_return_recovers_unwired_gate(void) {
    setup(); FakeDevice *d = device();
    atomic_store(&d->init_goal, 1); atomic_store(&d->init_done, 1); atomic_store(&d->block_event, 1);
    hv_npt_device_release(d); await_value(&d->event_entered, 1);
    advance(UINT64_C(6000000000));
    enter(); assert(device_current->call_stalled && !device_current->expired); leave();
    atomic_store(&d->block_event, 0); await_value(&d->destroyed, 1); await_idle();
    enter(); assert(!quarantined_pins && slow_calls == 1); leave();
}

int main(void) {
    struct { const char *name; void (*run)(void); } cases[] = {
        {"stale initializer event recovers after an hour", stale_event_recovers_after_hour},
        {"own errored barrier retries without deleting", failed_barrier_retries},
        {"nil barrier retries with bounded polling", nil_barrier_backoff},
        {"pending barrier keeps one ticket", pending_barrier_single_ticket},
        {"background prevents barrier factory", background_blocks_barrier_factory},
        {"blocked factory spans background safely", factory_spans_background},
        {"QI resurrection during barrier poll", resurrection_during_barrier_poll},
        {"successful barrier proof survives background", successful_barrier_survives_background},
        {"slow passive getter recovers without lifecycle gate", slow_getter_return_recovers_unwired_gate},
        {"hidden graph, aliases, registrations, tombstone", healthy_hidden_graph},
        {"main and initializer retire independently", delayed_main_and_initializer},
        {"long main and initializer waits stay retryable", long_counter_wait_remains_retryable},
        {"initializer getter error quarantines", getter_error_retains},
        {"invalid native snapshot quarantines", invalid_snapshot_retains},
        {"QI resurrection during getter", resurrection_during_getter},
        {"multiple public-zero epochs", many_zero_epochs},
        {"blocked getter watchdog pauses in background", blocked_getter_background},
        {"queued background time does not age", paused_queue_does_not_age},
        {"blocked Release stops subsequent calls", blocked_release_no_followup},
        {"blocked batch does not block device retirement", blocked_batch_does_not_block_device},
        {"destructor transient AddRef and QI do not enqueue", destructor_transient_references_do_not_enqueue},
        {"deleting destructor runs outside mutex", destructor_outside_mutex},
        {"failed finalizer retains sealed device", failed_finalizer_retains_sealed_device},
        {"bounded batch queue and retryable device backlog", queue_limits},
        {"retry does not evict device backlog", retry_does_not_evict_devices},
        {"allocation failure retains refs", allocation_failures},
        {"device thread creation failure is retryable", thread_failure},
        {"unverified backend cannot release", unverified_and_malformed},
        {"malformed registration remains retained", malformed_record_retains},
        {"backend TLS completion markers", thread_local_markers},
        {"concurrent QI and Release transitions", concurrent_reference_transitions}
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(*cases); i++) {
        pid_t child = fork(); assert(child >= 0);
        if (!child) { alarm(15); cases[i].run(); _exit(0); }
        int status; assert(waitpid(child, &status, 0) == child);
        if (!WIFEXITED(status) || WEXITSTATUS(status)) {
            fprintf(stderr, "FAIL: %s (status=%d)\n", cases[i].name, status); return 1;
        }
        printf("PASS: %s\n", cases[i].name);
    }
    return 0;
}
