/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The graphics hot switch (devices/virtio_gpu.c, hv_virtio_gpu_set_3d): what the device offers each time a driver
   starts, with stand-ins for the virtio transport, the machine and the 3D renderer (virtio_gpu3d.c), and the real
   fb_display.c. A driver start is played as the transport sees it: a reset (status 0), then the features it takes
   out of those offered, then DRIVER_OK.
   - With the renderer: 3D (VIRGL, blobs, context init) and the capset count are offered; switched to 2D, the next
     driver start takes none of them and the capset count reads 0; back to 3D, they return. The running driver is
     not touched by a switch (what it negotiated stays until it restarts). Mode reports follow.
   - A 2D driver after a switch is never taken for the firmware (GET_DISPLAY_INFO answers the preferred size, not
     ramfb's), while the firmware itself at boot still is.
   - Without the renderer: 3D cannot be offered (-1) and nothing changes.
   - fb_display: 3D's read-back buffer leaves the screen only while it is still what the screen shows.
   - Background drain (virtio_gpu3d.h): when a parked fence is answered by the host itself while the app is in the
     background, played through a stand-in fence queue the way the worker uses it; and the device passes the setting
     on to its renderer. */
#include "fb_display.h"
#include "virtio_gpu.h"
#include "virtio_gpu3d.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
static void check(const char *what, int ok) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    }
}

#define F_VIRGL (1ull << 0)
#define F_EDID (1ull << 1)
#define F_BLOB (1ull << 3)
#define F_CTX_INIT (1ull << 4)

/* ---- stand-ins: the machine and the transport ---- */
void hv_dev_lock(HvMachine *m) { (void)m; }
void hv_dev_unlock(HvMachine *m) { (void)m; }
void hv_machine_wake(HvMachine *m) { (void)m; }
void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) { (void)m, (void)pa, (void)len; return NULL; }
void hv_virtio_init(HvVirtio *v, HvMachine *m, int device_id, uint32_t class_code, int nq, uint64_t features) {
    (void)device_id, (void)class_code;
    v->m = m;
    v->nq = (uint16_t)nq;
    v->features = features | HV_VIRTIO_F_VERSION_1;
}
void hv_virtio_enable_msix(HvVirtio *v, uint16_t nvec) { (void)v, (void)nvec; }
void hv_virtio_add_shm_cap(HvVirtio *v, uint8_t at, uint8_t bar, uint64_t off, uint64_t len, uint8_t id) {
    (void)v, (void)at, (void)bar, (void)off, (void)len, (void)id;
}
void hv_virtio_interrupt(HvVirtio *v) { (void)v; }
void hv_virtio_config_interrupt(HvVirtio *v) { (void)v; }
static uint8_t req_buf[64];
static uint32_t req_len;
int hv_virtq_pop(HvVirtio *v, int q, HvVirtqElem *e) { (void)v, (void)q, (void)e; return 0; }
uint32_t hv_virtq_read(HvVirtio *v, const HvVirtqElem *e, uint32_t off, void *dst, uint32_t len) {
    (void)v, (void)e;
    if (off >= req_len) return 0;
    uint32_t n = req_len - off < len ? req_len - off : len;
    memcpy(dst, req_buf + off, n);
    return n;
}
uint32_t hv_virtq_write(HvVirtio *v, const HvVirtqElem *e, uint32_t off, const void *src, uint32_t len) {
    (void)v, (void)e, (void)off, (void)src;
    return len;
}
void hv_virtq_push(HvVirtio *v, int q, const HvVirtqElem *e, uint32_t len) { (void)v, (void)q, (void)e, (void)len; }
void hv_pci_add_bar_flags(HvPciDev *d, int bar, uint64_t size, int is64, int prefetch) {
    (void)d, (void)bar, (void)size, (void)is64, (void)prefetch;
}
int hv_pcie_attach(HvPcie *bus, HvPciDev *d) { (void)bus, (void)d; return 0; }
int hv_pci_msix_enabled(const HvPciDev *d) { (void)d; return 1; }
int hv_fw_cfg_add_writable_file(HvFwCfg *f, const char *name, uint32_t size, HvFwCfgWriteCb cb, void *opaque) {
    (void)f, (void)name, (void)size, (void)cb, (void)opaque;
    return 0;
}

