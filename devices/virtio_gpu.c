/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "virtio_gpu.h"
#include "virtio_gpu3d.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* virtio 1.x spec, 5.7 GPU device. Little-endian structs. */
#define CTRLQ 0
#define CURSORQ 1

#define F_EDID (1ull << 1)
#define F_VIRGL (1ull << 0)

#define CMD_GET_DISPLAY_INFO 0x0100
#define CMD_RESOURCE_CREATE_2D 0x0101
#define CMD_RESOURCE_UNREF 0x0102
#define CMD_SET_SCANOUT 0x0103
#define CMD_RESOURCE_FLUSH 0x0104
#define CMD_TRANSFER_TO_HOST_2D 0x0105
#define CMD_RESOURCE_ATTACH_BACKING 0x0106
#define CMD_RESOURCE_DETACH_BACKING 0x0107
#define CMD_GET_CAPSET_INFO 0x0108
#define CMD_GET_EDID 0x010a
#define CMD_UPDATE_CURSOR 0x0300
#define CMD_MOVE_CURSOR 0x0301

#define RESP_OK_NODATA 0x1100
#define RESP_OK_DISPLAY_INFO 0x1101
#define RESP_OK_EDID 0x1104
#define RESP_ERR_UNSPEC 0x1200
#define RESP_ERR_OUT_OF_MEMORY 0x1201
#define RESP_ERR_INVALID_SCANOUT_ID 0x1202
#define RESP_ERR_INVALID_RESOURCE_ID 0x1203
#define RESP_ERR_INVALID_PARAMETER 0x1205

#define FLAG_FENCE 1u
#define EVENT_DISPLAY 1u

#define HDR 24
#define MAX_DIM 8192
#define MAX_BACKING 65536

typedef struct {
    uint32_t type, flags;
    uint64_t fence_id;
    uint32_t ctx_id;
    uint32_t padding;
} Hdr;

typedef struct {
    uint32_t x, y, w, h;
} Rect;

static int gpu_log = -1;
#define LOG(...)                                                    \
    do {                                                            \
        if (gpu_log < 0) gpu_log = getenv("HV_GPU_LOG") != NULL;    \
        if (gpu_log) fprintf(stderr, "virtio-gpu: " __VA_ARGS__);   \
    } while (0)

static HvVgpuRes *find(HvVirtioGpu *g, uint32_t id) {
    if (!id) return NULL;
    for (int i = 0; i < HV_VGPU_MAX_RES; i++)
        if (g->res[i].id == id) return &g->res[i];
    return NULL;
}

/* A freed buffer may still be in the presenter's hands for one frame: keep it a little longer. */
static void bury(HvVirtioGpu *g, uint8_t *p) {
    if (!p) return;
    uint32_t i = g->grave_next++ % 8;
    free(g->graveyard[i]);
    g->graveyard[i] = p;
}

static void show_scanout(HvVirtioGpu *g) {
    HvVgpuRes *r = find(g, g->scanout_res);
    if (r && r->pixels) hv_fb_display_set_override(g->fb, r->pixels, r->width, r->height, r->stride);
    else hv_fb_display_set_override(g->fb, NULL, 0, 0, 0);
}

static void destroy(HvVirtioGpu *g, HvVgpuRes *r) {
    if (r->id == g->scanout_res) {
        g->scanout_res = 0;
        show_scanout(g);
    }
    bury(g, r->pixels);
    free(r->backing);
    memset(r, 0, sizeof *r);
}

static void drop_all(HvVirtioGpu *g) {
    g->scanout_res = 0;
    hv_fb_display_set_override(g->fb, NULL, 0, 0, 0);
    hv_fb_display_cursor_image(g->fb, NULL, 0, 0);
    for (int i = 0; i < HV_VGPU_MAX_RES; i++)
        if (g->res[i].id) destroy(g, &g->res[i]);
}

/* EDID 1.4: the preferred mode (any size, e.g. the iPad screen) as the first detailed timing,
   plus common modes as established and standard timings, which is where viogpudo builds its
   Display Settings list from (standard timings only carry 16:10, 4:3, 5:4 and 16:9). */
