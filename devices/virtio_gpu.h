/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINVM_VIRTIO_GPU_H
#define WINVM_VIRTIO_GPU_H

#include <pthread.h>
#include <stdint.h>

#include "fb_display.h"
#include "virtio.h"

/* virtio-gpu (2D only, one scanout) for the Red Hat viogpudo Windows driver and
   EDK2 VirtioGpuDxe. Resources live in host memory; TRANSFER_TO_HOST_2D copies
   from the guest backing pages, and the scanout resource is shown through
   HvFbDisplay's override in place of ramfb. The host's preferred size is
   reported in GET_DISPLAY_INFO / GET_EDID and can change at run time. */

#define HV_VGPU_MAX_RES 256

typedef struct HvVgpuBacking {
    uint64_t addr;
    uint32_t len;
} HvVgpuBacking;

typedef struct HvVgpuRes {
    uint32_t id, format, width, height, stride;
    uint8_t *pixels;            /* host copy, stride * height */
    HvVgpuBacking *backing;
    uint32_t nbacking;
} HvVgpuRes;

struct HvVgpu3d;

typedef struct HvVirtioGpu {
    HvVirtio vio;
    struct HvVgpu3d *g3d;       /* virglrenderer 3D, when available (virtio_gpu3d.c) */
    HvFbDisplay *fb;
    pthread_mutex_t mu;
    HvVgpuRes res[HV_VGPU_MAX_RES];
    uint32_t scanout_res;       /* resource on scanout 0, 0 = none */
    uint32_t pref_w, pref_h;    /* host preferred mode */
    uint8_t *graveyard[8];      /* freed scanout buffers, released a few frees later */
    uint32_t grave_next;
    uint64_t cmds, flushes;
    uint32_t resets;            /* driver resets since machine reset: <= 1 is still the UEFI driver */
    uint64_t edid_reqs, info_reqs;
    uint32_t info_w, info_h;    /* last size reported in GET_DISPLAY_INFO */
} HvVirtioGpu;

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb, uint32_t pref_w, uint32_t pref_h);
/* New preferred display size from the host (e.g. the iPad screen): raises a display event. */
void hv_virtio_gpu_set_preferred(HvVirtioGpu *g, uint32_t w, uint32_t h);
/* One-line status for diagnostics (driver stage, scanout, counters). */
int hv_virtio_gpu_describe(HvVirtioGpu *g, char *buf, unsigned len);
/* The 2D request handler (display info, EDID and the 2D resource path); g->mu held. */
uint32_t hv_virtio_gpu_handle2d(HvVirtioGpu *g, const HvVirtqElem *e, uint8_t *resp, uint32_t resp_cap);
/* Machine reset: drop every resource and give the screen back to ramfb. */
void hv_virtio_gpu_reset(HvVirtioGpu *g);

#endif