/* ---- stand-ins: the 3D renderer ---- */
static int renderer_loaded;
static int renderer_resets;
static struct HvVgpu3d *fake3d = (struct HvVgpu3d *)&renderer_loaded;
void hv_vgpu3d_set_window(void *mem, uint64_t size) { (void)mem, (void)size; }
HvVgpu3d *hv_vgpu3d_create(struct HvVirtioGpu *g) { (void)g; return renderer_loaded ? fake3d : NULL; }
uint64_t hv_vgpu3d_features(HvVgpu3d *s) { return s ? F_VIRGL | F_BLOB | F_CTX_INIT : 0; }
uint32_t hv_vgpu3d_num_capsets(HvVgpu3d *s) { return s ? 3 : 0; }
uint64_t hv_vgpu3d_hostmem_size(HvVgpu3d *s) { return s ? 64ull << 20 : 0; }
void hv_vgpu3d_kick(HvVgpu3d *s) { (void)s; }
void hv_vgpu3d_cursor(HvVgpu3d *s, uint32_t res) { (void)s, (void)res; }
void hv_vgpu3d_reset(HvVgpu3d *s) { if (s) renderer_resets++; }
void hv_vgpu3d_bar_update(HvVgpu3d *s) { (void)s; }
static int background_calls, background_on;
void hv_vgpu3d_set_background(HvVgpu3d *s, int on) {
    if (s) background_calls++, background_on = on;
}
int hv_vgpu3d_describe(HvVgpu3d *s, char *buf, unsigned len) { return snprintf(buf, len, "%s", s ? "on" : "off"); }

/* ---- a driver starting, as the transport sees it ---- */
static void driver_start(HvVirtioGpu *g, uint64_t wants) {
    HvVirtio *v = &g->vio;
    v->driver_features = 0;
    v->status = 0;
    if (v->on_reset) v->on_reset(v); /* status 0: the reset every driver start begins with */
    v->driver_features = wants & v->features;
    v->status = 1 | 2 | 8 | 4; /* ACKNOWLEDGE, DRIVER, FEATURES_OK, DRIVER_OK */
}

static uint32_t num_capsets(HvVirtioGpu *g) {
    uint32_t n;
    memcpy(&n, g->vio.config + 12, 4);
    return n;
}

/* GET_DISPLAY_INFO through the 2D handler: the size it answers. */
static void display_info(HvVirtioGpu *g, uint32_t *w, uint32_t *h) {
    memset(req_buf, 0, sizeof req_buf);
    uint32_t type = 0x0100;
    memcpy(req_buf, &type, 4);
    req_len = 24;
    static uint8_t resp[24 + 8 + 1024];
    HvVirtqElem e;
    memset(&e, 0, sizeof e);
    pthread_mutex_lock(&g->mu);
    hv_virtio_gpu_handle2d(g, &e, resp, sizeof resp);
    pthread_mutex_unlock(&g->mu);
    memcpy(w, resp + 24 + 8, 4);
    memcpy(h, resp + 24 + 12, 4);
}

