/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Neptune owns one host COM reference per record registration, but its pinned
 * destroy loop only frees the record. Release those references on a worker.
 *
 * The paired DXMT hooks delay the LAST private device reference until both
 * queues retire. Intercepting the ownership boundary covers hidden COM graphs
 * (including arbitrary SetPrivateDataInterface links), unlike enumerating the
 * remaining table's visible devices. The exact device QI/AddRef/Release code,
 * counter layout and queue layout MUST be verified before enabling cleanup.
 *
 * DXMT 8b9d334's queue destructor stops workers before draining all GPU work;
 * its no-copy argument buffers and external dynamic allocations make immediate
 * destruction unsafe (ordinary CpuPlaced dynamic backing is i386-only).
 * ready_for_encode-1 <= cpu_coherent proves main-queue completion (also on GPU
 * error). The initializer's final signal event proves its submitted uploads
 * completed. If an error suppresses that signal, a successful empty buffer
 * on the initializer's own queue can prove retirement after foreground return.
 */
#include "neptune_cleanup.h"

#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define NPT_BATCH_LIMIT 8u
#define NPT_TIMEOUT_NS UINT64_C(5000000000)
#define NPT_RETRY_MIN_NS UINT64_C(10000000)
#define NPT_RETRY_MAX_NS UINT64_C(1000000000)
#define NPT_PRIVATE_SENTINEL UINT32_C(0x80000000)
#define NPT_LOG(...) do { fprintf(stderr, "winvm: 3d: Neptune cleanup: "); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)

typedef struct NptRecord NptRecord;
struct NptRecord {
    NptRecord *next; /* dead table's uint64_t id; no subsequent lookup */
    uint16_t type;
    void *object;
    void *identity;
    uint32_t regs;
};
_Static_assert(sizeof(NptRecord) == 40, "pinned Neptune record size");
_Static_assert(offsetof(NptRecord, object) == 16, "pinned host_ptr");
_Static_assert(offsetof(NptRecord, regs) == 32, "pinned registration count");

typedef uint32_t (*Release)(void *);
#define COM_RELEASE(obj) (((union { void *p; Release f; }){ \
    .p = (*(void ***)(obj))[2] }).f)(obj)

typedef struct Job Job;
struct Job {
    Job *next;
    NptRecord *records;
    void *device;
    void *barrier;
    uint64_t id, objects, refs, start, call_start, initializer_done;
    uint64_t next_poll, retry_ns, initializer_stall_since, barrier_goal;
    int started, expired, pin, destroying, sealed, native_call;
    int call_stalled, initializer_stalling, barrier_completed, paused_ready;
    const char *reason, *call;
    struct HvNptDeviceSnapshot snapshot;
};

static pthread_once_t once = PTHREAD_ONCE_INIT;
static pthread_mutex_t lock;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static _Thread_local NptRecord *captured;
static _Thread_local uint64_t captured_objects, captured_refs;
static NptRecord *unbatched_quarantine;
static uint64_t collecting_objects, collecting_refs;
static unsigned collecting_batches;
static Job *waiting, *waiting_tail, *current, *quarantine;
static Job *device_waiting, *device_waiting_tail, *device_current;
static unsigned waiting_batches, waiting_devices;
static unsigned device_highwater;
static uint64_t quarantined_batches, quarantined_objects, quarantined_refs;
static uint64_t quarantined_pins, failed_finalizers, retired_devices, released_refs, next_id;
static uint64_t slow_calls, barrier_recoveries;
static int allowed = 1, clock_started, worker_started, device_worker_started, operations_started, backend_verified;
static uint64_t active_total, active_since;
static struct HvNptDeviceOps device_ops;

static void init_lock(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&lock, &attr);
    pthread_mutexattr_destroy(&attr);
}
static void enter(void) { pthread_once(&once, init_lock); pthread_mutex_lock(&lock); }
static void leave(void) { pthread_mutex_unlock(&lock); }

#ifndef NPT_NOW_NS
static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
#define NPT_NOW_NS() now_ns()
#endif