static void std_timing(uint8_t *d, uint32_t w, int aspect /* 0 16:10, 1 4:3, 2 5:4, 3 16:9 */) {
    d[0] = (uint8_t)(w / 8 - 31);
    d[1] = (uint8_t)(aspect << 6 | (60 - 60));
}

static void make_edid(uint8_t e[128], uint32_t w, uint32_t h) {
    memset(e, 0, 128);
    static const uint8_t header[8] = {0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0};
    memcpy(e, header, 8);
    uint16_t mfg = (uint16_t)((('W' - '@') << 10) | (('I' - '@') << 5) | ('N' - '@')); /* "WIN" */
    e[8] = (uint8_t)(mfg >> 8);
    e[9] = (uint8_t)mfg;
    e[10] = 0x01; /* product */
    e[16] = 1;    /* week */
    e[17] = 36;   /* 2026 */
    e[18] = 1;
    e[19] = 4;    /* EDID 1.4 */
    e[20] = 0xa5; /* digital, 8 bits per colour, DisplayPort */
    e[21] = 23;   /* ~23 x 16 cm: an 11" tablet */
    e[22] = 16;
    e[23] = 120;  /* gamma 2.2 */
    e[24] = 0x06; /* sRGB default, preferred timing is native, RGB 4:4:4 */
    static const uint8_t chroma[10] = {0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54};
    memcpy(e + 25, chroma, 10);
    e[35] = 0x21; /* established: 640x480@60, 800x600@60 */
    e[36] = 0x08; /* 1024x768@60 */
    uint8_t *st = e + 38;
    std_timing(st + 0, 1280, 0);  /* 1280x800 */
    std_timing(st + 2, 1440, 0);  /* 1440x900 */
    std_timing(st + 4, 1680, 0);  /* 1680x1050 */
    std_timing(st + 6, 1920, 0);  /* 1920x1200 */
    std_timing(st + 8, 1280, 1);  /* 1280x960 */
    std_timing(st + 10, 1600, 1); /* 1600x1200 */
    std_timing(st + 12, 1920, 3); /* 1920x1080 */
    std_timing(st + 14, 2048, 1); /* 2048x1536 */
    /* detailed timing 1: preferred mode, reduced blanking, at the app's refresh rate (HV_DISPLAY_HZ,
       Settings > Refresh rate; 60 by default). A rate whose pixel clock an EDID cannot hold (above
       655 MHz: very large modes at 120 Hz) falls back to 60. */
    uint32_t hb = 160, vb = 30, hso = 48, hsw = 32, vso = 3, vsw = 6;
    uint32_t hz = getenv("HV_DISPLAY_HZ") ? (uint32_t)atoi(getenv("HV_DISPLAY_HZ")) : 60;
    if (hz < 24 || hz > 240) hz = 60;
    uint64_t clk64 = ((uint64_t)(w + hb) * (h + vb) * hz) / 10000; /* 10 kHz units */
    if (clk64 > 0xffff) {
        hz = 60;
        clk64 = ((uint64_t)(w + hb) * (h + vb) * hz) / 10000;
    }
    uint32_t clk = clk64 > 0xffff ? 0xffff : (uint32_t)clk64;
    uint8_t *d = e + 54;
    d[0] = (uint8_t)clk;
    d[1] = (uint8_t)(clk >> 8);
    d[2] = (uint8_t)w;
    d[3] = (uint8_t)hb;
    d[4] = (uint8_t)(((w >> 8) & 0xf) << 4 | ((hb >> 8) & 0xf));
    d[5] = (uint8_t)h;
    d[6] = (uint8_t)vb;
    d[7] = (uint8_t)(((h >> 8) & 0xf) << 4 | ((vb >> 8) & 0xf));
    d[8] = (uint8_t)hso;
    d[9] = (uint8_t)hsw;
    d[10] = (uint8_t)((vso & 0xf) << 4 | (vsw & 0xf));
    d[11] = (uint8_t)(((hso >> 8) & 3) << 6 | ((hsw >> 8) & 3) << 4 | ((vso >> 4) & 3) << 2 | ((vsw >> 4) & 3));
    d[12] = 230 & 0xff; /* image size 230 x 160 mm */
    d[13] = 160;
    d[14] = 0;
    d[17] = 0x1e; /* digital separate sync, +h +v */
    /* monitor name */
    uint8_t *n = e + 72;
    n[3] = 0xfc;
    memcpy(n + 5, "WindowsiOS\n  ", 13);
    /* range limits: 24 Hz up to the mode's rate (at least 75) vertical, 30-255 kHz horizontal, max clock in 10 MHz units */
    uint8_t *rl = e + 90;
    rl[3] = 0xfd;
    rl[5] = 24; rl[6] = (uint8_t)(hz > 75 ? hz : 75); rl[7] = 30; rl[8] = 255;
    uint32_t mhz10 = clk / 1000 + 1;
    rl[9] = (uint8_t)(mhz10 > 255 ? 255 : mhz10);
    rl[10] = 0x01; /* range limits only */
    rl[11] = 0x0a;
    memset(rl + 12, 0x20, 6);
    uint8_t *x = e + 108; /* dummy descriptor */
    x[3] = 0x10;
    uint8_t sum = 0;
    for (int i = 0; i < 127; i++) sum += e[i];
    e[127] = (uint8_t)(0x100 - sum);
}

