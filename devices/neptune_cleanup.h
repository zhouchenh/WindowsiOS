/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_NEPTUNE_CLEANUP_H
#define HV_NEPTUNE_CLEANUP_H

#include <stddef.h>
#include <stdint.h>

/* Only the UUID/callsite-guarded Neptune free import hook may call capture.
 * The original 40-byte object record and every COM reference it owns transfer
 * here. Capture is thread-local. Submit only from the separately validated
 * final free(ctx) callsite inside npt_context_destroy, on that same thread.
 * Public renderer destroy/reset APIs only enqueue proxy requests: their
 * return is NOT a completion barrier and must never submit a batch. */
void hv_npt_capture_object(void *record);
void hv_npt_cleanup_submit(void);
void hv_npt_cleanup_poll(void);
void hv_npt_cleanup_describe(char *buffer, size_t length);

/* Pause between backend calls when iOS disallows GPU work. An already entered
 * backend call cannot be cancelled. The five-second watchdog counts only time
 * allowed here; the waiting FIFO holds at most eight batches. */
void hv_npt_cleanup_set_active(int active);

struct HvNptDeviceSnapshot {
    uint64_t main_goal, main_done, initializer_goal;
    void *event;
};
struct HvNptDeviceOps {
    /* Exact original QI also inlines refcount increments. It runs under the
     * recursive lifetime mutex and may reenter the AddRef wrapper. */
    int32_t (*query_interface)(void *device, const void *iid, void **out);
    /* Called under the lifetime mutex at public count zero: memory reads
     * only, no driver/COM calls. The exact pinned layout must be verified. */
    int (*snapshot)(void *device, struct HvNptDeviceSnapshot *out);
    /* Called without the mutex, with a deferred private reference held. */
    int (*event_value)(void *event, uint64_t *out);
    /* Caller already set the private sentinel. Stop/join compiler workers
     * before the exact deleting destructor. Return 1 after destruction, 0
     * on failure with the sealed device/maps intact. Never free on failure. */
    int (*destroy)(void *device);
};

/* Install before patching all pinned device QI/AddRef/Release vtable slots,
 * before any backend devices exist. The wrappers serialize public/private
 * transitions, preserving one private pin for every deferred public-zero
 * epoch. Never use these on a different object layout. */
int hv_npt_cleanup_set_device_ops(const struct HvNptDeviceOps *ops);
int32_t hv_npt_device_query_interface(void *device, const void *iid, void **out);
uint32_t hv_npt_device_addref(void *device);
uint32_t hv_npt_device_release(void *device);

/* Arm captured-object releases only after all UUID/code/layout checks and
 * all three device vtable replacements succeeded. Defaults to false. */
void hv_npt_cleanup_set_backend_verified(int verified);

#endif
