#include <CoreFoundation/CoreFoundation.h>
#include "fb_display.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* RAMFBCfg written by EDK2 QemuRamFbDxe via fw_cfg DMA to "etc/ramfb" (28 bytes, big-endian):
   struct RAMFBCfg {
       uint64_t addr;
       uint32_t fourcc;
       uint32_t flags;
       uint32_t width;
       uint32_t height;
       uint32_t stride;
   } __attribute__((packed));
*/

static uint32_t be32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return __builtin_bswap32(v);
}

static uint64_t be64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return __builtin_bswap64(v);
}

static void on_ramfb_write(void *opaque, const uint8_t *data, uint32_t len) {
    HvFbDisplay *fb = opaque;
    if (len < 28) return;

    uint64_t addr = be64(data + 0);
    uint32_t fourcc = be32(data + 8);
    uint32_t width = be32(data + 16);
    uint32_t height = be32(data + 20);
    uint32_t stride = be32(data + 24);

    if (width < 64 || width > 8192 || height < 64 || height > 8192) return;
    if (stride == 0) stride = width * 4;
    if (stride < width * 2 || stride > 65536) return;

    uint64_t total_bytes = (uint64_t)stride * (height - 1) + (uint64_t)width * 4;
    void *host_ptr = hv_phys_ptr(fb->m, addr, total_bytes);
    if (!host_ptr) {
        fprintf(stderr, "winvm: ramfb ignored invalid PA 0x%llx (%ux%u stride %u)\n",
                (unsigned long long)addr, width, height, stride);
        return;
    }

    pthread_mutex_lock(&fb->mu);
    fb->fb_pa = addr;
    fb->fb_host = (const uint8_t *)host_ptr;
    fb->width = width;
    fb->height = height;
    fb->stride = stride;
    fb->fourcc = fourcc;
    fb->active = 1;
    pthread_mutex_unlock(&fb->mu);

    fprintf(stderr, "winvm: ramfb configured %ux%u stride=%u fourcc=0x%08x at PA 0x%llx\n",
            width, height, stride, fourcc, (unsigned long long)addr);
}

HvFbDisplay *hv_fb_display_create(HvMachine *m, HvFwCfg *fw_cfg) {
    HvFbDisplay *fb = calloc(1, sizeof *fb);
    fb->m = m;
    pthread_mutex_init(&fb->mu, NULL);
    if (fw_cfg) {
        hv_fw_cfg_add_writable_file(fw_cfg, "etc/ramfb", 28, on_ramfb_write, fb);
    }
    return fb;
}

/* Returns 0 for an all-black frame (as far as the samples see): Windows blanks a display it
   stops using, and that should not count as that display coming back to life. */
static uint64_t sample_hash(const uint8_t *px, uint32_t w, uint32_t h, uint32_t stride) {
    uint64_t hash = ((uint64_t)w << 32) ^ h ^ stride, any = 0;
    uint32_t step_y = h > 96 ? h / 96 : 1;
    for (uint32_t y = 0; y < h; y += step_y) {
        const uint64_t *row = (const uint64_t *)(px + (size_t)y * stride);
        uint32_t qwords = (w * 4) / 8;
        uint32_t step_x = qwords > 48 ? qwords / 48 : 1;
        for (uint32_t x = 0; x < qwords; x += step_x) {
            any |= row[x] & 0x00ffffff00ffffffull; /* ignore the X/alpha byte */
            hash = (hash ^ row[x]) * 0x9e3779b97f4a7c15ull;
        }
    }
    if (!any) return 0;
    return hash ? hash : 1;
}

/* Both ramfb (firmware GOP, Windows Basic Display, boot screens) and the virtio-gpu scanout
   (UEFI VirtioGpuDxe, viogpudo) may be set at once: show the one that changed most recently. */
int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride) {
    if (!fb) return -1;
    pthread_mutex_lock(&fb->mu);
    int ramfb_ok = fb->active && fb->fb_host && fb->width && fb->height;
    int ovr_ok = fb->ovr_host && fb->ovr_width && fb->ovr_height;
    if (ramfb_ok && ovr_ok) {
        uint64_t hv = sample_hash(fb->fb_host, fb->width, fb->height, fb->stride);
        if (hv && hv != fb->ramfb_hash) {
            fb->ramfb_hash = hv;
            fb->ramfb_stamp = ++fb->clock;
        }
        uint64_t serial = __atomic_load_n(&fb->ovr_serial, __ATOMIC_RELAXED);
        if (serial != fb->ovr_seen) {
            fb->ovr_seen = serial;
            fb->ovr_stamp = ++fb->clock;
        }
        if (fb->ramfb_stamp > fb->ovr_stamp) ovr_ok = 0;
    }
    if (fb->force == 1 && ramfb_ok) ovr_ok = 0;
    if (fb->force == 2 && ovr_ok) ramfb_ok = 0;
    if (ovr_ok) {
        *pixels = fb->ovr_host;
        *w = fb->ovr_width;
        *h = fb->ovr_height;
        *stride = fb->ovr_stride;
        pthread_mutex_unlock(&fb->mu);
        return 0;
    }
    if (!ramfb_ok) {
        pthread_mutex_unlock(&fb->mu);
        return -1;
    }
    *pixels = fb->fb_host;
    *w = fb->width;
    *h = fb->height;
    *stride = fb->stride;
    pthread_mutex_unlock(&fb->mu);
    return 0;
}

