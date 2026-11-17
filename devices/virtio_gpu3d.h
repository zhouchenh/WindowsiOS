/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINVM_VIRTIO_GPU3D_H
#define WINVM_VIRTIO_GPU3D_H

#include <stdint.h>

#include "virtio.h"

/* 3D for virtio-gpu through virglrenderer (UTM's neptune build: D3D11 over virtio replayed on
   DXMT/Metal, plus a virgl/ANGLE context the Windows viogpu3d driver also opens). Loaded at run
   time from the app's Frameworks folder (HV_GPU3D_FRAMEWORKS); without it the device stays 2D.

   Threading: every virglrenderer call happens on one worker thread. The vCPU's queue notify only
   wakes it. Requests are taken off the control queue and completed under the device lock;
   2D requests (the boot framebuffer path) still go through virtio_gpu.c's handler. */

struct HvVirtioGpu;
typedef struct HvVgpu3d HvVgpu3d;

#define HV_VGPU3D_HOSTMEM_BAR 2

/* Memory reserved early for the hostmem window (a power of two); else it is mapped at create. */
void hv_vgpu3d_set_window(void *mem, uint64_t size);
/* Loads the libraries and starts the renderer; NULL if 3D is not available here. */
HvVgpu3d *hv_vgpu3d_create(struct HvVirtioGpu *g);
/* Feature bits to offer (VIRGL, RESOURCE_BLOB, CONTEXT_INIT) and the capset count for config. */
uint64_t hv_vgpu3d_features(HvVgpu3d *s);
uint32_t hv_vgpu3d_num_capsets(HvVgpu3d *s);
uint64_t hv_vgpu3d_hostmem_size(HvVgpu3d *s);
/* Control queue notified (vCPU thread, device lock held). */
void hv_vgpu3d_kick(HvVgpu3d *s);
/* Cursor queue: show the image in this resource as the hardware cursor (fetched on the worker thread). */
void hv_vgpu3d_cursor(HvVgpu3d *s, uint32_t res);
/* Driver reset (device lock held): drops in-flight requests; the renderer resets on the worker. */
void hv_vgpu3d_reset(HvVgpu3d *s);
/* What the renderer holds when a driver reset comes (worker thread). A reset of a renderer that did nothing since its
   last reset is skipped (no virgl_renderer_reset, so no Metal work): driver resets in 2D, which may come while the
   app is in the background, never touch the GPU. */
typedef struct {
    int used;          /* a command or a cursor read-back since the last reset */
    uint32_t live_ctxs, resources, scanout, parked;
} HvVgpu3dUse;
static inline int hv_vgpu3d_reset_needed(const HvVgpu3dUse *u) {
    return u->used || u->live_ctxs || u->resources || u->scanout || u->parked;
}
/* Background drain. In the background iOS refuses every Metal command buffer, and a fence signalled inside one (DXMT's
   event queries, vrend's GL fences through ANGLE) never retires: Windows would wait on it for good (DWM, a display
   driver unloading during a switch to 2D). While drain is on, the worker answers a fence itself once it has been
   parked for the grace period, counted from when it was parked or from when drain went on, whichever is later (work
   committed just before the app left gets that long to retire as usual). Every answer it gives is counted and the
   first ones are logged. Off again (the app back in front): fences wait for the renderer as before. A driver reset
   drops whatever is parked either way; the setting itself stays until the app changes it. Any thread. */
void hv_vgpu3d_set_background(HvVgpu3d *s, int on);

#define HV_VGPU3D_DRAIN_GRACE_NS (250ull * 1000000ull)
typedef struct {
    int on;
    uint64_t since_ns; /* when it went on (CLOCK_MONOTONIC) */
    uint64_t grace_ns; /* 0: HV_VGPU3D_DRAIN_GRACE_NS */
} HvVgpu3dDrain;
static inline void hv_vgpu3d_drain_set(HvVgpu3dDrain *d, int on, uint64_t now_ns) {
    on = on != 0;
    if (on && !d->on) d->since_ns = now_ns; /* on again while on: the first moment counts */
    d->on = on;
}
/* When drain answers a fence parked at parked_ns; UINT64_MAX: never (drain is off). */
static inline uint64_t hv_vgpu3d_drain_due_at(const HvVgpu3dDrain *d, uint64_t parked_ns) {
    if (!d->on) return UINT64_MAX;
    uint64_t grace = d->grace_ns ? d->grace_ns : HV_VGPU3D_DRAIN_GRACE_NS;
    uint64_t from = parked_ns > d->since_ns ? parked_ns : d->since_ns;
    return from > UINT64_MAX - grace ? UINT64_MAX - 1 : from + grace;
}
static inline int hv_vgpu3d_drain_due(const HvVgpu3dDrain *d, uint64_t parked_ns, uint64_t now_ns) {
    return d->on && hv_vgpu3d_drain_due_at(d, parked_ns) <= now_ns;
}

/* PCI config written: (re)place the hostmem window where the BAR now points. */
void hv_vgpu3d_bar_update(HvVgpu3d *s);
int hv_vgpu3d_describe(HvVgpu3d *s, char *buf, unsigned len);

#endif