/* All helpers suffixed _locked require the lifetime mutex. */
static uint64_t active_clock(void) {
    uint64_t now = NPT_NOW_NS();
    if (!clock_started) { active_since = now; clock_started = 1; }
    return active_total + (allowed ? now - active_since : 0);
}
static uint32_t *public_count(void *d) { return (uint32_t *)((char *)d + 8); }
static uint32_t *private_count(void *d) { return (uint32_t *)((char *)d + 12); }
static uint32_t count_load(uint32_t *p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
static const char *kind(Job *j) { return j->device ? "device" : "batch"; }

static void expire_locked(Job *j) {
    /* A device whose GPU counters are still pending must remain retryable,
     * however long the wait (including an unwired lifecycle gate/suspension).
     * Its watchdog applies only to one entered native call, never queue age. */
    if (!j || (j->device && !j->native_call)) return;
    uint64_t elapsed = active_clock() - (j->device ? j->call_start : j->start);
    if (j->device && j->native_call == 2) {
        /* A returned passive read is still valid even after suspension. The
         * watchdog reports a blocked probe but never poisons its later result. */
        if (!j->call_stalled && elapsed >= NPT_TIMEOUT_NS) {
            j->call_stalled = 1; slow_calls++;
            NPT_LOG("device %" PRIu64 " stalled call=%s elapsed=%" PRIu64
                    "ms; retained and will recheck returned result", j->id,
                    j->call, elapsed / UINT64_C(1000000));
        }
        return;
    }
    if (!j->expired && elapsed >= NPT_TIMEOUT_NS) {
        j->expired = 1;
        j->reason = "active-time deadline";
        NPT_LOG("%s %" PRIu64 " deadline: elapsed=%" PRIu64 "ms call=%s "
                "refs=%" PRIu64 " pin=%d%s; entered call is not cancelled",
                kind(j), j->id, elapsed / UINT64_C(1000000),
                j->call ? j->call : "between calls", j->refs, j->pin,
                j->destroying ? " (destructor already entered)" : "");
    }
}
static int gate_locked(Job *j) {
    expire_locked(j);
    while (!allowed && !j->device && !j->expired) {
        pthread_cond_wait(&changed, &lock);
        expire_locked(j);
    }
    return !j->expired;
}
static int call_enter(Job *j, const char *name, int native_call) {
    enter();
    int ok = gate_locked(j);
    if (ok) { j->call = name; j->call_start = active_clock(); j->native_call = native_call; }
    leave();
    return ok;
}
static void call_leave(Job *j) {
    enter(); expire_locked(j);
    if (j->call_stalled) NPT_LOG("device %" PRIu64 " returned from %s; rechecking result", j->id, j->call);
    j->call = NULL; j->native_call = 0; j->call_stalled = 0; leave();
}
static void fail_locked(Job *j, const char *reason) { if (!j->reason) j->reason = reason; }

static void quarantine_locked(Job *j, const char *reason) {
    fail_locked(j, reason);
    j->next = quarantine; quarantine = j;
    if (j->device) { quarantined_pins += j->pin; failed_finalizers += j->sealed; }
    else {
        quarantined_batches++;
        quarantined_objects += j->objects;
        quarantined_refs += j->refs;
    }
    NPT_LOG("retained %s %" PRIu64 ": %s objects=%" PRIu64
            " refs=%" PRIu64 " device_pins=%d failed_finalizer=%d", kind(j), j->id, j->reason,
            j->objects, j->refs, j->pin, j->sealed);
}

static void append_locked(Job *j) {
    j->next = NULL;
    Job **head = j->device ? &device_waiting : &waiting;
    Job **tail = j->device ? &device_waiting_tail : &waiting_tail;
    if (*tail) (*tail)->next = j; else *head = j;
    *tail = j;
    if (j->device) {
        waiting_devices++;
        if (waiting_devices > device_highwater) {
            device_highwater = waiting_devices;
            if (device_highwater == 65 || (device_highwater > 65 && !(device_highwater & (device_highwater - 1))))
                NPT_LOG("pending device highwater=%u; GPU retirement remains retryable", device_highwater);
        }
    } else waiting_batches++;
}
static void remove_locked(Job *j, Job *previous) {
    Job **head = j->device ? &device_waiting : &waiting;
    Job **tail = j->device ? &device_waiting_tail : &waiting_tail;
    if (previous) previous->next = j->next; else *head = j->next;
    if (*tail == j) *tail = previous;
    if (j->device) waiting_devices--; else waiting_batches--;
    j->next = NULL;
}
static void limit_batch_queue_locked(void) {
    if (waiting_batches <= NPT_BATCH_LIMIT) return;
    Job *j = waiting;
    remove_locked(j, NULL);
    quarantine_locked(j, "waiting queue limit");
}

static int release_batch(Job *j) {
    enter();
    int verified = backend_verified;
    if (!verified) fail_locked(j, "device lifetime hooks not verified");
    leave();
    if (!verified) return 0;
    while (j->records) {
        NptRecord *r = j->records;
        if (r->object && !r->regs) {
            enter(); fail_locked(j, "nonnull record without registrations"); leave();
            return 0;
        }
        while (r->object && r->regs) {
            if (!call_enter(j, "Release registration", 1)) return 0;
            /* The entered call owns this reference now, even if its destructor
             * blocks. Quarantine/describe count only references still ours. */
            enter(); r->regs--; j->refs--; leave();
            COM_RELEASE(r->object);
            call_leave(j);
            enter(); released_refs++; leave();
        }
        enter(); j->records = r->next; j->objects--; leave();
        free(r);
    }
    return 1;
}

static int release_barrier(Job *j) {
    /* Worker-owned only, including quarantine cleanup. Transfer this one
     * native reference before entering release, which can itself block.
     * Neither the watchdog nor another thread may release it again. Empty
     * committed buffers own no DXMT resources, and Metal retains execution. */
    enter();
    void *barrier = j->barrier;
    j->barrier = NULL;
    if (!barrier) { leave(); return 1; }
    j->call = "release initializer barrier";
    j->call_start = active_clock(); j->native_call = 2;
    leave();
    device_ops.barrier_release(barrier);
    call_leave(j);
    return 1;
}

/* Return 1 only on successful same-queue completion; Error/nil/pending are
 * retryable and never prove retirement of preceding initializer buffers. */
static int initializer_barrier(Job *j) {
    if (j->barrier) {
        if (!call_enter(j, "initializer barrier status", 2)) return 0;
        int status = device_ops.barrier_status(j->barrier);
        call_leave(j);
        if (status > 0 && j->snapshot.initializer_goal <= j->barrier_goal) {
            enter(); j->barrier_completed = 1; barrier_recoveries++; leave();
            NPT_LOG("device %" PRIu64 " initializer recovered by successful same-queue barrier goal=%" PRIu64,
                    j->id, j->barrier_goal);
            return 1;
        }
        if (status < 0 || j->snapshot.initializer_goal > j->barrier_goal) release_barrier(j);
        return 0;
    }
    enter();
    uint64_t elapsed = active_clock() - j->initializer_stall_since;
    int can_submit = allowed;
    leave();
    if (!can_submit || elapsed < NPT_TIMEOUT_NS || !j->snapshot.initializer_queue) return 0;
    if (!call_enter(j, "create initializer barrier", 2)) return 0;
    uint64_t goal = j->snapshot.initializer_goal;
    void *barrier = device_ops.barrier_begin(j->snapshot.initializer_queue);
    call_leave(j);
    enter(); j->barrier = barrier; j->barrier_goal = goal; leave();
    return 0;
}

/* Return 1 when consumed, 2 to retry, 0 to retain permanently. One pin belongs
 * to each public-zero epoch. Resurrection adds another private reference under
 * the same mutex; an old epoch can drop its pin without destroying that owner.
 * Only the LAST private pin requires a stable queue-retirement snapshot. */
static int retire_device(Job *j) {
    if (!call_enter(j, "snapshot retirement", 0)) return 0;
    enter();
    int was_paused_ready = j->paused_ready;
    j->paused_ready = 0;
    expire_locked(j);
    if (j->expired) { j->call = NULL; leave(); return 0; }
    uint32_t pub = count_load(public_count(j->device));
    uint32_t priv = count_load(private_count(j->device));
    if (!priv || priv >= NPT_PRIVATE_SENTINEL || (pub && priv == 1)) {
        fail_locked(j, "invalid device reference counts");
        j->call = NULL; leave(); return 0;
    }
    if (priv > 1) {
        __atomic_fetch_sub(private_count(j->device), 1, __ATOMIC_SEQ_CST);
        j->pin = 0; j->call = NULL; leave(); return release_barrier(j);
    }
    /* public == 0 and the lifetime mutex excludes QI/AddRef resurrection.
     * In particular initializer seq is non-atomic and may ONLY be read here. */
    uint64_t old_main_done = j->snapshot.main_done;
    uint64_t old_initializer_goal = j->snapshot.initializer_goal;
    int valid = device_ops.snapshot && device_ops.snapshot(j->device, &j->snapshot);
    if (old_main_done != j->snapshot.main_done) j->retry_ns = 0;
    int obsolete_barrier = valid && (j->barrier || j->barrier_completed) &&
                           j->snapshot.initializer_goal > j->barrier_goal;
    if (valid && j->snapshot.initializer_goal > old_initializer_goal) {
        j->initializer_stalling = 0; j->retry_ns = 0;
    }
    if (obsolete_barrier) {
        j->barrier_completed = 0; j->barrier_goal = 0;
        j->initializer_stalling = 0;
    }
    if (!valid) fail_locked(j, "invalid device retirement snapshot");
    j->call = NULL;
    leave();
    if (!valid) return 0;
    if (obsolete_barrier) release_barrier(j);
    if (j->snapshot.main_done < j->snapshot.main_goal) return 2;
    uint64_t event_value = 0;
    /* A later epoch may run first and drop its pin while this job backs off.
     * Only the captured initializer goal identifies what a barrier covered. */
    if (j->snapshot.initializer_goal && !j->barrier_completed) {
        if (!j->snapshot.event || !call_enter(j, "initializer event value", 2)) return 0;
        valid = device_ops.event_value && device_ops.event_value(j->snapshot.event, &event_value);
        call_leave(j);
        enter();
        if (j->initializer_done != event_value) {
            j->retry_ns = 0; j->initializer_stalling = 0;
        }
        j->initializer_done = event_value;
        leave();
        if (!valid) { enter(); fail_locked(j, "initializer event read failed"); leave(); return 0; }
        if (event_value < j->snapshot.initializer_goal) {
            enter();
            if (!j->initializer_stalling) {
                j->initializer_stalling = 1; j->initializer_stall_since = active_clock();
            }
            leave();
            if (!initializer_barrier(j)) return 2;
        }
    }
    if (!release_barrier(j)) return 0;
    if (!call_enter(j, "prepare device deletion", 0)) return 0;
    enter();
    /* No mutex was held across the event getter. A new public-zero epoch may
     * have appeared meanwhile, in which case its separate pin owns new work. */
    pub = count_load(public_count(j->device));
    priv = count_load(private_count(j->device));
    expire_locked(j);
    if (j->expired) { j->call = NULL; leave(); return 0; }
    if (!priv || priv >= NPT_PRIVATE_SENTINEL || (pub && priv == 1)) {
        fail_locked(j, "device reference counts changed unexpectedly");
        j->call = NULL; leave(); return 0;
    }
    if (priv == 1) {
        struct HvNptDeviceSnapshot latest;
        if (!device_ops.snapshot(j->device, &latest)) {
            fail_locked(j, "invalid final device retirement snapshot");
            j->call = NULL; leave(); return 0;
        }
        int initializer_retired = event_value >= latest.initializer_goal ||
            (j->barrier_completed && latest.initializer_goal <= j->barrier_goal);
        if (latest.main_done < latest.main_goal || !initializer_retired) {
            if (latest.initializer_goal > j->snapshot.initializer_goal) {
                j->initializer_stalling = 0; j->retry_ns = 0;
            }
            if (latest.initializer_goal > j->barrier_goal) j->barrier_completed = 0;
            j->snapshot = latest;
            j->call = NULL; leave(); return 2;
        }
        j->snapshot = latest;
        if (!allowed) {
            j->paused_ready = 1;
            if (!was_paused_ready)
                NPT_LOG("device %" PRIu64 " queues retired; final destruction waits for foreground", j->id);
            j->call = NULL; leave(); return 2;
        }
    }
    __atomic_fetch_sub(private_count(j->device), 1, __ATOMIC_SEQ_CST);
    j->pin = 0;
    if (priv > 1) { j->call = NULL; leave(); return 1; }
    /* Same sentinel as the pinned ComObjectWithInitialRef::ReleasePrivate. */
    __atomic_fetch_add(private_count(j->device), NPT_PRIVATE_SENTINEL, __ATOMIC_SEQ_CST);
    j->destroying = 1; j->sealed = 1;
    j->call = "quiesce and delete device";
    j->call_start = active_clock(); j->native_call = 1;
    leave();
    int destroyed = device_ops.destroy(j->device);
    enter();
    expire_locked(j);
    if (destroyed) { retired_devices++; j->sealed = 0; }
    else fail_locked(j, "native finalizer failed; sealed device retained");
    j->destroying = 0; j->call = NULL; j->native_call = 0;
    leave();
    return !!destroyed;
}

static void wait_retry_locked(uint64_t ns) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += (time_t)(ns / UINT64_C(1000000000));
    until.tv_nsec += (long)(ns % UINT64_C(1000000000));
    if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
    pthread_cond_timedwait(&changed, &lock, &until);
}
static Job *take_job_locked(int devices) {
    for (;;) {
        while (!(devices ? device_waiting : waiting) || (!devices && !allowed)) pthread_cond_wait(&changed, &lock);
        if (!devices) { Job *j = waiting; remove_locked(j, NULL); return j; }
        /* Passive device polling continues in the background. The separate
         * active clock remains for watchdogs and foreground barrier stalls. */
        uint64_t now = NPT_NOW_NS(), delay = NPT_RETRY_MAX_NS;
        Job *previous = NULL;
        for (Job *j = device_waiting; j; previous = j, j = j->next) {
            if (j->next_poll <= now) { remove_locked(j, previous); return j; }
            if (j->next_poll - now < delay) delay = j->next_poll - now;
        }
        wait_retry_locked(delay);
    }
}
static void *cleanup_worker(void *lane) {
    int devices = (int)(uintptr_t)lane;
    for (;;) {
        enter();
        Job *j = take_job_locked(devices);
        if (!j->started) { j->started = 1; j->start = active_clock(); }
        if (devices) device_current = j; else current = j;
        uint64_t objects = j->objects, refs = j->refs;
        leave();
        int result = j->device ? retire_device(j) : release_batch(j);
        enter();
        if (result == 2) { expire_locked(j); if (j->expired) result = 0; }
        leave();
        /* A failed retirement retains its private pin, but need not leak the
         * independent empty-buffer ticket too. Never make this native call
         * from quarantine_locked(), expire_locked() or under the mutex. */
        if (!result && j->device) release_barrier(j);
        enter();
        if (devices) device_current = NULL; else current = NULL;
        if (!result) quarantine_locked(j, "cleanup could not complete");
        if (result == 2) {
            j->retry_ns = j->retry_ns ? j->retry_ns * 2 : NPT_RETRY_MIN_NS;
            if (j->retry_ns > NPT_RETRY_MAX_NS) j->retry_ns = NPT_RETRY_MAX_NS;
            j->next_poll = NPT_NOW_NS() + j->retry_ns;
            append_locked(j);
        }
        leave();
        if (result == 1) {
            if (j->device)
                NPT_LOG("retired device epoch %" PRIu64 " main=%" PRIu64 "/%" PRIu64
                        " initializer=%" PRIu64 "/%" PRIu64 " barrier=%d barrier_goal=%" PRIu64,
                        j->id, j->snapshot.main_done, j->snapshot.main_goal, j->initializer_done,
                        j->snapshot.initializer_goal, j->barrier_completed, j->barrier_goal);
            else
                NPT_LOG("released batch %" PRIu64 ": %" PRIu64 " objects / %" PRIu64
                        " registrations; final devices retire separately", j->id, objects, refs);
            free(j);
        }
    }
    return NULL;
}

