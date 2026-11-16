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
/* PCI config written: (re)place the hostmem window where the BAR now points. */
void hv_vgpu3d_bar_update(HvVgpu3d *s);
int hv_vgpu3d_describe(HvVgpu3d *s, char *buf, unsigned len);

#endif