static void with_renderer(void) {
    renderer_loaded = 1;
    HvFbDisplay fb;
    memset(&fb, 0, sizeof fb);
    pthread_mutex_init(&fb.mu, NULL);
    HvVirtioGpu *g = hv_virtio_gpu_create(NULL, NULL, &fb, 1920, 1200);
    check("created", g != NULL);
    if (!g) return;
    HvVgpuMode m;
    hv_virtio_gpu_mode(g, &m);
    check("renderer loaded: capable, 3D offered", m.capable && m.offered3d && !m.negotiated3d && !m.driver_ok);
    check("3D offered: VIRGL, blobs, context init, EDID", (g->vio.features & (F_VIRGL | F_BLOB | F_CTX_INIT | F_EDID)) ==
                                                              (F_VIRGL | F_BLOB | F_CTX_INIT | F_EDID));
    check("3D offered: the capsets", num_capsets(g) == 3);

    /* the firmware (no VIRGL), then the OS's 3D driver */
    driver_start(g, F_EDID);
    uint32_t w = 0, h = 0;
    display_info(g, &w, &h);
    check("firmware stage: ramfb's size, not the preferred one", w == 1210 && h == 834);
    driver_start(g, F_VIRGL | F_BLOB | F_CTX_INIT | F_EDID);
    hv_virtio_gpu_mode(g, &m);
    check("3D driver: negotiated", m.negotiated3d && m.driver_ok && m.resets == 2);

    /* switch to 2D: the running driver keeps what it took */
    check("switch to 2D", hv_virtio_gpu_set_3d(g, 0) == 0);
    hv_virtio_gpu_mode(g, &m);
    check("2D offered, the 3D driver still runs", !m.offered3d && m.negotiated3d && m.capable);
    check("2D offered: no VIRGL, blobs or context init", !(g->vio.features & (F_VIRGL | F_BLOB | F_CTX_INIT)) &&
                                                         (g->vio.features & F_EDID) &&
                                                         (g->vio.features & HV_VIRTIO_F_VERSION_1));
    check("2D offered: no capsets", num_capsets(g) == 0);
    int before = renderer_resets;
    /* the guest restarts its display adapter (pnputil /restart-device): the old driver resets the device on its
       way out, the new one on its way in */
    g->vio.status = 0;
    g->vio.on_reset(&g->vio);
    driver_start(g, F_VIRGL | F_BLOB | F_CTX_INIT | F_EDID); /* the same 3D driver asks: VIRGL is not there */
    hv_virtio_gpu_mode(g, &m);
    check("after the restart: 2D, driver running, resets moved on", !m.negotiated3d && m.driver_ok && m.resets == 4);
    check("the renderer was told to drop the 3D state", renderer_resets > before);
    display_info(g, &w, &h);
    check("a 2D driver after the switch is not taken for the firmware: the preferred size", w == 1920 && h == 1200);
    char line[512];
    hv_virtio_gpu_describe(g, line, sizeof line);
    check("describe: os stage, 2D offered", strstr(line, "stage=os") && strstr(line, "virgl=0") && strstr(line, "offer=2d"));

    /* and back to 3D */
    check("switch back to 3D", hv_virtio_gpu_set_3d(g, 1) == 0);
    check("3D offered again", (g->vio.features & F_VIRGL) && num_capsets(g) == 3);
    driver_start(g, F_VIRGL | F_BLOB | F_CTX_INIT | F_EDID);
    hv_virtio_gpu_mode(g, &m);
    check("after the next restart: 3D again", m.negotiated3d && m.driver_ok && m.offered3d && m.switches == 2);
    check("the same offer again is no switch", hv_virtio_gpu_set_3d(g, 1) == 0 && (hv_virtio_gpu_mode(g, &m), m.switches == 2));

    /* a machine reset keeps the offer */
    hv_virtio_gpu_set_3d(g, 0);
    hv_virtio_gpu_reset(g);
    hv_virtio_gpu_mode(g, &m);
    check("machine reset: the offer stays 2D", !m.offered3d && !(g->vio.features & F_VIRGL) && m.resets == 0);
    driver_start(g, F_EDID);
    display_info(g, &w, &h);
    check("machine reset: the firmware is the firmware again", w == 1210 && h == 834);
}

static void without_renderer(void) {
    renderer_loaded = 0;
    HvFbDisplay fb;
    memset(&fb, 0, sizeof fb);
    pthread_mutex_init(&fb.mu, NULL);
    HvVirtioGpu *g = hv_virtio_gpu_create(NULL, NULL, &fb, 1920, 1200);
    HvVgpuMode m;
    hv_virtio_gpu_mode(g, &m);
    check("no renderer: not capable, 2D", !m.capable && !m.offered3d && !(g->vio.features & F_VIRGL));
    check("no renderer: 3D refused", hv_virtio_gpu_set_3d(g, 1) == -1 && !(g->vio.features & F_VIRGL));
    check("no renderer: 2D is fine", hv_virtio_gpu_set_3d(g, 0) == 0 && (hv_virtio_gpu_mode(g, &m), m.switches == 0));
    check("NULL device", hv_virtio_gpu_set_3d(NULL, 0) == -1);
}

