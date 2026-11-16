#ifndef WINVM_FB_DISPLAY_H
#define WINVM_FB_DISPLAY_H

#include <pthread.h>
#include <stdint.h>

#include "fw_cfg.h"
#include "machine.h"
#include "pcie.h"

/* Linear framebuffer display supporting QEMU `ramfb` (etc/ramfb in fw_cfg, used by
   EDK2 ArmVirtQemu GOP -> winload.efi -> Windows 11 BasicDisplay.sys + DWM)
   as well as optional VBE/bochs scanout. Zero MMIO exits per pixel write! */

typedef struct HvFbDisplay {
    HvMachine *m;
    pthread_mutex_t mu;

    /* Active scanout geometry (protected by mu) */
    uint64_t fb_pa;
    const uint8_t *fb_host;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t fourcc; /* DRM fourcc, e.g. XR24 / AR24 (32-bit BGRX) */
    int active;

    /* virtio-gpu scanout (host memory owned by the GPU device); shown instead of ramfb while set */
    const uint8_t *ovr_host;
    uint32_t ovr_width, ovr_height, ovr_stride;
    uint64_t ovr_serial; /* bumped on every flush so the presenter re-uploads */
    /* Which source changed last wins (ramfb is sampled; the override counts flushes). */
    uint64_t clock, ramfb_hash, ramfb_stamp, ovr_seen, ovr_stamp;
    int force; /* debugging: 0 auto, 1 always ramfb, 2 always the virtio-gpu scanout */

    /* virtio-gpu 3D scanout: a Metal texture (id<MTLTexture>, retained here) shown as is, the
       rect (x, y, w, h) of it. Takes precedence over both pixel sources while set. */
    void *ovr_tex;
    uint32_t ovr_tex_w, ovr_tex_h, ovr_rx, ovr_ry, ovr_rw, ovr_rh;

    /* Hardware cursor (virtio-gpu cursor queue), drawn by the presenter over the scanout. Linux
       guests put the pointer here instead of into their frames. Under mu. */
    uint32_t cur_px[64 * 64]; /* BGRA, premultiplied alpha */
    uint32_t cur_w, cur_h;
    int32_t cur_x, cur_y;     /* top-left corner of the image, in scanout pixels (may be negative) */
    int cur_visible;
    uint64_t cur_img_serial;  /* bumped when the image changes */
    uint64_t cur_serial;      /* bumped on any change (image, position, visibility) */

    /* Metal presenter handle (created lazily by fb_metal.m) */
    void *metal;
} HvFbDisplay;

HvFbDisplay *hv_fb_display_create(HvMachine *m, HvFwCfg *fw_cfg);
/* Thread-safe snapshot of current scanout pointer and dimensions; returns 0 if active, -1 if not yet set. */
int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride);
/* Show a host-memory scanout (virtio-gpu) instead of ramfb; pixels NULL goes back to ramfb.
   The memory must stay valid until the next call that replaces it (plus a presenter frame). */
void hv_fb_display_set_override(HvFbDisplay *fb, const uint8_t *pixels, uint32_t w, uint32_t h, uint32_t stride);
void hv_fb_display_override_flushed(HvFbDisplay *fb);
/* Show a Metal texture (retained; NULL clears). Rect is the visible part. */
void hv_fb_display_set_texture(HvFbDisplay *fb, void *mtl_texture, uint32_t tex_w, uint32_t tex_h, uint32_t rx,
                               uint32_t ry, uint32_t rw, uint32_t rh);
/* 0 and a retained texture (the caller releases it with CFRelease) if one is shown. */
int hv_fb_display_get_texture(HvFbDisplay *fb, void **tex, uint32_t *tex_w, uint32_t *tex_h, uint32_t *rx,
                              uint32_t *ry, uint32_t *rw, uint32_t *rh);

/* Hardware cursor: a new image (BGRA premultiplied, at most 64x64; NULL hides it), a new position.
   get copies the image out when its serial differs from *img_serial; returns 1 if a cursor is shown. */
void hv_fb_display_cursor_image(HvFbDisplay *fb, const uint32_t *px, uint32_t w, uint32_t h);
void hv_fb_display_cursor_move(HvFbDisplay *fb, int32_t x, int32_t y);
int hv_fb_display_cursor_get(HvFbDisplay *fb, uint32_t *px, uint64_t *img_serial, uint32_t *w, uint32_t *h,
                             int32_t *x, int32_t *y, uint64_t *serial);

/* Metal layer presentation & PNG screenshot helpers (implemented in devices/fb_metal.m) */
void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer);
/* Refresh rate of the presented frames (default 60): set any time, global. */
void hv_fb_metal_set_fps(int fps);
int hv_fb_metal_fps(void);
/* Pan/zoom of the shown picture (keyboard pan, viewport zoom): zoom >= 1 about the drawable's centre, then
   moved by (tx, ty) as fractions of the drawable (y down). 1, 0, 0 = as fitted. Any thread. */
void hv_fb_metal_set_view_transform(float zoom, float tx, float ty);
uint64_t hv_fb_metal_frames(HvFbDisplay *fb);
int hv_fb_save_png(HvFbDisplay *fb, const char *path);

#endif