static void start_worker_locked(int devices) {
    int *started = devices ? &device_worker_started : &worker_started;
    if (*started || !(devices ? device_waiting : waiting)) return;
    pthread_t thread;
    pthread_attr_t attr;
    int err = pthread_attr_init(&attr);
    if (!err) {
        err = pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (!err) err = pthread_create(&thread, &attr, cleanup_worker, (void *)(uintptr_t)devices);
        pthread_attr_destroy(&attr);
    }
    if (err) {
        if (devices) {
            NPT_LOG("device worker creation failed (%d); pending devices remain retryable", err);
            return;
        }
        while (waiting) {
            Job *j = waiting; remove_locked(j, NULL);
            quarantine_locked(j, "worker creation failed");
        }
    } else *started = 1;
}
static void enqueue_locked(Job *j) {
    j->id = ++next_id;
    append_locked(j);
    if (!j->device) limit_batch_queue_locked();
    start_worker_locked(!!j->device);
    pthread_cond_broadcast(&changed);
}

int32_t hv_npt_device_query_interface(void *device, const void *iid, void **out) {
    enter(); operations_started = 1;
    /* The exact original QI has an inline refcount increment. Its verified
     * body only compares IIDs, returns aliases, AddRefs them, or logs an unknown
     * IID. Recursive locking permits its calls to the hooked AddRef. */
    int32_t hr = device_ops.query_interface(device, iid, out);
    leave(); return hr;
}
uint32_t hv_npt_device_addref(void *device) {
    enter(); operations_started = 1;
    uint32_t old = __atomic_fetch_add(public_count(device), 1, __ATOMIC_SEQ_CST);
    if (!old) __atomic_fetch_add(private_count(device), 1, __ATOMIC_SEQ_CST);
    leave(); return old + 1;
}
uint32_t hv_npt_device_release(void *device) {
    enter(); operations_started = 1;
    uint32_t count = __atomic_fetch_sub(public_count(device), 1, __ATOMIC_SEQ_CST) - 1;
    if (!count) {
        /* Deletion has already consumed the final private pin and installed
         * the original sentinel. Destructor callbacks may transiently QI or
         * AddRef this same object. Balance that epoch exactly as the original
         * ReleasePrivate does; never enqueue a pointer about to be freed. */
        if (count_load(private_count(device)) >= NPT_PRIVATE_SENTINEL) {
            __atomic_fetch_sub(private_count(device), 1, __ATOMIC_SEQ_CST);
            leave(); return count;
        }
        /* Keep the private reference that the original Release would drop.
         * Failure to allocate bookkeeping must leak it, never destroy early. */
        Job *j = calloc(1, sizeof(*j));
        if (!j) {
            quarantined_pins++;
            NPT_LOG("retained device pin: bookkeeping allocation failed");
        } else {
            j->device = device; j->pin = 1;
            enqueue_locked(j);
        }
    }
    leave(); return count;
}