/* Copy `len` bytes at byte offset `off` of the resource's backing into dst. */
static int backing_read(HvVirtioGpu *g, HvVgpuRes *r, uint64_t off, uint8_t *dst, uint32_t len) {
    uint64_t base = 0;
    for (uint32_t i = 0; i < r->nbacking && len; i++) {
        uint64_t elen = r->backing[i].len;
        if (off >= base + elen) {
            base += elen;
            continue;
        }
        uint64_t in = off - base;
        uint32_t n = (uint32_t)(elen - in < len ? elen - in : len);
        uint8_t *src = hv_phys_ptr(g->vio.m, r->backing[i].addr + in, n);
        if (!src) return -1;
        memcpy(dst, src, n);
        dst += n;
        len -= n;
        off += n;
        base += elen;
    }
    return len ? -1 : 0;
}

/* UEFI (VirtioGpuDxe) and ramfb both drive the firmware console, which picks a mode both
   offer; a preferred size ramfb lacks leaves only 640x480 for both, and Windows' Basic
   Display then starts at 640x480. So until the OS driver takes over (after the firmware's
   reset at ExitBootServices), report the ramfb size. */
static void guest_mode(HvVirtioGpu *g, uint32_t *w, uint32_t *h) {
    /* The 3D driver (viogpu3d) negotiates VIRGL, which the firmware's driver never does. */
    if (g->resets <= 1 && !(g->vio.driver_features & F_VIRGL)) {
        uint32_t fw = 1210, fh = 834;
        HvFbDisplay *fb = g->fb;
        if (fb) {
            pthread_mutex_lock(&fb->mu);
            if (fb->active && fb->width >= 640 && fb->height >= 480) {
                fw = fb->width;
                fh = fb->height;
            }
            pthread_mutex_unlock(&fb->mu);
        }
        *w = fw;
        *h = fh;
        return;
    }
    *w = g->pref_w;
    *h = g->pref_h;
}

