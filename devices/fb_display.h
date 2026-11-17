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
/* Clears the override only if it still shows these pixels (someone else may have set their own since). */
void hv_fb_display_clear_override_if(HvFbDisplay *fb, const uint8_t *pixels);
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

/* Presentation engine controls (one presenter per process; set from any thread). */
/* Hold the last good frame: frames of another size are not shown until one of w x h arrives, or ms have
   passed (then the newest frame is shown letterboxed). w == 0 (or ms == 0) ends a hold. */
void hv_fb_metal_hold_for_size(uint32_t w, uint32_t h, uint32_t ms);
/* Called (on the presenter's thread) when a hold ends by itself: a frame of its size came, or its deadline
   passed, frame or no frame. Not for hv_fb_metal_hold_for_size's own clearing. */
void hv_fb_metal_set_hold_end_handler(void (*fn)(void *opaque), void *opaque);
/* Touch, key or pointer input: the display link goes back to its full rate at once (idle throttling). */
void hv_fb_metal_note_input(void);
/* 1: the former placement (aspect fit, linear filtering) for HV_DISPLAY_LEGACY; 0: whole-pixel placement,
   nearest sampling at integer scales. */
void hv_fb_metal_set_legacy_fit(int legacy);

typedef struct HvFbMetalStats {
    uint64_t frames;       /* frames presented */
    uint64_t ticks;        /* display-link callbacks */
    uint64_t held;         /* frames not shown while holding for a new size */
    uint64_t cpu_ns;       /* presenter thread CPU time */
    uint64_t upload_bytes; /* guest pixels copied into textures */
    int link_hz;           /* the display link's current preferred rate */
    int idle;              /* throttled: no new guest frame and no input for a while */
    int nearest;           /* the last frame was drawn at an integer scale with nearest sampling */
    int holding;           /* a hold for a new size is in effect */
    uint32_t src_w, src_h; /* the last frame */
    uint32_t dst_w, dst_h; /* the drawable it went to */
    uint32_t scale_x100;   /* the last frame's on-screen scale (drawable pixels per guest pixel) x 100 */
} HvFbMetalStats;
void hv_fb_metal_get_stats(HvFbMetalStats *out);
/* Save the active scanout, logging source/serial/size/error (identical repeats
   are suppressed). An active 3D
   readback failure returns -1; it never substitutes an older CPU framebuffer. */
int hv_fb_save_png(HvFbDisplay *fb, const char *path);
/* A copy of the screen as it is shown now, the hardware cursor blended in: BGRA, opaque, rows of *w * 4 bytes,
   malloc'd (the caller frees it). allow_gpu 0 never touches the GPU: NULL while the screen is a 3D (Metal) texture.
   1 reads a 3D texture with one blit, which only works while the app may use the GPU (in front, or merely inactive:
   never in the background); NULL when that fails. 2 explicitly permits falling back to the 2D pixels when the
   blit fails. Any thread; NULL when there is no picture. */
uint8_t *hv_fb_metal_snapshot(HvFbDisplay *fb, int allow_gpu, uint32_t *w, uint32_t *h);
/* A value that changes whenever the picture does (a 3D frame, a 2D flush or ramfb change, the cursor): sampled, cheap.
   0: no picture. *is_texture (may be NULL): the screen is a 3D texture now. */
uint64_t hv_fb_metal_screen_serial(HvFbDisplay *fb, int *is_texture);
/* Paused, nothing is presented (the display link stops): the app in the background, where iOS refuses GPU work.
   Resumed, the next tick draws the current frame again. NULL fb: only the global flag. Any thread. */
void hv_fb_metal_set_paused(HvFbDisplay *fb, int paused);

#endif