void hv_npt_capture_object(void *record) {
    if (!record) return;
    NptRecord *r = record;
    enter(); operations_started = 1;
    if (!captured) collecting_batches++;
    r->next = captured; captured = r;
    captured_objects++; collecting_objects++;
    if (r->object) { captured_refs += r->regs; collecting_refs += r->regs; }
    leave();
}
void hv_npt_cleanup_submit(void) {
    enter();
    if (!captured) { leave(); return; }
    collecting_batches--;
    collecting_objects -= captured_objects; collecting_refs -= captured_refs;
    Job *j = calloc(1, sizeof(*j));
    if (!j) {
        NptRecord *tail = captured;
        while (tail->next) tail = tail->next;
        tail->next = unbatched_quarantine; unbatched_quarantine = captured;
        quarantined_batches++; quarantined_objects += captured_objects; quarantined_refs += captured_refs;
        NPT_LOG("retained batch: allocation failed (%" PRIu64 " registrations)", captured_refs);
    } else {
        j->records = captured; j->objects = captured_objects; j->refs = captured_refs;
        enqueue_locked(j);
    }
    captured = NULL; captured_objects = captured_refs = 0;
    leave();
}
void hv_npt_cleanup_poll(void) {
    enter(); expire_locked(current); expire_locked(device_current);
    start_worker_locked(1); pthread_cond_broadcast(&changed); leave();
}
void hv_npt_cleanup_set_active(int active) {
    enter();
    uint64_t value = active_clock();
    if (!!active != allowed) {
        active_total = value; active_since = NPT_NOW_NS(); allowed = !!active;
        NPT_LOG("%s; watchdog counts allowed time only", allowed ? "resumed" : "paused");
    }
    start_worker_locked(1); pthread_cond_broadcast(&changed); leave();
}
int hv_npt_cleanup_gpu_allowed(void) { enter(); int value = allowed; leave(); return value; }
int hv_npt_cleanup_set_device_ops(const struct HvNptDeviceOps *ops) {
    enter();
    int ok = !operations_started && !worker_started && !device_worker_started && ops && ops->query_interface
             && ops->snapshot && ops->event_value && ops->destroy
             && ops->barrier_begin && ops->barrier_status && ops->barrier_release;
    if (ok) device_ops = *ops;
    leave(); return ok;
}
void hv_npt_cleanup_set_backend_verified(int verified) {
    enter();
    if (!worker_started && !device_worker_started && !operations_started) backend_verified = !!verified;
    leave();
}
void hv_npt_cleanup_describe(char *buffer, size_t length) {
    enter();
    uint64_t objects = collecting_objects, refs = collecting_refs, pins = waiting_devices;
    uint64_t qb = quarantined_batches, qo = quarantined_objects, qr = quarantined_refs, qp = quarantined_pins;
    unsigned batches = waiting_batches + collecting_batches;
    unsigned stalled_initializers = 0, paused_ready = 0;
    uint64_t now = active_clock();
    for (Job *j = device_waiting; j; j = j->next) {
        if (j->initializer_stalling && now - j->initializer_stall_since >= NPT_TIMEOUT_NS) stalled_initializers++;
        if (!allowed && j->paused_ready) paused_ready++;
    }
    for (Job *j = waiting; j; j = j->next) { objects += j->objects; refs += j->refs; }
    if (current) {
        if (current->expired) {
            qb++; qo += current->objects; qr += current->refs;
        } else { batches++; objects += current->objects; refs += current->refs; }
    }
    if (device_current) {
        if (!allowed && device_current->paused_ready) paused_ready++;
        if (device_current->initializer_stalling && now - device_current->initializer_stall_since >= NPT_TIMEOUT_NS)
            stalled_initializers++;
        if (device_current->expired) qp += device_current->pin;
        else pins += device_current->pin;
    }
    snprintf(buffer, length, "cleanup %s pending=%u/%" PRIu64 "/%" PRIu64
             " devices=%" PRIu64 " quarantined=%" PRIu64 "/%" PRIu64 "/%" PRIu64
             " device_pins=%" PRIu64 " failed_finalizers=%" PRIu64
             " finalizing=%d released=%" PRIu64 " retired=%" PRIu64 " highwater=%u"
             " stalled_init=%u paused_ready=%u barriers=%" PRIu64 " slow_calls=%" PRIu64 " stalled_call=%d"
             " batch_job=%" PRIu64 " active_ms=%" PRIu64 " call=%s call_ms=%" PRIu64
             " device_job=%" PRIu64 " call=%s call_ms=%" PRIu64
             " main=%" PRIu64 "/%" PRIu64 " initializer=%" PRIu64 "/%" PRIu64,
             allowed ? "active" : "paused", batches, objects, refs, pins, qb, qo, qr, qp,
             failed_finalizers, device_current ? device_current->destroying : 0,
             released_refs, retired_devices, device_highwater, stalled_initializers, paused_ready, barrier_recoveries,
             slow_calls, device_current ? device_current->call_stalled : 0, current ? current->id : 0,
             current ? (active_clock() - current->start) / UINT64_C(1000000) : 0,
             current && current->call ? current->call : "none",
             current && current->call ? (active_clock() - current->call_start) / UINT64_C(1000000) : 0,
             device_current ? device_current->id : 0,
             device_current && device_current->call ? device_current->call : "none",
             device_current && device_current->native_call ? (active_clock() - device_current->call_start) / UINT64_C(1000000) : 0,
             device_current ? device_current->snapshot.main_done : 0, device_current ? device_current->snapshot.main_goal : 0,
             device_current ? device_current->initializer_done : 0, device_current ? device_current->snapshot.initializer_goal : 0);
    leave();
}