uint32_t hv_virtio_gpu_handle2d(HvVirtioGpu *g, const HvVirtqElem *e, uint8_t *resp, uint32_t resp_cap) {
    HvVirtio *v = &g->vio;
    uint8_t req[HDR + 64];
    memset(req, 0, sizeof req);
    uint32_t got = hv_virtq_read(v, e, 0, req, sizeof req);
    Hdr h;
    memcpy(&h, req, sizeof h);
    uint8_t *b = req + HDR;
    uint32_t rtype = RESP_OK_NODATA, rlen = HDR;
    g->cmds++;
    if (got < HDR) {
        rtype = RESP_ERR_UNSPEC;
        goto out;
    }
    if (g->cmds <= 60) LOG("cmd #%llu type %#x flags %#x (%u bytes)\n", (unsigned long long)g->cmds, h.type, h.flags, got);
    switch (h.type) {
    case CMD_GET_DISPLAY_INFO: {
        rtype = RESP_OK_DISPLAY_INFO;
        memset(resp + HDR, 0, 16 * 24);
        uint32_t mw, mh;
        guest_mode(g, &mw, &mh);
        uint32_t pm[6] = {0, 0, mw, mh, 1, 0};
        memcpy(resp + HDR, pm, sizeof pm);
        rlen = HDR + 16 * 24;
        g->info_reqs++;
        g->info_w = mw;
        g->info_h = mh;
        LOG("display info -> %ux%u (stage %s)\n", mw, mh, g->resets <= 1 ? "firmware" : "os");
        break;
    }
    case CMD_GET_EDID: {
        uint32_t scanout;
        memcpy(&scanout, b, 4);
        if (scanout != 0) {
            rtype = RESP_ERR_INVALID_SCANOUT_ID;
            break;
        }
        rtype = RESP_OK_EDID;
        memset(resp + HDR, 0, 8 + 1024);
        uint32_t size = 128;
        memcpy(resp + HDR, &size, 4);
        uint32_t ew, eh;
        guest_mode(g, &ew, &eh);
        make_edid(resp + HDR + 8, ew, eh);
        rlen = HDR + 8 + 1024;
        g->edid_reqs++;
        LOG("edid -> preferred %ux%u + common modes\n", ew, eh);
        break;
    }
    case CMD_RESOURCE_CREATE_2D: {
        uint32_t a[4]; /* id, format, width, height */
        memcpy(a, b, sizeof a);
        if (!a[0] || find(g, a[0]) || !a[2] || !a[3] || a[2] > MAX_DIM || a[3] > MAX_DIM) {
            rtype = RESP_ERR_INVALID_PARAMETER;
            break;
        }
        HvVgpuRes *r = NULL;
        for (int i = 0; i < HV_VGPU_MAX_RES; i++)
            if (!g->res[i].id) { r = &g->res[i]; break; }
        uint8_t *px = r ? calloc((size_t)a[2] * a[3], 4) : NULL;
        if (!px) {
            rtype = RESP_ERR_OUT_OF_MEMORY;
            break;
        }
        *r = (HvVgpuRes){.id = a[0], .format = a[1], .width = a[2], .height = a[3], .stride = a[2] * 4, .pixels = px};
        LOG("create res %u fmt %u %ux%u\n", a[0], a[1], a[2], a[3]);
        break;
    }
    case CMD_RESOURCE_UNREF: {
        uint32_t id;
        memcpy(&id, b, 4);
        HvVgpuRes *r = find(g, id);
        if (!r) rtype = RESP_ERR_INVALID_RESOURCE_ID;
        else destroy(g, r);
        break;
    }
    case CMD_RESOURCE_ATTACH_BACKING: {
        uint32_t a[2]; /* id, nr_entries */
        memcpy(a, b, sizeof a);
        HvVgpuRes *r = find(g, a[0]);
        if (!r) {
            rtype = RESP_ERR_INVALID_RESOURCE_ID;
            break;
        }
        if (!a[1] || a[1] > MAX_BACKING) {
            rtype = RESP_ERR_INVALID_PARAMETER;
            break;
        }
        HvVgpuBacking *bk = calloc(a[1], sizeof *bk);
        uint8_t *raw = malloc((size_t)a[1] * 16);
        if (!bk || !raw) {
            free(bk);
            free(raw);
            rtype = RESP_ERR_OUT_OF_MEMORY;
            break;
        }
        if (hv_virtq_read(v, e, HDR + 8, raw, a[1] * 16) != a[1] * 16) {
            free(bk);
            free(raw);
            rtype = RESP_ERR_INVALID_PARAMETER;
            break;
        }
        for (uint32_t i = 0; i < a[1]; i++) {
            memcpy(&bk[i].addr, raw + 16 * i, 8);
            memcpy(&bk[i].len, raw + 16 * i + 8, 4);
        }
        free(raw);
        free(r->backing);
        r->backing = bk;
        r->nbacking = a[1];
        LOG("attach res %u: %u entries\n", a[0], a[1]);
        break;
    }
    case CMD_RESOURCE_DETACH_BACKING: {
        uint32_t id;
        memcpy(&id, b, 4);
        HvVgpuRes *r = find(g, id);
        if (!r) {
            rtype = RESP_ERR_INVALID_RESOURCE_ID;
            break;
        }
        free(r->backing);
        r->backing = NULL;
        r->nbacking = 0;
        break;
    }
    case CMD_SET_SCANOUT: {
        Rect rc;
        uint32_t a[2]; /* scanout_id, resource_id */
        memcpy(&rc, b, sizeof rc);
        memcpy(a, b + 16, sizeof a);
        if (a[0] != 0) {
            rtype = RESP_ERR_INVALID_SCANOUT_ID;
            break;
        }
        if (a[1] && !find(g, a[1])) {
            rtype = RESP_ERR_INVALID_RESOURCE_ID;
            break;
        }
        g->scanout_res = a[1];
        show_scanout(g);
        LOG("scanout -> res %u (%ux%u)\n", a[1], rc.w, rc.h);
        break;
    }
    case CMD_TRANSFER_TO_HOST_2D: {
        Rect rc;
        uint64_t off;
        uint32_t id;
        memcpy(&rc, b, sizeof rc);
        memcpy(&off, b + 16, 8);
        memcpy(&id, b + 24, 4);
        HvVgpuRes *r = find(g, id);
        if (!r) {
            rtype = RESP_ERR_INVALID_RESOURCE_ID;
            break;
        }
        if (!r->backing || rc.x + rc.w > r->width || rc.y + rc.h > r->height || rc.x + rc.w < rc.x || rc.y + rc.h < rc.y) {
            rtype = RESP_ERR_INVALID_PARAMETER;
            break;
        }
        for (uint32_t y = 0; y < rc.h; y++) {
            uint8_t *dst = r->pixels + (size_t)(rc.y + y) * r->stride + (size_t)rc.x * 4;
            if (backing_read(g, r, off + (uint64_t)r->stride * y, dst, rc.w * 4) != 0) {
                rtype = RESP_ERR_INVALID_PARAMETER;
                break;
            }
        }
        break;
    }
    case CMD_RESOURCE_FLUSH: {
        uint32_t id;
        memcpy(&id, b + 16, 4);
        if (!find(g, id)) {
            rtype = RESP_ERR_INVALID_RESOURCE_ID;
            break;
        }
        if (id == g->scanout_res) {
            g->flushes++;
            hv_fb_display_override_flushed(g->fb);
        }
        break;
    }
    case CMD_GET_CAPSET_INFO:
        rtype = RESP_ERR_INVALID_PARAMETER; /* no 3D */
        break;
    default:
        LOG("unhandled command %#x\n", h.type);
        rtype = RESP_ERR_UNSPEC;
        break;
    }
out:;
    Hdr o = {.type = rtype, .flags = h.flags & FLAG_FENCE, .fence_id = (h.flags & FLAG_FENCE) ? h.fence_id : 0, .ctx_id = h.ctx_id};
    memcpy(resp, &o, sizeof o);
    if (rlen > resp_cap) rlen = resp_cap;
    return rlen;
}