void hv_fb_display_set_override(HvFbDisplay *fb, const uint8_t *pixels, uint32_t w, uint32_t h, uint32_t stride) {
    if (!fb) return;
    pthread_mutex_lock(&fb->mu);
    fb->ovr_host = pixels;
    fb->ovr_width = pixels ? w : 0;
    fb->ovr_height = pixels ? h : 0;
    fb->ovr_stride = pixels ? stride : 0;
    fb->ovr_serial++;
    pthread_mutex_unlock(&fb->mu);
}

void hv_fb_display_set_texture(HvFbDisplay *fb, void *mtl_texture, uint32_t tex_w, uint32_t tex_h, uint32_t rx,
                               uint32_t ry, uint32_t rw, uint32_t rh) {
    if (!fb) return;
    if (mtl_texture) CFRetain(mtl_texture);
    pthread_mutex_lock(&fb->mu);
    void *old = fb->ovr_tex;
    fb->ovr_tex = mtl_texture;
    fb->ovr_tex_w = tex_w;
    fb->ovr_tex_h = tex_h;
    if (!rw || !rh || rx + rw > tex_w || ry + rh > tex_h) rx = 0, ry = 0, rw = tex_w, rh = tex_h;
    fb->ovr_rx = rx;
    fb->ovr_ry = ry;
    fb->ovr_rw = rw;
    fb->ovr_rh = rh;
    fb->ovr_serial++;
    pthread_mutex_unlock(&fb->mu);
    if (old) CFRelease(old);
}

int hv_fb_display_get_texture(HvFbDisplay *fb, void **tex, uint32_t *tex_w, uint32_t *tex_h, uint32_t *rx,
                              uint32_t *ry, uint32_t *rw, uint32_t *rh) {
    if (!fb) return -1;
    pthread_mutex_lock(&fb->mu);
    if (!fb->ovr_tex || fb->force == 1) {
        pthread_mutex_unlock(&fb->mu);
        return -1;
    }
    *tex = fb->ovr_tex;
    CFRetain(*tex);
    *tex_w = fb->ovr_tex_w;
    *tex_h = fb->ovr_tex_h;
    *rx = fb->ovr_rx;
    *ry = fb->ovr_ry;
    *rw = fb->ovr_rw;
    *rh = fb->ovr_rh;
    pthread_mutex_unlock(&fb->mu);
    return 0;
}

void hv_fb_display_override_flushed(HvFbDisplay *fb) {
    if (fb) __atomic_add_fetch(&fb->ovr_serial, 1, __ATOMIC_RELAXED);
}

void hv_fb_display_cursor_image(HvFbDisplay *fb, const uint32_t *px, uint32_t w, uint32_t h) {
    if (!fb) return;
    if (w > 64) w = 64;
    if (h > 64) h = 64;
    pthread_mutex_lock(&fb->mu);
    if (px && w && h) {
        memcpy(fb->cur_px, px, (size_t)w * h * 4);
        fb->cur_w = w, fb->cur_h = h;
        fb->cur_visible = 1;
        fb->cur_img_serial++;
    } else {
        fb->cur_visible = 0;
    }
    fb->cur_serial++;
    pthread_mutex_unlock(&fb->mu);
}

void hv_fb_display_cursor_move(HvFbDisplay *fb, int32_t x, int32_t y) {
    if (!fb) return;
    pthread_mutex_lock(&fb->mu);
    if (fb->cur_x != x || fb->cur_y != y) {
        fb->cur_x = x, fb->cur_y = y;
        fb->cur_serial++;
    }
    pthread_mutex_unlock(&fb->mu);
}

int hv_fb_display_cursor_get(HvFbDisplay *fb, uint32_t *px, uint64_t *img_serial, uint32_t *w, uint32_t *h,
                             int32_t *x, int32_t *y, uint64_t *serial) {
    if (!fb) return 0;
    pthread_mutex_lock(&fb->mu);
    int vis = fb->cur_visible;
    if (px && img_serial && *img_serial != fb->cur_img_serial) {
        memcpy(px, fb->cur_px, (size_t)fb->cur_w * fb->cur_h * 4);
        *img_serial = fb->cur_img_serial;
    }
    if (w) *w = fb->cur_w;
    if (h) *h = fb->cur_h;
    if (x) *x = fb->cur_x;
    if (y) *y = fb->cur_y;
    if (serial) *serial = fb->cur_serial;
    pthread_mutex_unlock(&fb->mu);
    return vis;
}