static void override_ownership(void) {
    HvFbDisplay fb;
    memset(&fb, 0, sizeof fb);
    pthread_mutex_init(&fb.mu, NULL);
    static uint8_t mine[16], theirs[16];
    hv_fb_display_set_override(&fb, mine, 2, 2, 8);
    hv_fb_display_clear_override_if(&fb, mine);
    check("own read-back buffer cleared", fb.ovr_host == NULL && fb.ovr_width == 0);
    hv_fb_display_set_override(&fb, theirs, 2, 2, 8);
    uint64_t serial = fb.ovr_serial;
    hv_fb_display_clear_override_if(&fb, mine);
    check("another scanout (the 2D driver's) stays", fb.ovr_host == theirs && fb.ovr_width == 2 && fb.ovr_serial == serial);
}

/* virtio_gpu3d.c's driver reset: virgl_renderer_reset (Metal work) runs only for a renderer that did something since
   its last reset. A 2D driver's resets (which may come with the app in the background) never reach the renderer. */
static void renderer_reset_plan(void) {
    HvVgpu3dUse u;
    memset(&u, 0, sizeof u);
    check("reset plan: a fresh renderer (boot, the firmware's reset) is not reset", !hv_vgpu3d_reset_needed(&u));
    /* the OS's 3D driver works: commands, contexts, resources, a scanout, a parked fence */
    u.used = 1, u.live_ctxs = 2, u.resources = 40, u.scanout = 7, u.parked = 1;
    check("reset plan: after 3D use the switch's reset runs", hv_vgpu3d_reset_needed(&u));
    /* the reset ran: everything went, and the flag was cleared */
    memset(&u, 0, sizeof u);
    for (int i = 0; i < 4; i++) /* the 2D driver's resets: Windows restarts, Windows Update, a TDR, the firmware */
        check("reset plan: 2D-only resets after it are skipped", !hv_vgpu3d_reset_needed(&u));
    HvVgpu3dUse one;
    memset(&one, 0, sizeof one);
    one.used = 1;
    check("reset plan: a command alone (e.g. a context that failed) is enough", hv_vgpu3d_reset_needed(&one));
    memset(&one, 0, sizeof one);
    one.live_ctxs = 1;
    check("reset plan: a live context alone", hv_vgpu3d_reset_needed(&one));
    memset(&one, 0, sizeof one);
    one.resources = 1;
    check("reset plan: a resource alone", hv_vgpu3d_reset_needed(&one));
    memset(&one, 0, sizeof one);
    one.scanout = 1;
    check("reset plan: a scanout alone", hv_vgpu3d_reset_needed(&one));
    memset(&one, 0, sizeof one);
    one.parked = 1;
    check("reset plan: a parked fence alone", hv_vgpu3d_reset_needed(&one));
}

/* The worker's use of the drain plan over a queue of parked fences: what is answered at a given moment, oldest first,
   and when it next has to wake. */
#define MS 1000000ull
typedef struct { uint64_t parked_ns; int answered; uint64_t at; } FakeFence;
static int drain_pass(const HvVgpu3dDrain *d, FakeFence *f, int n, uint64_t now, uint64_t *wake) {
    int answered = 0;
    *wake = UINT64_MAX;
    for (int i = 0; i < n; i++) {
        if (f[i].answered) continue;
        if (hv_vgpu3d_drain_due(d, f[i].parked_ns, now)) {
            f[i].answered = 1, f[i].at = now;
            answered++;
        } else {
            uint64_t t = hv_vgpu3d_drain_due_at(d, f[i].parked_ns);
            if (t < *wake) *wake = t;
        }
    }
    return answered;
}