/* The cursor queue: Linux (KMS cursor plane) puts the pointer here, not in its frames. pos is the
   image's top-left corner in scanout pixels; the hot spot only matters to a host pointer. */
static void cursor_cmd(HvVirtioGpu *g, const uint8_t *req) {
    uint32_t type, scanout, res;
    int32_t x, y;
    memcpy(&type, req, 4);
    memcpy(&scanout, req + HDR, 4);
    memcpy(&x, req + HDR + 4, 4);
    memcpy(&y, req + HDR + 8, 4);
    memcpy(&res, req + HDR + 16, 4);
    if (scanout != 0) return;
    if (type == CMD_UPDATE_CURSOR) {
        if (!res) {
            hv_fb_display_cursor_image(g->fb, NULL, 0, 0);
        } else if (g->g3d && (g->vio.driver_features & F_VIRGL)) {
            hv_vgpu3d_cursor(g->g3d, res); /* the renderer owns it: read on its thread */
        } else {
            static uint32_t px[64 * 64];
            uint32_t w = 0, h = 0;
            pthread_mutex_lock(&g->mu);
            HvVgpuRes *r = find(g, res);
            if (r && r->pixels) {
                w = r->width < 64 ? r->width : 64;
                h = r->height < 64 ? r->height : 64;
                for (uint32_t row = 0; row < h; row++) memcpy(px + row * w, r->pixels + (size_t)row * r->stride, w * 4);
            }
            pthread_mutex_unlock(&g->mu);
            hv_fb_display_cursor_image(g->fb, w ? px : NULL, w, h);
        }
    } else if (type != CMD_MOVE_CURSOR) {
        return;
    }
    hv_fb_display_cursor_move(g->fb, x, y);
}

