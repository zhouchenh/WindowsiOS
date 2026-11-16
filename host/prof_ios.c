/* A sampling profiler for the iOS build (host/main.c has the Mac one).
   Every guest CPU thread registers itself; a sampler thread reads each one's PC
   1000 times a second and sorts it into: asleep, in translated code, or in a host
   function (kept as an offset into the app image, symbolized afterwards with the
   unstripped binary: tools/prof_symbolize.sh). Every HV_PROF_IOS_SECS seconds
   (default 30) the totals go to stderr, which Henge mirrors to henge-native.log.
   Off unless HV_PROF_IOS is set (Documents/henge-env.txt can set it): reading a running
   thread's PC stops it for a moment, so sampling is not free. */
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../core/machine.h"
#include "winvm.h"

extern void (*hv_prof_register)(void);

#define MAX_THREADS 16
#define SLOTS 4096
static thread_act_t threads[MAX_THREADS];
static _Atomic int nthreads;
static struct { uintptr_t off; uint32_t n; } slots[SLOTS];
static uint64_t total, idle, jit, other_image, unknown;
static uintptr_t image_base;
static uint64_t t_total[MAX_THREADS], t_busy[MAX_THREADS], t_fail[MAX_THREADS]; /* per guest CPU thread */
#define OSLOTS 256
static struct { const char *name; uint32_t n; } oslots[OSLOTS]; /* samples in system libraries, by symbol */

static void reg(void) {
    int i = atomic_fetch_add(&nthreads, 1);
    if (i < MAX_THREADS) threads[i] = mach_thread_self();
}

static void count_host(uintptr_t pc) {
    Dl_info info;
    if (!dladdr((void *)pc, &info) || (uintptr_t)info.dli_fbase != image_base) {
        other_image++;
        const char *nm = info.dli_sname ? info.dli_sname : "?";
        uint32_t oh = (uint32_t)(((uintptr_t)nm >> 3) * 2654435761u) % OSLOTS;
        for (int k = 0; k < 32; k++, oh = (oh + 1) % OSLOTS) {
            if (oslots[oh].name == nm) { oslots[oh].n++; break; }
            if (!oslots[oh].n) { oslots[oh].name = nm, oslots[oh].n = 1; break; }
        }
        return;
    }
    uintptr_t off = pc - image_base;
    uint32_t h = (uint32_t)((off >> 2) * 2654435761u) % SLOTS;
    for (int k = 0; k < 64; k++, h = (h + 1) % SLOTS) {
        if (slots[h].off == off) { slots[h].n++; return; }
        if (!slots[h].n) { slots[h].off = off, slots[h].n = 1; return; }
    }
    unknown++;
}

static int by_count(const void *a, const void *b) {
    const __typeof__(slots[0]) *x = a, *y = b;
    return (int)y->n - (int)x->n;
}

static void dump(void) {
    static __typeof__(slots[0]) sorted[SLOTS];
    memcpy(sorted, slots, sizeof slots);
    qsort(sorted, SLOTS, sizeof sorted[0], by_count);
    uint64_t busy = total - idle;
    fprintf(stderr, "hvprof: %llu samples, idle %.1f%%, of busy: jit %.1f%%, other images %.1f%%, base %#lx\n",
            (unsigned long long)total, total ? 100.0 * idle / total : 0, busy ? 100.0 * jit / busy : 0,
            busy ? 100.0 * other_image / busy : 0, (unsigned long)image_base);
    for (int i = 0; i < 40 && sorted[i].n; i++)
        fprintf(stderr, "hvprof: %5.2f%% +%#lx\n", busy ? 100.0 * sorted[i].n / busy : 0, (unsigned long)sorted[i].off);
    int nt = atomic_load(&nthreads);
    fprintf(stderr, "hvprof: threads %d busy:", nt);
    for (int i = 0; i < nt && i < MAX_THREADS; i++)
        fprintf(stderr, " [%d] %.1f%%%s", i, t_total[i] ? 100.0 * t_busy[i] / t_total[i] : 0, t_fail[i] ? " (unreadable)" : "");
    fprintf(stderr, "\n");
    for (int r = 0; r < 12; r++) { /* the dozen most sampled system-library symbols */
        int best = -1;
        for (int i = 0; i < OSLOTS; i++) if (oslots[i].n && (best < 0 || oslots[i].n > oslots[best].n)) best = i;
        if (best < 0) break;
        fprintf(stderr, "hvprof: other %5.2f%% %s\n", busy ? 100.0 * oslots[best].n / busy : 0, oslots[best].name);
        oslots[best].n = 0;
    }
    memset(oslots, 0, sizeof oslots);
    memset(t_total, 0, sizeof t_total); memset(t_busy, 0, sizeof t_busy); memset(t_fail, 0, sizeof t_fail);
    memset(slots, 0, sizeof slots);
    total = idle = jit = other_image = unknown = 0;
}

static void *sampler(void *unused) {
    (void)unused;
    int secs = getenv("HV_PROF_IOS_SECS") ? atoi(getenv("HV_PROF_IOS_SECS")) : 30;
    uint64_t ticks = 0;
    for (;;) {
        usleep(1000);
        HvMachine *m = hv_winvm_machine();
        uintptr_t lo = m ? (uintptr_t)m->jit.base : 0, hi = m ? lo + m->jit.capacity * 4 : 0;
        int n = atomic_load(&nthreads);
        for (int i = 0; i < n && i < MAX_THREADS; i++) {
            thread_basic_info_data_t ti;
            mach_msg_type_number_t ni = THREAD_BASIC_INFO_COUNT;
            if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&ti, &ni) != KERN_SUCCESS) { t_fail[i]++; continue; }
            total++; t_total[i]++;
            if (ti.run_state != TH_STATE_RUNNING) { idle++; continue; }
            t_busy[i]++;
            arm_thread_state64_t st;
            mach_msg_type_number_t sn = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &sn) != KERN_SUCCESS) { unknown++; continue; }
            uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(st);
            if (pc >= lo && pc < hi) jit++;
            else count_host(pc);
        }
        if (++ticks % (uint64_t)(secs * 1000) == 0) dump();
    }
    return NULL;
}

void hv_prof_ios_start(void) {
    static int started;
    if (started++) return;
    if (!getenv("HV_PROF_IOS")) return;
    Dl_info info;
    if (dladdr((void *)hv_prof_ios_start, &info)) image_base = (uintptr_t)info.dli_fbase;
    hv_prof_register = reg;
    pthread_t t;
    pthread_create(&t, NULL, sampler, NULL);
}
