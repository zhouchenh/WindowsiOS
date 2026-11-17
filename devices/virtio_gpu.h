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
    uint64_t base_features;     /* offered without 3D */
    int offer3d;                /* the next driver start is offered 3D (VIRGL, blobs, context init) */
    uint32_t mode_switches;     /* hv_virtio_gpu_set_3d calls that changed the offer */
} HvVirtioGpu;

/* The graphics mode: what the device offers the next time a driver starts, and what the running driver took. */
typedef struct HvVgpuMode {
    int capable;     /* the 3D renderer is loaded: 3D can be offered (it stays loaded, idle while 2D) */
    int offered3d;   /* the next driver start negotiates 3D */
    int negotiated3d; /* the driver running now took VIRGL */
    int driver_ok;   /* a driver runs (DRIVER_OK) */
    uint32_t resets; /* driver resets since the machine started: a new driver start moves it on */
    uint32_t switches;
} HvVgpuMode;

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb, uint32_t pref_w, uint32_t pref_h);
/* New preferred display size from the host (e.g. the iPad screen): raises a display event. */
void hv_virtio_gpu_set_preferred(HvVirtioGpu *g, uint32_t w, uint32_t h);
/* One-line status for diagnostics (driver stage, scanout, counters). */
int hv_virtio_gpu_describe(HvVirtioGpu *g, char *buf, unsigned len);
/* The 2D request handler (display info, EDID and the 2D resource path); g->mu held. */
uint32_t hv_virtio_gpu_handle2d(HvVirtioGpu *g, const HvVirtqElem *e, uint8_t *resp, uint32_t resp_cap);
/* Machine reset: drop every resource and give the screen back to ramfb. The offered mode stays. */
void hv_virtio_gpu_reset(HvVirtioGpu *g);
/* Offer 3D (1) or plain 2D (0) from the next driver start on: device features are read at every driver
   initialisation, so a guest that restarts its display adapter (or reboots) takes the new mode without the machine
   restarting. The running driver is not touched. 0, or -1 when 3D is asked for and the renderer is not loaded.
   Any thread. */
int hv_virtio_gpu_set_3d(HvVirtioGpu *g, int on);
void hv_virtio_gpu_mode(HvVirtioGpu *g, HvVgpuMode *out);
/* The app is in the background (1) or back in front (0): the 3D renderer answers parked fences itself after a grace
   period while in the background (hv_vgpu3d_set_background). No-op without the renderer. Any thread. */
void hv_virtio_gpu_set_background(HvVirtioGpu *g, int on);

#endif