static void notify(HvVirtio *v, int q) {
    HvVirtioGpu *g = v->dev;
    static HvVirtqElem e;
    static uint8_t resp[HDR + 8 + 1024];
    if (q == CURSORQ) {
        /* Hardware cursor commands (only this thread uses this queue). */
        int any = 0;
        while (hv_virtq_pop(v, q, &e) > 0) {
            uint8_t req[HDR + 32];
            memset(req, 0, sizeof req);
            if (hv_virtq_read(v, &e, 0, req, sizeof req) >= HDR + 20) cursor_cmd(g, req);
            hv_virtq_push(v, q, &e, 0);
            any = 1;
        }
        if (any) hv_virtio_interrupt(v);
        return;
    }
    if (g->g3d && (v->driver_features & F_VIRGL)) { /* the 3D driver: the worker thread takes it */
        hv_vgpu3d_kick(g->g3d);
        return;
    }
    int any = 0;
    pthread_mutex_lock(&g->mu);
    while (hv_virtq_pop(v, q, &e) > 0) {
        uint32_t n = hv_virtio_gpu_handle2d(g, &e, resp, sizeof resp);
        n = hv_virtq_write(v, &e, 0, resp, n);
        hv_virtq_push(v, q, &e, n);
        any = 1;
    }
    pthread_mutex_unlock(&g->mu);
    if (any) hv_virtio_interrupt(v);
}

static void on_config_write_cb(HvPciDev *d) {
    HvVirtioGpu *g = ((HvVirtio *)d->opaque)->dev;
    if (g && g->g3d) hv_vgpu3d_bar_update(g->g3d);
}

static void config_write(HvVirtio *v, uint32_t off, uint64_t val, unsigned size) {
    (void)size;
    if (off == 4) { /* events_clear */
        uint32_t ev;
        memcpy(&ev, v->config, 4);
        ev &= ~(uint32_t)val;
        memcpy(v->config, &ev, 4);
    }
}

