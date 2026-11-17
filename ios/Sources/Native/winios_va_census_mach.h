/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_VA_CENSUS_MACH_H
#define WINIOS_VA_CENSUS_MACH_H

#include "winios_va_census.h"
#include <mach/mach.h>
#include <time.h>

/* iOS does not expose mach_vm.h. Its public vm_region_64 interface has
 * 64-bit address/size arguments on our LP64 targets. Use top-level regions:
 * submaps count as occupied, so their interior is never reported as a gap.
 * A task-wide gap does not identify the allocation range used by shared-file
 * mmap or Metal; either may fail despite a large reported gap. */
_Static_assert(sizeof(vm_address_t) == sizeof(uint64_t), "VA census requires LP64");
_Static_assert(sizeof(vm_size_t) == sizeof(uint64_t), "VA census requires LP64");
#ifndef WINIOS_VA_REGION
#define WINIOS_VA_REGION vm_region_64
#endif
#ifndef WINIOS_VA_PORT_RELEASE
#define WINIOS_VA_PORT_RELEASE mach_port_deallocate
#endif

struct WiniosVaMachContext { mach_port_t task; kern_return_t error; };
static inline int winios_va_mach_next(void *opaque, uint64_t cursor,
                                      uint64_t *start, uint64_t *length) {
    struct WiniosVaMachContext *ctx = opaque;
    vm_address_t address = cursor;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = WINIOS_VA_REGION(ctx->task, &address, &size, VM_REGION_BASIC_INFO_64,
                                       (vm_region_info_t)&info, &count, &object);
    /* Some failure paths may still return a send right. Never retain it. */
    if (MACH_PORT_VALID(object)) WINIOS_VA_PORT_RELEASE(mach_task_self(), object);
    if (kr == KERN_INVALID_ADDRESS) return 1;
    if (kr != KERN_SUCCESS) { ctx->error = kr; return -1; }
    if (count < VM_REGION_BASIC_INFO_COUNT_64) { ctx->error = KERN_INVALID_ARGUMENT; return -1; }
    *start = address; *length = size;
    return 0;
}
static inline uint64_t winios_va_mach_now(void *unused) {
    (void)unused;
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0 || ts.tv_sec < 0 || ts.tv_nsec < 0 ||
        ts.tv_nsec >= 1000000000 || (uint64_t)ts.tv_sec > (UINT64_MAX - (uint64_t)ts.tv_nsec) / UINT64_C(1000000000))
        return UINT64_MAX;
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}
static inline struct WiniosVaCensus winios_va_mach_census(uint64_t lower, uint64_t upper) {
    struct WiniosVaMachContext ctx = {.task = mach_task_self()};
    struct WiniosVaCensus result = winios_va_census(lower, upper, 2048, UINT64_C(5000000),
                                                  winios_va_mach_next, winios_va_mach_now, &ctx);
    result.query_error = ctx.error;
    return result;
}
#endif