static void background_drain(void) {
    HvVgpu3dDrain d;
    memset(&d, 0, sizeof d);
    uint64_t wake;
    check("drain off: never due", !hv_vgpu3d_drain_due(&d, 0, 3600000 * MS) && hv_vgpu3d_drain_due_at(&d, 5) == UINT64_MAX);
    /* parked in the foreground long before the app left, a fresh one just before, one in the background */
    FakeFence f[3] = {{.parked_ns = 1000 * MS}, {.parked_ns = 9900 * MS}, {.parked_ns = 10100 * MS}};
    check("drain off: the worker sleeps without a deadline", drain_pass(&d, f, 3, 10000 * MS, &wake) == 0 && wake == UINT64_MAX);
    hv_vgpu3d_drain_set(&d, 1, 10000 * MS); /* the app goes to the background at 10 s */
    check("drain on: nothing answered at once, even a fence parked long ago",
          drain_pass(&d, f, 3, 10000 * MS, &wake) == 0 && wake == 10250 * MS);
    check("drain on: the grace period counts from going on", drain_pass(&d, f, 3, 10249 * MS, &wake) == 0);
    check("drain on: after the grace both earlier fences are answered", drain_pass(&d, f, 3, 10250 * MS, &wake) == 2 &&
                                                                         f[0].answered && f[1].answered && !f[2].answered);
    check("drain on: a fence parked in the background waits its own grace", wake == 10350 * MS &&
                                                                             drain_pass(&d, f, 3, 10349 * MS, &wake) == 0);
    check("drain on: then it is answered", drain_pass(&d, f, 3, 10350 * MS, &wake) == 1 && wake == UINT64_MAX);
    hv_vgpu3d_drain_set(&d, 1, 20000 * MS);
    check("drain on again while on: the first moment stays", d.since_ns == 10000 * MS);
    hv_vgpu3d_drain_set(&d, 0, 30000 * MS); /* back in front */
    FakeFence g[1] = {{.parked_ns = 30000 * MS}};
    check("drain off again: fences wait for the renderer", drain_pass(&d, g, 1, 90000 * MS, &wake) == 0 && wake == UINT64_MAX);
    hv_vgpu3d_drain_set(&d, 1, 100000 * MS); /* the next trip */
    check("next trip: counted from its own start", d.since_ns == 100000 * MS &&
                                                    !hv_vgpu3d_drain_due(&d, g[0].parked_ns, 100100 * MS) &&
                                                    hv_vgpu3d_drain_due(&d, g[0].parked_ns, 100250 * MS));
    d.grace_ns = 5 * MS;
    check("a grace of its own", hv_vgpu3d_drain_due_at(&d, 100000 * MS) == 100005 * MS);
    check("no overflow at the end of time", hv_vgpu3d_drain_due_at(&d, UINT64_MAX - 1) == UINT64_MAX - 1);

    /* the device passes the setting on to its renderer, and does nothing without one */
    renderer_loaded = 1;
    HvFbDisplay fb;
    memset(&fb, 0, sizeof fb);
    pthread_mutex_init(&fb.mu, NULL);
    HvVirtioGpu *gpu = hv_virtio_gpu_create(NULL, NULL, &fb, 1920, 1200);
    background_calls = 0;
    hv_virtio_gpu_set_background(gpu, 1);
    check("device: background on reaches the renderer", background_calls == 1 && background_on == 1);
    hv_virtio_gpu_set_background(gpu, 0);
    check("device: and off", background_calls == 2 && background_on == 0);
    renderer_loaded = 0;
    HvVirtioGpu *plain = hv_virtio_gpu_create(NULL, NULL, &fb, 1920, 1200);
    hv_virtio_gpu_set_background(plain, 1);
    hv_virtio_gpu_set_background(NULL, 1);
    check("device: no renderer, nothing to drain", background_calls == 2);
}

int main(void) {
    with_renderer();
    background_drain();
    renderer_reset_plan();
    without_renderer();
    override_ownership();
    printf("gpu mode: %s (%d failures)\n", failures ? "FAILED" : "ok", failures);
    return failures != 0;
}