static void on_reset(HvVirtio *v) {
    HvVirtioGpu *g = v->dev;
    if (!g) return;
    pthread_mutex_lock(&g->mu);
    g->resets++;
    LOG("device reset by driver (#%u)\n", g->resets);
    drop_all(g);
    pthread_mutex_unlock(&g->mu);
    if (g->g3d) hv_vgpu3d_reset(g->g3d);
}

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb, uint32_t pref_w, uint32_t pref_h) {
    HvVirtioGpu *g = calloc(1, sizeof *g);
    if (!g) return NULL;
    HvVirtio *v = &g->vio;
    hv_virtio_init(v, m, 16, 0x038000, 2, F_EDID); /* GPU, "other display controller" like QEMU */
    v->pci.config[0x2e] = 0x00; /* SUBSYS_11001AF4: primary hardware ID in viogpudo.inf */
    v->pci.config[0x2f] = 0x11;
    v->dev = g;
    v->notify = notify;
    v->config_write = config_write;
    v->on_reset = on_reset;
    hv_virtio_enable_msix(v, 3); /* config + 2 queues; viogpudo fails without MSI-X vectors */
    g->fb = fb;
    pthread_mutex_init(&g->mu, NULL);
    g->pref_w = pref_w >= 640 && pref_w <= MAX_DIM ? pref_w : 1024;
    g->pref_h = pref_h >= 480 && pref_h <= MAX_DIM ? pref_h : 768;
    g->g3d = hv_vgpu3d_create(g);
    uint32_t cfg[4] = {0, 0, 1, hv_vgpu3d_num_capsets(g->g3d)}; /* events_read, events_clear, num_scanouts, num_capsets */
    memcpy(v->config, cfg, sizeof cfg);
    v->config_len = sizeof cfg;
    if (g->g3d) {
        v->features |= hv_vgpu3d_features(g->g3d);
        hv_pci_add_bar_flags(&v->pci, HV_VGPU3D_HOSTMEM_BAR, hv_vgpu3d_hostmem_size(g->g3d), 1, 1);
        hv_virtio_add_shm_cap(v, 0xa0, HV_VGPU3D_HOSTMEM_BAR, 0, hv_vgpu3d_hostmem_size(g->g3d), 1 /* HOST_VISIBLE */);
        v->pci.on_config_write = on_config_write_cb;
    }
    hv_pcie_attach(bus, &v->pci);
    fprintf(stderr, "winvm: virtio-gpu attached (preferred %ux%u, 3D %s)\n", g->pref_w, g->pref_h, g->g3d ? "on" : "off");
    return g;
}

void hv_virtio_gpu_set_preferred(HvVirtioGpu *g, uint32_t w, uint32_t h) {
    if (!g || w < 640 || h < 480 || w > MAX_DIM || h > MAX_DIM) return;
    hv_dev_lock(g->vio.m); /* same order as notify(): device lock, then ours */
    pthread_mutex_lock(&g->mu);
    int changed = w != g->pref_w || h != g->pref_h;
    g->pref_w = w;
    g->pref_h = h;
    if (changed && (g->vio.status & 4)) {
        uint32_t ev;
        memcpy(&ev, g->vio.config, 4);
        ev |= EVENT_DISPLAY;
        memcpy(g->vio.config, &ev, 4);
        hv_virtio_config_interrupt(&g->vio);
    }
    pthread_mutex_unlock(&g->mu);
    hv_dev_unlock(g->vio.m);
    if (changed) hv_machine_wake(g->vio.m);
}

int hv_virtio_gpu_describe(HvVirtioGpu *g, char *buf, unsigned len) {
    if (!g || !buf || !len) return -1;
    pthread_mutex_lock(&g->mu);
    HvVgpuRes *r = find(g, g->scanout_res);
    int n = snprintf(buf, len,
                     "stage=%s resets=%u driver_ok=%d scanout=%ux%u pref=%ux%u info=%ux%u info_reqs=%llu edid_reqs=%llu cmds=%llu flushes=%llu msix=%d",
                     g->resets <= 1 && !(g->vio.driver_features & F_VIRGL) ? "firmware" : "os", g->resets, (g->vio.status & 4) != 0, r ? r->width : 0,
                     r ? r->height : 0, g->pref_w, g->pref_h, g->info_w, g->info_h, (unsigned long long)g->info_reqs,
                     (unsigned long long)g->edid_reqs, (unsigned long long)g->cmds, (unsigned long long)g->flushes,
                     hv_pci_msix_enabled(&g->vio.pci));
    pthread_mutex_unlock(&g->mu);
    if (n > 0 && (unsigned)n < len) {
        n += snprintf(buf + n, len - (unsigned)n, " virgl=%d 3d=", (g->vio.driver_features & F_VIRGL) != 0);
        if ((unsigned)n < len) n += hv_vgpu3d_describe(g->g3d, buf + n, len - (unsigned)n);
    }
    return n;
}

void hv_virtio_gpu_reset(HvVirtioGpu *g) {
    if (!g) return;
    pthread_mutex_lock(&g->mu);
    g->resets = 0;
    drop_all(g);
    pthread_mutex_unlock(&g->mu);
    if (g->g3d) hv_vgpu3d_reset(g->g3d);
}
