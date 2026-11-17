/* SPDX-License-Identifier: GPL-2.0-or-later */
/* virtio-gpu 3D through virglrenderer. Modeled on QEMU's hw/display/virtio-gpu-virgl.c (UTM's
   utm-edition branch, which carries the neptune/DXMT support this follows). See virtio_gpu3d.h. */
#include "virtio_gpu3d.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define VIRGL_RENDERER_UNSTABLE_APIS 1
#include "virglrenderer.h"
#include "virtio_gpu.h"

/* ---- protocol ---- */
#define F_VIRGL (1ull << 0)
#define F_RESOURCE_BLOB (1ull << 3)
#define F_CONTEXT_INIT (1ull << 4)

#define CMD_GET_DISPLAY_INFO 0x0100
#define CMD_RESOURCE_CREATE_2D 0x0101
#define CMD_RESOURCE_UNREF 0x0102
#define CMD_SET_SCANOUT 0x0103
#define CMD_RESOURCE_FLUSH 0x0104
#define CMD_TRANSFER_TO_HOST_2D 0x0105
#define CMD_RESOURCE_ATTACH_BACKING 0x0106
#define CMD_RESOURCE_DETACH_BACKING 0x0107
#define CMD_GET_CAPSET_INFO 0x0108
#define CMD_GET_CAPSET 0x0109
#define CMD_GET_EDID 0x010a
#define CMD_RESOURCE_CREATE_BLOB 0x010c
#define CMD_SET_SCANOUT_BLOB 0x010d
#define CMD_CTX_CREATE 0x0200
#define CMD_CTX_DESTROY 0x0201
#define CMD_CTX_ATTACH_RESOURCE 0x0202
#define CMD_CTX_DETACH_RESOURCE 0x0203
#define CMD_RESOURCE_CREATE_3D 0x0204
#define CMD_TRANSFER_TO_HOST_3D 0x0205
#define CMD_TRANSFER_FROM_HOST_3D 0x0206
#define CMD_SUBMIT_3D 0x0207
#define CMD_RESOURCE_MAP_BLOB 0x0208
#define CMD_RESOURCE_UNMAP_BLOB 0x0209

#define RESP_OK_NODATA 0x1100
#define RESP_OK_CAPSET_INFO 0x1102
#define RESP_OK_CAPSET 0x1103
#define RESP_OK_MAP_INFO 0x1106
#define RESP_ERR_UNSPEC 0x1200
#define RESP_ERR_OUT_OF_MEMORY 0x1201
#define RESP_ERR_INVALID_SCANOUT_ID 0x1202
#define RESP_ERR_INVALID_RESOURCE_ID 0x1203
#define RESP_ERR_INVALID_PARAMETER 0x1205

#define FLAG_FENCE 1u
#define FLAG_RING_IDX 2u
#define BLOB_MEM_HOST3D 2u

#define CAPSET_VIRGL 1
#define CAPSET_VIRGL2 2
#define CAPSET_VENUS 4
#define CAPSET_NEPTUNE 7

#define HDR 24
#define MAX_SUBMIT (16u << 20)
#define MAX_ENTRIES 262144
#define HOSTMEM_DEFAULT (1ull << 30)
#define HOST_PAGE 16384ull

typedef struct {
    uint32_t type, flags;
    uint64_t fence_id;
    uint32_t ctx_id;
    uint8_t ring_idx, pad[3];
} Hdr;

static int g3_log = -1;
#define LOG(...)                                                                   \
    do {                                                                           \
        if (g3_log < 0) g3_log = getenv("HV_GPU_LOG") != NULL;                     \
        if (g3_log) fprintf(stderr, "virtio-gpu3d: " __VA_ARGS__);                 \
    } while (0)
#define WARN(...) fprintf(stderr, "virtio-gpu3d: " __VA_ARGS__)

/* ---- virglrenderer, loaded at run time ---- */
#define VFN(name) __typeof__(name) *name
static struct {
    VFN(virgl_renderer_init);
    VFN(virgl_renderer_poll);
    VFN(virgl_renderer_reset);
    VFN(virgl_renderer_get_cap_set);
    VFN(virgl_renderer_fill_caps);
    VFN(virgl_renderer_context_create);
    VFN(virgl_renderer_context_create_with_flags);
    VFN(virgl_renderer_context_destroy);
    VFN(virgl_renderer_ctx_attach_resource);
    VFN(virgl_renderer_ctx_detach_resource);
    VFN(virgl_renderer_resource_create);
    VFN(virgl_renderer_resource_unref);
    VFN(virgl_renderer_resource_attach_iov);
    VFN(virgl_renderer_resource_detach_iov);
    VFN(virgl_renderer_transfer_write_iov);
    VFN(virgl_renderer_transfer_read_iov);
    VFN(virgl_renderer_submit_cmd);
    VFN(virgl_renderer_create_fence);
    VFN(virgl_renderer_context_create_fence);
    VFN(virgl_renderer_resource_create_blob);
    VFN(virgl_renderer_resource_map);
    VFN(virgl_renderer_resource_map_fixed);
    VFN(virgl_renderer_resource_unmap);
    VFN(virgl_renderer_resource_get_map_info);
    VFN(virgl_renderer_resource_get_info);
    VFN(virgl_renderer_resource_get_info_ext);
    VFN(virgl_renderer_force_ctx_0);
    VFN(virgl_renderer_create_handle_for_scanout);
    VFN(virgl_renderer_release_handle_for_scanout);
} V;

/* ---- EGL (ANGLE on Metal) for virgl's GL contexts ---- */
typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface;
typedef intptr_t EGLAttrib;
typedef int32_t EGLint;
#define EGL_NONE 0x3038
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_SURFACE_TYPE 0x3033
#define EGL_PBUFFER_BIT 0x0001
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_ES3_BIT 0x0040
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
static struct {
    EGLDisplay (*GetPlatformDisplay)(uint32_t, void *, const EGLAttrib *);
    uint32_t (*Initialize)(EGLDisplay, EGLint *, EGLint *);
    uint32_t (*BindAPI)(uint32_t);
    uint32_t (*ChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
    EGLContext (*CreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
    uint32_t (*DestroyContext)(EGLDisplay, EGLContext);
    uint32_t (*MakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
    EGLint (*GetError)(void);
} E;

/* ---- device state ---- */
typedef struct Parked {
    struct Parked *next;
    Hdr h;
    uint32_t epoch;
    uint64_t parked_ns; /* CLOCK_MONOTONIC: background drain answers it a grace period later */
    HvVirtqElem e;
} Parked;

typedef struct FenceEv {
    struct FenceEv *next;
    uint32_t ctx_id, ring_idx; /* ring_idx UINT32_MAX: a global fence */
    uint64_t fence_id;
} FenceEv;

typedef struct {
    uint32_t id;
    uint8_t is_blob, mapped, mapped_fixed, scanout_native;
    uint64_t map_off, map_len;
    struct iovec *iov; /* guest backing handed to virgl (blob GUEST memory or attach_backing) */
    int niov;
} Res3d;

#define MAX_RES3D 8192

struct HvVgpu3d {
    HvVirtioGpu *g;
    pthread_t th;
    pthread_mutex_t mu; /* kick, epoch, fence events */
    pthread_cond_t cv;
    int kicked;
    uint32_t cursor_req; /* a hardware cursor image to fetch from this resource (cursor queue) */
    int cursor_pending;
    uint32_t epoch;      /* bumped by a driver reset */
    uint32_t done_epoch; /* the worker has reset the renderer for this one */
    FenceEv *events;
    HvVgpu3dDrain drain; /* background drain (hv_vgpu3d_set_background) */
    uint64_t drain_trips;

    /* worker only */
    int used; /* the renderer did work (a command, a cursor read-back) since its last reset */
    uint64_t resets, resets_skipped;
    Parked *fenceq;
    uint32_t nparked_global;
    /* Live contexts and their capsets, for the log: whether Windows' contexts come and go as they should
       (a crash in DXMT after a display change came with more DXMT devices than live contexts). */
    struct { uint32_t id; uint8_t capset; } live[256];
    uint32_t nlive, nlive_npt, peak_live;
    uint64_t ctx_failed, ctx_destroyed, ctx_destroy_unknown;
    uint64_t fenced_ring, fenced_global; /* fenced commands by timeline */
    uint64_t drained_ring, drained_global; /* fences answered by background drain, not by the renderer */
    uint64_t drained_trip;                 /* ... since drain last went on */
    uint64_t drain_max_age_ns;             /* the oldest fence drain answered (from when it was parked) */
    int drain_was_on;                      /* the worker's view: the trip's totals are logged when it ends */
    Res3d res[MAX_RES3D];
    uint32_t capsets[8], ncapsets;
    uint32_t scanout_res;
    void *scanout_handle; /* from create_handle_for_scanout, released when replaced */
    int scanout_handle_type;
    uint8_t *readback;    /* CPU copy of a scanout virgl could not give as a Metal texture */
    size_t readback_len;
    uint32_t sc_w, sc_h;

    /* hostmem window */
    uint8_t *win;
    uint8_t **page_host; /* per 4 KB page of the window: the blob memory mapped there, or NULL */
    uint64_t win_size;
    int ram_idx;
    uint64_t win_pa;

    /* stats */
    uint64_t cmds, submits, submit_bytes, fences, maps, blobs, ctxs, errors, submit_errors;
    int init_ok;
    char why[160];

    EGLDisplay dpy;
    EGLConfig cfg;
    EGLContext root;
};

static HvVgpu3d *g_state;
static void *pre_win;
static uint64_t pre_win_size;

void hv_vgpu3d_set_window(void *mem, uint64_t size) {
    pre_win = mem;
    pre_win_size = size;
}

/* ---- shm_open without an app group: plain files in the temporary folder ----
   virglrenderer shares blob and ring memory between its client and the render-server thread
   with POSIX shared memory, which the iOS sandbox only allows under an entitled app group.
   Everything is in this process, so an unlinked-later file in tmp maps the same way. */
static char shm_dir[PATH_MAX];

static void shm_path(char *out, size_t n, const char *name) {
    char clean[200];
    size_t j = 0;
    for (size_t i = 0; name[i] && j + 1 < sizeof clean; i++) clean[j++] = name[i] == '/' ? '_' : name[i];
    clean[j] = 0;
    snprintf(out, n, "%s/vshm_%s", shm_dir, clean);
}

static int hv_shm_open(const char *name, int oflag, ...) {
    mode_t mode = 0600;
    if (oflag & O_CREAT) {
        va_list ap;
        va_start(ap, oflag);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    char p[PATH_MAX];
    shm_path(p, sizeof p, name);
    return open(p, oflag | O_CLOEXEC, mode);
}

static int hv_shm_unlink(const char *name) {
    char p[PATH_MAX];
    shm_path(p, sizeof p, name);
    return unlink(p);
}

/* Point one image's imported shm_open/shm_unlink at the functions above (its GOT entries). */
static int rebind_image(const struct mach_header_64 *mh, intptr_t slide) {
    const struct load_command *lc = (const void *)(mh + 1);
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dst = NULL;
    const struct segment_command_64 *linkedit = NULL;
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const uint8_t *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SYMTAB) st = (const void *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dst = (const void *)lc;
        else if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT))
            linkedit = (const void *)lc;
    }
    if (!st || !dst || !linkedit) return 0;
    uintptr_t lbase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(lbase + st->symoff);
    const char *strs = (const char *)(lbase + st->stroff);
    const uint32_t *ind = (const uint32_t *)(lbase + dst->indirectsymoff);
    int n = 0;
    lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const uint8_t *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        const struct section_64 *sec = (const void *)(seg + 1);
        for (uint32_t k = 0; k < seg->nsects; k++, sec++) {
            uint32_t t = sec->flags & SECTION_TYPE;
            if (t != S_NON_LAZY_SYMBOL_POINTERS && t != S_LAZY_SYMBOL_POINTERS) continue;
            void **ptrs = (void **)((uintptr_t)slide + sec->addr);
            uint32_t cnt = (uint32_t)(sec->size / sizeof(void *));
            for (uint32_t j = 0; j < cnt; j++) {
                uint32_t si = ind[sec->reserved1 + j];
                if (si & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
                const char *nm = strs + syms[si].n_un.n_strx;
                void *to = !strcmp(nm, "_shm_open") ? (void *)hv_shm_open
                           : !strcmp(nm, "_shm_unlink") ? (void *)hv_shm_unlink : NULL;
                if (!to) continue;
                vm_address_t page = (vm_address_t)&ptrs[j] & ~(vm_address_t)(vm_page_size - 1);
                kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, 0,
                                              VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr != KERN_SUCCESS) continue;
                ptrs[j] = to;
                vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ);
                n++;
            }
        }
    }
    return n;
}

static int rebind_shm(void *any_symbol_in_image) {
    Dl_info info;
    if (!dladdr(any_symbol_in_image, &info)) return 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++)
        if (_dyld_get_image_header(i) == info.dli_fbase)
            return rebind_image((const struct mach_header_64 *)info.dli_fbase, _dyld_get_image_vmaddr_slide(i));
    return 0;
}

/* ---- loading ---- */
static void *open_fw(const char *dir, const char *rel, int global) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", dir, rel);
    void *h = dlopen(p, RTLD_NOW | (global ? RTLD_GLOBAL : RTLD_LOCAL));
    if (!h) WARN("dlopen %s: %s\n", rel, dlerror());
    return h;
}

static int load_libs(HvVgpu3d *s) {
    const char *dir = getenv("HV_GPU3D_FRAMEWORKS");
    if (!dir || !*dir) {
        snprintf(s->why, sizeof s->why, "HV_GPU3D_FRAMEWORKS not set");
        return -1;
    }
    /* libepoxy opens "EGL.framework/EGL" and "GLESv2.framework/GLESv2" by relative path. */
    if (chdir(dir) != 0) WARN("chdir %s: %s\n", dir, strerror(errno));
    void *egl = open_fw(dir, "EGL.framework/EGL", 1);
    open_fw(dir, "GLESv2.framework/GLESv2", 1);
    open_fw(dir, "epoxy.0.framework/epoxy.0", 1);
    void *vr = open_fw(dir, "virglrenderer.1.framework/virglrenderer.1", 0);
    if (!egl || !vr) {
        snprintf(s->why, sizeof s->why, "frameworks missing (egl %p virgl %p)", egl, vr);
        return -1;
    }
#define SYM(name)                                                            \
    do {                                                                     \
        *(void **)&V.name = dlsym(vr, #name);                                \
        if (!V.name) {                                                       \
            snprintf(s->why, sizeof s->why, "missing %s", #name);            \
            return -1;                                                       \
        }                                                                    \
    } while (0)
    SYM(virgl_renderer_init);
    SYM(virgl_renderer_poll);
    SYM(virgl_renderer_reset);
    SYM(virgl_renderer_get_cap_set);
    SYM(virgl_renderer_fill_caps);
    SYM(virgl_renderer_context_create);
    SYM(virgl_renderer_context_create_with_flags);
    SYM(virgl_renderer_context_destroy);
    SYM(virgl_renderer_ctx_attach_resource);
    SYM(virgl_renderer_ctx_detach_resource);
    SYM(virgl_renderer_resource_create);
    SYM(virgl_renderer_resource_unref);
    SYM(virgl_renderer_resource_attach_iov);
    SYM(virgl_renderer_resource_detach_iov);
    SYM(virgl_renderer_transfer_write_iov);
    SYM(virgl_renderer_transfer_read_iov);
    SYM(virgl_renderer_submit_cmd);
    SYM(virgl_renderer_create_fence);
    SYM(virgl_renderer_context_create_fence);
    SYM(virgl_renderer_resource_create_blob);
    SYM(virgl_renderer_resource_map);
    SYM(virgl_renderer_resource_map_fixed);
    SYM(virgl_renderer_resource_unmap);
    SYM(virgl_renderer_resource_get_map_info);
    SYM(virgl_renderer_resource_get_info);
    SYM(virgl_renderer_resource_get_info_ext);
    SYM(virgl_renderer_force_ctx_0);
    SYM(virgl_renderer_create_handle_for_scanout);
    SYM(virgl_renderer_release_handle_for_scanout);
#undef SYM
#define ESYM(field, name)                                                    \
    do {                                                                     \
        *(void **)&E.field = dlsym(egl, name);                               \
        if (!E.field) {                                                      \
            snprintf(s->why, sizeof s->why, "missing %s", name);             \
            return -1;                                                       \
        }                                                                    \
    } while (0)
    ESYM(GetPlatformDisplay, "eglGetPlatformDisplay");
    ESYM(Initialize, "eglInitialize");
    ESYM(BindAPI, "eglBindAPI");
    ESYM(ChooseConfig, "eglChooseConfig");
    ESYM(CreateContext, "eglCreateContext");
    ESYM(DestroyContext, "eglDestroyContext");
    ESYM(MakeCurrent, "eglMakeCurrent");
    ESYM(GetError, "eglGetError");
#undef ESYM
    /* shared memory: the sandbox refuses shm_open without an app group */
    const char *tmp = getenv("TMPDIR");
    snprintf(shm_dir, sizeof shm_dir, "%s", tmp && *tmp ? tmp : "/tmp");
    size_t l = strlen(shm_dir);
    if (l > 1 && shm_dir[l - 1] == '/') shm_dir[l - 1] = 0;
    /* Files of earlier runs: the app is usually ended by a kill, which never unlinks them. They
       pile up, and a name coming round again fails its exclusive create. */
    {
        DIR *dd = opendir(shm_dir);
        struct dirent *de;
        unsigned gone = 0;
        while (dd && (de = readdir(dd)))
            if (!strncmp(de->d_name, "vshm_", 5)) {
                char p[PATH_MAX];
                snprintf(p, sizeof p, "%s/%s", shm_dir, de->d_name);
                if (unlink(p) == 0) gone++;
            }
        if (dd) closedir(dd);
        if (gone) fprintf(stderr, "winvm: removed %u shared-memory files left by earlier runs\n", gone);
    }
    int rb = rebind_shm((void *)V.virgl_renderer_init);
    /* DXMT shares textures with virglrenderer through shm_open too: same redirection, before
       Neptune loads it (same path, so the same image). */
    const char *dxmt = getenv("NPT_D3D11_LIBRARY_PATH");
    if (dxmt) {
        void *dh = dlopen(dxmt, RTLD_NOW | RTLD_LOCAL);
        void *sym = dh ? dlsym(dh, "D3D11CreateDevice") : NULL;
        int rb2 = sym ? rebind_shm(sym) : -1;
        LOG("shm_open rebound in dxmt: %d slots\n", rb2);
    }
    LOG("shm_open rebound in virglrenderer: %d slots (files in %s)\n", rb, shm_dir);
    return 0;
}

static int egl_setup(HvVgpu3d *s) {
    const EGLAttrib attrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    s->dpy = E.GetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, NULL, attrs);
    EGLint maj = 0, min = 0;
    if (!s->dpy || !E.Initialize(s->dpy, &maj, &min)) {
        snprintf(s->why, sizeof s->why, "eglInitialize failed (%#x)", E.GetError());
        return -1;
    }
    E.BindAPI(EGL_OPENGL_ES_API);
    const EGLint cattr[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                            EGL_RED_SIZE,     8,               EGL_GREEN_SIZE,      8,
                            EGL_BLUE_SIZE,    8,               EGL_ALPHA_SIZE,      8,
                            EGL_NONE};
    EGLint n = 0;
    if (!E.ChooseConfig(s->dpy, cattr, &s->cfg, 1, &n) || n < 1) {
        snprintf(s->why, sizeof s->why, "eglChooseConfig failed (%#x)", E.GetError());
        return -1;
    }
    const EGLint ctx_attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
    s->root = E.CreateContext(s->dpy, s->cfg, NULL, ctx_attr);
    if (!s->root) {
        snprintf(s->why, sizeof s->why, "root eglCreateContext failed (%#x)", E.GetError());
        return -1;
    }
    E.MakeCurrent(s->dpy, NULL, NULL, s->root);
    LOG("EGL %d.%d (ANGLE/Metal) ready\n", maj, min);
    return 0;
}

static virgl_renderer_gl_context cb_create_ctx(void *cookie, int scanout, struct virgl_renderer_gl_ctx_param *p) {
    HvVgpu3d *s = cookie;
    (void)scanout;
    const EGLint attr[] = {EGL_CONTEXT_MAJOR_VERSION, p->major_ver, EGL_CONTEXT_MINOR_VERSION, p->minor_ver, EGL_NONE};
    /* every context shares objects with the root one (as QEMU's display contexts do): vrend's
       resources, sync objects and sub-contexts must all see each other */
    EGLContext c = E.CreateContext(s->dpy, s->cfg, s->root, attr);
    LOG("gl context %d.%d shared=%d -> %p\n", p->major_ver, p->minor_ver, p->shared, c);
    return c;
}

static void cb_destroy_ctx(void *cookie, virgl_renderer_gl_context c) {
    HvVgpu3d *s = cookie;
    if (c) E.DestroyContext(s->dpy, c);
}

static int cb_make_current(void *cookie, int scanout, virgl_renderer_gl_context c) {
    HvVgpu3d *s = cookie;
    (void)scanout;
    return E.MakeCurrent(s->dpy, NULL, NULL, c) ? 0 : -1;
}

static void *cb_get_egl_display(void *cookie) {
    return ((HvVgpu3d *)cookie)->dpy;
}

static void push_fence(HvVgpu3d *s, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id) {
    FenceEv *f = malloc(sizeof *f);
    if (!f) return;
    *f = (FenceEv){.ctx_id = ctx_id, .ring_idx = ring_idx, .fence_id = fence_id};
    pthread_mutex_lock(&s->mu);
    f->next = s->events;
    s->events = f;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

static void cb_write_fence(void *cookie, uint32_t fence) {
    push_fence(cookie, 0, UINT32_MAX, fence);
}

static void cb_write_context_fence(void *cookie, uint32_t ctx_id, uint32_t ring_idx, uint64_t fence_id) {
    push_fence(cookie, ctx_id, ring_idx, fence_id);
}

static struct virgl_renderer_callbacks cbs = {
    .version = 4,
    .write_fence = cb_write_fence,
    .create_gl_context = cb_create_ctx,
    .destroy_gl_context = cb_destroy_ctx,
    .make_current = cb_make_current,
    .write_context_fence = cb_write_context_fence,
    .get_egl_display = cb_get_egl_display,
};

static void add_capset(HvVgpu3d *s, uint32_t id) {
    uint32_t ver = 0, size = 0;
    V.virgl_renderer_get_cap_set(id, &ver, &size);
    LOG("capset %u: version %u size %u\n", id, ver, size);
    if (size && s->ncapsets < 8) s->capsets[s->ncapsets++] = id;
}

static int renderer_init(HvVgpu3d *s) {
    if (load_libs(s) != 0 || egl_setup(s) != 0) return -1;
    if (!getenv("NPT_BACKEND")) setenv("NPT_BACKEND", "dxmt", 0);
    int flags = VIRGL_RENDERER_NEPTUNE | VIRGL_RENDERER_RENDER_SERVER | VIRGL_RENDERER_ASYNC_FENCE_CB |
                VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_NATIVE_SHARE_TEXTURE;
    if (getenv("HV_GPU3D_VENUS")) flags |= VIRGL_RENDERER_VENUS;
    int rc = V.virgl_renderer_init(s, flags, &cbs);
    if (rc != 0) {
        snprintf(s->why, sizeof s->why, "virgl_renderer_init failed: %d", rc);
        return -1;
    }
    add_capset(s, CAPSET_VIRGL);
    add_capset(s, CAPSET_VIRGL2);
    if (flags & VIRGL_RENDERER_VENUS) add_capset(s, CAPSET_VENUS);
    if (!getenv("HV_GPU3D_NO_NEPTUNE")) add_capset(s, CAPSET_NEPTUNE);
    return 0;
}

/* ---- resources ---- */
static Res3d *res_find(HvVgpu3d *s, uint32_t id) {
    if (!id) return NULL;
    for (int i = 0; i < MAX_RES3D; i++)
        if (s->res[i].id == id) return &s->res[i];
    return NULL;
}

static Res3d *res_new(HvVgpu3d *s, uint32_t id) {
    for (int i = 0; i < MAX_RES3D; i++)
        if (!s->res[i].id) {
            memset(&s->res[i], 0, sizeof s->res[i]);
            s->res[i].id = id;
            return &s->res[i];
        }
    return NULL;
}

/* Guest (addr, len) entries as host iovecs; RAM regions are contiguous in host memory. */
static int read_iov(HvVgpu3d *s, const HvVirtqElem *e, uint32_t off, uint32_t n, struct iovec **out) {
    HvVirtio *v = &s->g->vio;
    if (!n || n > MAX_ENTRIES) return -1;
    struct iovec *iov = calloc(n, sizeof *iov);
    uint8_t *raw = malloc((size_t)n * 16);
    if (!iov || !raw || hv_virtq_read(v, e, off, raw, n * 16) != n * 16) {
        free(iov);
        free(raw);
        return -1;
    }
    for (uint32_t i = 0; i < n; i++) {
        uint64_t a;
        uint32_t l;
        memcpy(&a, raw + 16 * i, 8);
        memcpy(&l, raw + 16 * i + 8, 4);
        void *p = hv_phys_ptr(v->m, a, l);
        if (!p) {
            WARN("backing entry %u (%#llx+%u) is not RAM\n", i, (unsigned long long)a, l);
            free(iov);
            free(raw);
            return -1;
        }
        iov[i].iov_base = p;
        iov[i].iov_len = l;
    }
    free(raw);
    *out = iov;
    return 0;
}

/* Every CPU drops its TLB (which may hold host pointers into blob memory) before that memory goes. */
static void sync_tlbs(HvVgpu3d *s) {
    HvMachine *m = s->g->vio.m;
    uint64_t seq[HV_MAX_CPUS] = {0};
    for (int i = 0; i < HV_MAX_CPUS; i++)
        if (m->cpus[i]) seq[i] = hv_cpu_post(m->cpus[i], HV_REQ_TLB_ALL);
    for (int i = 0; i < HV_MAX_CPUS; i++)
        if (m->cpus[i]) {
            hv_cpu_wake(m->cpus[i]);
            hv_cpu_sync(NULL, m->cpus[i], seq[i]);
        }
}

static void set_pages(HvVgpu3d *s, uint64_t off, uint64_t len, uint8_t *host) {
    for (uint64_t o = 0; o < len; o += 0x1000)
        __atomic_store_n(&s->page_host[(off + o) >> 12], host ? host + o : NULL, __ATOMIC_RELEASE);
}

static void unmap_blob(HvVgpu3d *s, Res3d *r) {
    if (!r->mapped) return;
    if (s->maps <= 12) { /* debugging: what both sides left in the shared memory */
        const uint32_t *w = (const uint32_t *)__atomic_load_n(&s->page_host[r->map_off >> 12], __ATOMIC_ACQUIRE);
        if (w) {
            char line[512];
            int n = 0, shown = 0;
            for (int i = 0; i < 1024 && shown < 24; i++)
                if (w[i]) n += snprintf(line + n, sizeof line - (size_t)n, " [%#x]=%#x", i * 4, w[i]), shown++;
            LOG("unmap blob %u: nonzero words:%s\n", r->id, shown ? line : " none");
        }
    }
    set_pages(s, r->map_off, r->map_len, NULL);
    sync_tlbs(s);
    V.virgl_renderer_resource_unmap(r->id);
    r->mapped = 0;
}

/* Gives up what 3D shows: its texture, and the override only while it is 3D's own read-back buffer. A 2D driver
   that started after a switch (hv_virtio_gpu_set_3d) may already show its own scanout by the time the worker gets
   here: that one stays. */
static void clear_scanout(HvVgpu3d *s) {
    if (s->scanout_handle) {
        V.virgl_renderer_release_handle_for_scanout(s->scanout_handle_type, s->scanout_handle);
        s->scanout_handle = NULL;
    }
    s->scanout_res = 0;
    hv_fb_display_set_texture(s->g->fb, NULL, 0, 0, 0, 0, 0, 0);
    if (s->readback) hv_fb_display_clear_override_if(s->g->fb, s->readback);
}

static void res_destroy(HvVgpu3d *s, Res3d *r) {
    if (r->id == s->scanout_res) clear_scanout(s);
    unmap_blob(s, r);
    struct iovec *iov = NULL;
    int n = 0;
    V.virgl_renderer_resource_detach_iov(r->id, &iov, &n);
    if (iov && iov != r->iov) free(iov);
    free(r->iov);
    V.virgl_renderer_resource_unref(r->id);
    memset(r, 0, sizeof *r);
}

/* ---- responses ---- */
typedef struct Out {
    struct Out *next;
    uint32_t epoch, len;
    HvVirtqElem e;
    uint8_t resp[];
} Out;

static Out *done_list;

static void respond(HvVgpu3d *s, const HvVirtqElem *e, const Hdr *h, uint32_t epoch, uint32_t type, const void *payload,
                    uint32_t plen) {
    Out *o = malloc(sizeof *o + HDR + plen);
    if (!o) return;
    o->epoch = epoch;
    o->e = *e;
    Hdr r = {.type = type, .ctx_id = h->ctx_id};
    if (h->flags & FLAG_FENCE) {
        r.flags = FLAG_FENCE | (h->flags & FLAG_RING_IDX);
        r.fence_id = h->fence_id;
        r.ring_idx = h->ring_idx;
    }
    memcpy(o->resp, &r, HDR);
    if (plen) memcpy(o->resp + HDR, payload, plen);
    o->len = HDR + plen;
    o->next = done_list;
    done_list = o;
    (void)s;
}

/* Under the device lock: put the answers on the used ring (oldest first). */
static void flush_done(HvVgpu3d *s) {
    if (!done_list) return;
    Out *rev = NULL;
    while (done_list) {
        Out *o = done_list;
        done_list = o->next;
        o->next = rev;
        rev = o;
    }
    HvVirtio *v = &s->g->vio;
    hv_dev_lock(v->m);
    pthread_mutex_lock(&s->mu);
    uint32_t epoch = s->epoch;
    pthread_mutex_unlock(&s->mu);
    int any = 0;
    while (rev) {
        Out *o = rev;
        rev = o->next;
        if (o->epoch == epoch && (v->status & 4)) {
            uint32_t n = hv_virtq_write(v, &o->e, 0, o->resp, o->len);
            hv_virtq_push(v, 0, &o->e, n);
            any = 1;
        }
        free(o);
    }
    if (any) hv_virtio_interrupt(v);
    hv_dev_unlock(v->m);
    if (any) hv_machine_wake(v->m);
}

/* ---- commands ---- */
static void set_scanout_texture(HvVgpu3d *s, uint32_t res, void *tex, int type, int owned, uint32_t tw, uint32_t th,
                                const uint32_t r[4]) {
    if (s->scanout_handle) {
        V.virgl_renderer_release_handle_for_scanout(s->scanout_handle_type, s->scanout_handle);
        s->scanout_handle = NULL;
    }
    if (owned) {
        s->scanout_handle = tex;
        s->scanout_handle_type = type;
    }
    s->scanout_res = res;
    s->sc_w = tw;
    s->sc_h = th;
    hv_fb_display_set_override(s->g->fb, NULL, 0, 0, 0);
    hv_fb_display_set_texture(s->g->fb, tex, tw, th, r[0], r[1], r[2], r[3]);
}

/* A scanout virgl has no Metal texture for: copy it back on every flush. */
static void readback_scanout(HvVgpu3d *s) {
    if (!s->scanout_res || !s->sc_w || !s->sc_h) return;
    size_t need = (size_t)s->sc_w * s->sc_h * 4;
    if (need > s->readback_len) {
        uint8_t *nb = malloc(need);
        if (!nb) return;
        hv_fb_display_set_override(s->g->fb, NULL, 0, 0, 0);
        free(s->readback);
        s->readback = nb;
        s->readback_len = need;
    }
    struct iovec iov = {s->readback, need};
    struct virgl_box { uint32_t x, y, z, w, h, d; } box = {0, 0, 0, s->sc_w, s->sc_h, 1};
    V.virgl_renderer_transfer_read_iov(s->scanout_res, 0, 0, s->sc_w * 4, 0, (void *)&box, 0, &iov, 1);
    hv_fb_display_set_override(s->g->fb, s->readback, s->sc_w, s->sc_h, s->sc_w * 4);
}

/* ---- live contexts (worker only) ---- */
static int live_index(HvVgpu3d *s, uint32_t id) {
    for (uint32_t i = 0; i < s->nlive; i++)
        if (s->live[i].id == id) return (int)i;
    return -1;
}

/* One line per context create or destroy (a few a minute; stderr is winvm.log, which a crash keeps). */
static void live_log(HvVgpu3d *s, const char *what, uint32_t id, uint32_t capset, const char *name) {
    char ids[256];
    int n = 0;
    ids[0] = 0;
    for (uint32_t i = 0; i < s->nlive && n < (int)sizeof ids - 12; i++)
        n += snprintf(ids + n, sizeof ids - (size_t)n, " %u%s", s->live[i].id, s->live[i].capset == CAPSET_NEPTUNE ? "n" : "");
    WARN("ctx %u %s (capset %u%s%s): live %u, neptune %u, peak %u, destroyed %llu, failed %llu, unknown %llu:%s\n", id,
         what, capset, *name ? " " : "", name, s->nlive, s->nlive_npt, s->peak_live, (unsigned long long)s->ctx_destroyed,
         (unsigned long long)s->ctx_failed, (unsigned long long)s->ctx_destroy_unknown, ids);
}

/* Returns 1 if the request was answered (or parked) here, 0 to answer RESP_OK_NODATA / error. */
static uint32_t process(HvVgpu3d *s, const HvVirtqElem *e, const Hdr *h, uint32_t epoch, uint8_t *b, uint32_t got,
                        int *answered) {
    HvVirtio *v = &s->g->vio;
    *answered = 0;
    V.virgl_renderer_force_ctx_0();
    switch (h->type) {
    case CMD_GET_DISPLAY_INFO:
    case CMD_GET_EDID: {
        static uint8_t resp[HDR + 8 + 1024];
        pthread_mutex_lock(&s->g->mu);
        uint32_t n = hv_virtio_gpu_handle2d(s->g, e, resp, sizeof resp);
        pthread_mutex_unlock(&s->g->mu);
        Hdr r;
        memcpy(&r, resp, sizeof r);
        respond(s, e, h, epoch, r.type, resp + HDR, n - HDR);
        *answered = 1;
        return 0;
    }
    case CMD_CTX_CREATE: {
        uint32_t nlen, init;
        memcpy(&nlen, b, 4);
        memcpy(&init, b + 4, 4);
        char name[65] = {0};
        memcpy(name, b + 8, 64);
        if (nlen > 64) nlen = 64;
        int rc = init ? V.virgl_renderer_context_create_with_flags(h->ctx_id, init, nlen, name)
                      : V.virgl_renderer_context_create(h->ctx_id, nlen, name);
        s->ctxs++;
        LOG("ctx %u create capset %u '%s' -> %d\n", h->ctx_id, init & 0xff, name, rc);
        if (rc) {
            s->ctx_failed++;
            WARN("context %u (capset %u '%s') could not be created: %d (errno %d %s)\n", h->ctx_id, init & 0xff, name, rc, errno, strerror(errno));
            return RESP_ERR_UNSPEC;
        }
        if (live_index(s, h->ctx_id) < 0 && s->nlive < sizeof s->live / sizeof s->live[0]) {
            s->live[s->nlive].id = h->ctx_id;
            s->live[s->nlive].capset = (uint8_t)(init & 0xff);
            s->nlive++;
            if ((init & 0xff) == CAPSET_NEPTUNE) s->nlive_npt++;
            if (s->nlive > s->peak_live) s->peak_live = s->nlive;
        }
        live_log(s, "created", h->ctx_id, init & 0xff, name);
        return 0;
    }
    case CMD_CTX_DESTROY: {
        /* Its rings go with it: a ring fence still parked on it would never be written, and its
           request (the guest's buffer) would never come back. */
        int n = 0;
        for (Parked **pp = &s->fenceq; *pp;) {
            Parked *p = *pp;
            if ((p->h.flags & FLAG_RING_IDX) && p->h.ctx_id == h->ctx_id) {
                *pp = p->next;
                respond(s, &p->e, &p->h, p->epoch, RESP_OK_NODATA, NULL, 0);
                s->fences++;
                free(p);
                n++;
            } else {
                pp = &p->next;
            }
        }
        LOG("ctx %u destroy (%d ring fences still parked on it answered)\n", h->ctx_id, n);
        V.virgl_renderer_context_destroy(h->ctx_id);
        int li = live_index(s, h->ctx_id);
        uint32_t cap = li >= 0 ? s->live[li].capset : 0;
        if (li >= 0) {
            if (cap == CAPSET_NEPTUNE) s->nlive_npt--;
            s->live[li] = s->live[--s->nlive];
            s->ctx_destroyed++;
        } else {
            s->ctx_destroy_unknown++;
        }
        live_log(s, li >= 0 ? "destroyed" : "destroyed (not known as live)", h->ctx_id, cap, "");
        return 0;
    }
    case CMD_CTX_ATTACH_RESOURCE:
    case CMD_CTX_DETACH_RESOURCE: {
        uint32_t id;
        memcpy(&id, b, 4);
        if (h->type == CMD_CTX_ATTACH_RESOURCE) V.virgl_renderer_ctx_attach_resource(h->ctx_id, id);
        else V.virgl_renderer_ctx_detach_resource(h->ctx_id, id);
        return 0;
    }
    case CMD_RESOURCE_CREATE_2D:
    case CMD_RESOURCE_CREATE_3D: {
        uint32_t a[12] = {0};
        memcpy(a, b, h->type == CMD_RESOURCE_CREATE_2D ? 16 : 48);
        if (!a[0] || res_find(s, a[0])) return RESP_ERR_INVALID_RESOURCE_ID;
        Res3d *r = res_new(s, a[0]);
        if (!r) return RESP_ERR_OUT_OF_MEMORY;
        struct virgl_renderer_resource_create_args args = {0};
        args.handle = a[0];
        if (h->type == CMD_RESOURCE_CREATE_2D) {
            args.target = 2;
            args.format = a[1];
            args.bind = 1 << 1;
            args.width = a[2];
            args.height = a[3];
            args.depth = 1;
            args.array_size = 1;
            args.flags = 1; /* Y_0_TOP */
        } else {
            args.target = a[1];
            args.format = a[2];
            args.bind = a[3];
            args.width = a[4];
            args.height = a[5];
            args.depth = a[6];
            args.array_size = a[7];
            args.last_level = a[8];
            args.nr_samples = a[9];
            args.flags = a[10];
        }
        int rc = V.virgl_renderer_resource_create(&args, NULL, 0);
        if (rc) {
            memset(r, 0, sizeof *r);
            return RESP_ERR_UNSPEC;
        }
        return 0;
    }
    case CMD_RESOURCE_UNREF: {
        uint32_t id;
        memcpy(&id, b, 4);
        Res3d *r = res_find(s, id);
        if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
        res_destroy(s, r);
        return 0;
    }
    case CMD_RESOURCE_ATTACH_BACKING: {
        uint32_t a[2];
        memcpy(a, b, 8);
        Res3d *r = res_find(s, a[0]);
        if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
        struct iovec *iov;
        if (read_iov(s, e, HDR + 8, a[1], &iov) != 0) return RESP_ERR_UNSPEC;
        if (V.virgl_renderer_resource_attach_iov(a[0], iov, (int)a[1]) != 0) {
            free(iov);
            return RESP_ERR_UNSPEC;
        }
        return 0;
    }
    case CMD_RESOURCE_DETACH_BACKING: {
        uint32_t id;
        memcpy(&id, b, 4);
        struct iovec *iov = NULL;
        int n = 0;
        V.virgl_renderer_resource_detach_iov(id, &iov, &n);
        Res3d *r = res_find(s, id);
        if (iov && (!r || iov != r->iov)) free(iov);
        if (r && iov == r->iov) r->iov = NULL;
        return 0;
    }
    case CMD_TRANSFER_TO_HOST_2D: {
        uint32_t rc4[4], id;
        uint64_t off;
        memcpy(rc4, b, 16);
        memcpy(&off, b + 16, 8);
        memcpy(&id, b + 24, 4);
        struct { uint32_t x, y, z, w, h, d; } box = {rc4[0], rc4[1], 0, rc4[2], rc4[3], 1};
        V.virgl_renderer_transfer_write_iov(id, 0, 0, 0, 0, (void *)&box, off, NULL, 0);
        return 0;
    }
    case CMD_TRANSFER_TO_HOST_3D:
    case CMD_TRANSFER_FROM_HOST_3D: {
        uint32_t box[6], id, level, stride, lstride;
        uint64_t off;
        memcpy(box, b, 24);
        memcpy(&off, b + 24, 8);
        memcpy(&id, b + 32, 4);
        memcpy(&level, b + 36, 4);
        memcpy(&stride, b + 40, 4);
        memcpy(&lstride, b + 44, 4);
        if (h->type == CMD_TRANSFER_TO_HOST_3D)
            V.virgl_renderer_transfer_write_iov(id, h->ctx_id, (int)level, stride, lstride, (void *)box, off, NULL, 0);
        else
            V.virgl_renderer_transfer_read_iov(id, h->ctx_id, level, stride, lstride, (void *)box, off, NULL, 0);
        return 0;
    }
    case CMD_SUBMIT_3D: {
        uint32_t size;
        memcpy(&size, b, 4);
        if (size > MAX_SUBMIT || (size & 3)) return RESP_ERR_INVALID_PARAMETER;
        void *buf = malloc(size ? size : 4);
        if (!buf) return RESP_ERR_OUT_OF_MEMORY;
        if (hv_virtq_read(v, e, HDR + 8, buf, size) != size) {
            free(buf);
            return RESP_ERR_INVALID_PARAMETER;
        }
        s->submits++;
        s->submit_bytes += size;
        if (s->submits <= 40) {
            const uint32_t *w = buf;
            char line[256];
            int n = 0;
            for (uint32_t i = 0; i < size / 4 && i < 14; i++) n += snprintf(line + n, sizeof line - (size_t)n, " %x", w[i]);
            LOG("submit ctx %u %u bytes:%s\n", h->ctx_id, size, line);
        }
        int rc = V.virgl_renderer_submit_cmd(buf, (int)h->ctx_id, (int)(size / 4));
        free(buf);
        if (rc) { /* answered as before (QEMU does not fail it either), but no longer silently */
            s->submit_errors++;
            if (s->submit_errors <= 20) WARN("submit ctx %u (%u bytes) failed: %d\n", h->ctx_id, size, rc);
        }
        return 0;
    }
    case CMD_GET_CAPSET_INFO: {
        uint32_t idx;
        memcpy(&idx, b, 4);
        uint32_t out[4] = {0};
        if (idx < s->ncapsets) {
            out[0] = s->capsets[idx];
            V.virgl_renderer_get_cap_set(out[0], &out[1], &out[2]);
        }
        respond(s, e, h, epoch, RESP_OK_CAPSET_INFO, out, sizeof out);
        *answered = 1;
        return 0;
    }
    case CMD_GET_CAPSET: {
        uint32_t id, ver, max_ver = 0, max_size = 0;
        memcpy(&id, b, 4);
        memcpy(&ver, b + 4, 4);
        V.virgl_renderer_get_cap_set(id, &max_ver, &max_size);
        if (!max_size || max_size > (1u << 20)) return RESP_ERR_INVALID_PARAMETER;
        uint8_t *caps = calloc(1, max_size);
        if (!caps) return RESP_ERR_OUT_OF_MEMORY;
        V.virgl_renderer_fill_caps(id, ver, caps);
        respond(s, e, h, epoch, RESP_OK_CAPSET, caps, max_size);
        free(caps);
        *answered = 1;
        return 0;
    }
    case CMD_RESOURCE_CREATE_BLOB: {
        uint32_t id, mem, flags, nent;
        uint64_t blob_id, size;
        memcpy(&id, b, 4);
        memcpy(&mem, b + 4, 4);
        memcpy(&flags, b + 8, 4);
        memcpy(&nent, b + 12, 4);
        memcpy(&blob_id, b + 16, 8);
        memcpy(&size, b + 24, 8);
        if (!id || res_find(s, id)) return RESP_ERR_INVALID_RESOURCE_ID;
        Res3d *r = res_new(s, id);
        if (!r) return RESP_ERR_OUT_OF_MEMORY;
        r->is_blob = 1;
        if (mem != BLOB_MEM_HOST3D && nent) {
            if (read_iov(s, e, HDR + 32, nent, &r->iov) != 0) {
                memset(r, 0, sizeof *r);
                return RESP_ERR_UNSPEC;
            }
            r->niov = (int)nent;
        }
        struct virgl_renderer_resource_create_blob_args a = {
            .res_handle = id, .ctx_id = h->ctx_id, .blob_mem = mem, .blob_flags = flags,
            .blob_id = blob_id, .size = size, .iovecs = r->iov, .num_iovs = (uint32_t)r->niov};
        int rc = V.virgl_renderer_resource_create_blob(&a);
        s->blobs++;
        if (rc) {
            WARN("blob %u (mem %u flags %#x id %llu size %llu) create failed: %d\n", id, mem, flags,
                 (unsigned long long)blob_id, (unsigned long long)size, rc);
            free(r->iov);
            memset(r, 0, sizeof *r);
            return RESP_ERR_UNSPEC;
        }
        return 0;
    }
    case CMD_RESOURCE_MAP_BLOB: {
        uint32_t id;
        uint64_t off;
        memcpy(&id, b, 4);
        memcpy(&off, b + 8, 8);
        Res3d *r = res_find(s, id);
        if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
        if (r->mapped) return RESP_ERR_INVALID_PARAMETER;
        if (!s->win || (off & 0xfff) || off >= s->win_size) {
            WARN("map blob %u at %#llx: not 4K aligned or outside the %lluMB window\n", id,
                 (unsigned long long)off, (unsigned long long)(s->win_size >> 20));
            return RESP_ERR_INVALID_PARAMETER;
        }
        void *data = NULL;
        uint64_t size = 0;
        int rc = V.virgl_renderer_resource_map(id, &data, &size);
        if (rc || !data || !size) {
            WARN("map blob %u: virgl map failed %d\n", id, rc);
            return RESP_ERR_UNSPEC;
        }
        uint64_t len = (size + 0xfff) & ~0xfffull;
        if (off + len > s->win_size) {
            V.virgl_renderer_resource_unmap(id);
            return RESP_ERR_INVALID_PARAMETER;
        }
        /* the guest's 4 KB pages at the offset now lead to the blob's memory */
        /* No TLB flush here: unmap_blob flushed when these pages were last taken away, and until this
           command is answered the guest has no mapping of the range to have cached. */
        set_pages(s, off, len, data);
        r->mapped = 1;
        r->map_off = off;
        r->map_len = len;
        s->maps++;
        if (s->maps <= 20) LOG("map blob %u at %#llx (%lluKB)\n", id, (unsigned long long)off, (unsigned long long)(len >> 10));
        uint32_t info[2] = {0, 0};
        V.virgl_renderer_resource_get_map_info(id, &info[0]);
        respond(s, e, h, epoch, RESP_OK_MAP_INFO, info, sizeof info);
        *answered = 1;
        return 0;
    }
    case CMD_RESOURCE_UNMAP_BLOB: {
        uint32_t id;
        memcpy(&id, b, 4);
        Res3d *r = res_find(s, id);
        if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
        unmap_blob(s, r);
        return 0;
    }
    case CMD_SET_SCANOUT: {
        uint32_t rc4[4], sid, id;
        memcpy(rc4, b, 16);
        memcpy(&sid, b + 16, 4);
        memcpy(&id, b + 20, 4);
        if (sid != 0) return RESP_ERR_INVALID_SCANOUT_ID;
        if (!id || !rc4[2] || !rc4[3]) {
            if (s->scanout_res) clear_scanout(s);
            return 0;
        }
        struct virgl_renderer_resource_info_ext ext;
        memset(&ext, 0, sizeof ext);
        ext.version = VIRGL_RENDERER_RESOURCE_INFO_EXT_VERSION;
        if (V.virgl_renderer_resource_get_info_ext(id, &ext) != 0) return RESP_ERR_INVALID_RESOURCE_ID;
        if (ext.native_type == VIRGL_NATIVE_HANDLE_METAL_TEXTURE && ext.native_handle) {
            set_scanout_texture(s, id, ext.native_handle, 0, 0, ext.base.width, ext.base.height, rc4);
        } else {
            set_scanout_texture(s, id, NULL, 0, 0, ext.base.width, ext.base.height, rc4);
            readback_scanout(s);
        }
        LOG("scanout -> res %u %ux%u (%s)\n", id, ext.base.width, ext.base.height,
            ext.native_type == VIRGL_NATIVE_HANDLE_METAL_TEXTURE ? "metal" : "readback");
        return 0;
    }
    case CMD_SET_SCANOUT_BLOB: {
        uint32_t a[18];
        memcpy(a, b, sizeof a); /* r[4], scanout, res, w, h, format, pad, strides[4], offsets[4] */
        if (a[4] != 0) return RESP_ERR_INVALID_SCANOUT_ID;
        if (!a[5]) {
            if (s->scanout_res) clear_scanout(s);
            return 0;
        }
        virgl_renderer_native_handle hnd = NULL;
        enum virgl_renderer_native_handle_type t =
            V.virgl_renderer_create_handle_for_scanout(a[5], a[6], a[7], a[8], a[9], a[10], a[14], &hnd);
        if (t == VIRGL_NATIVE_HANDLE_METAL_TEXTURE && hnd) {
            set_scanout_texture(s, a[5], hnd, t, 1, a[6], a[7], a);
            LOG("scanout blob -> res %u %ux%u fmt %u (metal)\n", a[5], a[6], a[7], a[8]);
            return 0;
        }
        if (t != VIRGL_NATIVE_HANDLE_NONE && hnd) V.virgl_renderer_release_handle_for_scanout(t, hnd);
        WARN("scanout blob res %u: no Metal texture (type %d)\n", a[5], t);
        return RESP_ERR_UNSPEC;
    }
    case CMD_RESOURCE_FLUSH: {
        uint32_t id;
        memcpy(&id, b + 16, 4);
        if (id && id == s->scanout_res) {
            s->g->flushes++;
            if (!s->scanout_handle && !s->g->fb->ovr_tex) readback_scanout(s);
            hv_fb_display_override_flushed(s->g->fb);
        }
        return 0;
    }
    default:
        LOG("unhandled command %#x\n", h->type);
        return RESP_ERR_UNSPEC;
    }
    (void)got;
}

static uint64_t mono_ns(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

/* Background drain (worker): answers every parked fence that is due, oldest first, and logs the trip's totals when
   drain goes off. */
static void drain_parked(HvVgpu3d *s, const HvVgpu3dDrain *d) {
    if (!d->on) {
        if (s->drain_was_on) {
            s->drain_was_on = 0;
            WARN("background drain off: %llu fences answered by drain this time (oldest %llu ms; %llu ring, %llu global "
                 "in all); %s parked now\n",
                 (unsigned long long)s->drained_trip, (unsigned long long)(s->drain_max_age_ns / 1000000ull),
                 (unsigned long long)s->drained_ring, (unsigned long long)s->drained_global, s->fenceq ? "some" : "none");
        }
        return;
    }
    if (!s->drain_was_on) {
        s->drain_was_on = 1;
        s->drained_trip = 0;
        s->drain_max_age_ns = 0;
    }
    if (!s->fenceq) return;
    uint64_t now = mono_ns();
    Parked *due = NULL; /* the queue is newest first: taken off in that order and pushed here, it is oldest first */
    for (Parked **pp = &s->fenceq; *pp;) {
        Parked *p = *pp;
        if (hv_vgpu3d_drain_due(d, p->parked_ns, now)) {
            *pp = p->next;
            p->next = due;
            due = p;
        } else {
            pp = &p->next;
        }
    }
    while (due) {
        Parked *p = due;
        due = p->next;
        int ring = (p->h.flags & FLAG_RING_IDX) != 0;
        uint64_t age = now - p->parked_ns;
        if (age > s->drain_max_age_ns) s->drain_max_age_ns = age;
        if (ring) s->drained_ring++;
        else {
            s->drained_global++;
            s->nparked_global--;
        }
        s->drained_trip++;
        if (s->drained_trip <= 20)
            WARN("background drain: %s fence %llu (ctx %u ring %u, cmd %#x) answered after %llu ms\n", ring ? "ring" : "global",
                 (unsigned long long)p->h.fence_id, p->h.ctx_id, ring ? p->h.ring_idx : 0, p->h.type,
                 (unsigned long long)(age / 1000000ull));
        else if (s->drained_trip == 21)
            WARN("background drain: more fences answered (the count is in the trip's summary and the status line)\n");
        respond(s, &p->e, &p->h, p->epoch, RESP_OK_NODATA, NULL, 0);
        s->fences++;
        free(p);
    }
}

static void complete_fences(HvVgpu3d *s, const FenceEv *f) {
    Parked **pp = &s->fenceq;
    while (*pp) {
        Parked *p = *pp;
        int match;
        if (f->ring_idx == UINT32_MAX)
            match = !(p->h.flags & FLAG_RING_IDX) && p->h.fence_id <= f->fence_id;
        else
            match = (p->h.flags & FLAG_RING_IDX) && p->h.ctx_id == f->ctx_id && p->h.ring_idx == f->ring_idx &&
                    p->h.fence_id <= f->fence_id;
        if (match) {
            *pp = p->next;
            if (!(p->h.flags & FLAG_RING_IDX)) s->nparked_global--;
            respond(s, &p->e, &p->h, p->epoch, RESP_OK_NODATA, NULL, 0);
            s->fences++;
            free(p);
        } else {
            pp = &p->next;
        }
    }
}

/* A driver reset: every context and resource goes (virgl_renderer_reset). The renderer itself stays, idle, so the
   next 3D driver start (after a switch back, hv_virtio_gpu_set_3d) finds it ready: it is never torn down and made
   again within one run of the app. A real reset runs Metal work; see below for when it is skipped. */
static void renderer_reset(HvVgpu3d *s) {
    /* A renderer that did nothing since its last reset has nothing to drop, so the reset is skipped: after a switch
       to 2D, Windows (and so its driver resets: a restart, Windows Update, a TDR) can run in the background, where
       no Metal work may happen. The first reset after real 3D use still runs, and that one follows a 3D driver, so
       it happens in the foreground (the switch itself restarts the adapter). */
    uint32_t nres = 0;
    for (int i = 0; i < MAX_RES3D; i++)
        if (s->res[i].id) nres++;
    HvVgpu3dUse use = {.used = s->used, .live_ctxs = s->nlive, .resources = nres, .scanout = s->scanout_res || s->scanout_handle,
                       .parked = s->nparked_global + (s->fenceq != NULL)};
    if (!hv_vgpu3d_reset_needed(&use)) {
        s->resets_skipped++;
        return;
    }
    s->resets++;
    s->used = 0;
    clear_scanout(s);
    for (int i = 0; i < MAX_RES3D; i++)
        if (s->res[i].id) unmap_blob(s, &s->res[i]);
    if (s->nlive) WARN("renderer reset: %u live contexts (%u neptune) go with it\n", s->nlive, s->nlive_npt);
    s->nlive = s->nlive_npt = 0;
    V.virgl_renderer_reset();
    for (int i = 0; i < MAX_RES3D; i++) {
        free(s->res[i].iov);
        memset(&s->res[i], 0, sizeof s->res[i]);
    }
    uint32_t dropped = 0;
    while (s->fenceq) {
        Parked *p = s->fenceq;
        s->fenceq = p->next;
        free(p);
        dropped++;
    }
    s->nparked_global = 0;
    if (dropped && s->drain_was_on) WARN("renderer reset in background drain: %u parked fences dropped\n", dropped);
    if (s->page_host) {
        memset(s->page_host, 0, (s->win_size >> 12) * sizeof *s->page_host);
        sync_tlbs(s);
    }
    LOG("renderer reset\n");
}

/* The hardware cursor's new image: read it out of its resource (the guest transferred it there first). */
static void fetch_cursor(HvVgpu3d *s, uint32_t res) {
    struct virgl_renderer_resource_info info;
    memset(&info, 0, sizeof info);
    uint32_t w = 64, h = 64;
    if (V.virgl_renderer_resource_get_info((int)res, &info) == 0 && info.width && info.height) {
        w = info.width < 64 ? info.width : 64;
        h = info.height < 64 ? info.height : 64;
    }
    static uint32_t px[64 * 64];
    memset(px, 0, sizeof px);
    struct iovec iov = {px, (size_t)w * h * 4};
    struct { uint32_t x, y, z, w, h, d; } box = {0, 0, 0, w, h, 1};
    V.virgl_renderer_force_ctx_0();
    if (V.virgl_renderer_transfer_read_iov(res, 0, 0, w * 4, 0, (void *)&box, 0, &iov, 1) != 0) {
        WARN("cursor res %u: no pixels\n", res);
        return;
    }
    hv_fb_display_cursor_image(s->g->fb, px, w, h);
}

void hv_vgpu3d_cursor(HvVgpu3d *s, uint32_t res) {
    pthread_mutex_lock(&s->mu);
    s->cursor_req = res;
    s->cursor_pending = 1;
    s->kicked = 1;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

static void *worker(void *arg) {
    HvVgpu3d *s = arg;
    pthread_setname_np("virtio-gpu3d");
    if (renderer_init(s) != 0) {
        WARN("3D unavailable: %s\n", s->why);
        pthread_mutex_lock(&s->mu);
        s->init_ok = -1;
        pthread_cond_broadcast(&s->cv);
        pthread_mutex_unlock(&s->mu);
        return NULL;
    }
    pthread_mutex_lock(&s->mu);
    s->init_ok = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->mu);

    HvVirtio *v = &s->g->vio;
    static uint8_t req[HDR + 64 + 32];
    for (;;) {
        pthread_mutex_lock(&s->mu);
        /* background drain: wake when the oldest parked fence is due (the queue is the worker's own) */
        uint64_t drain_wake = UINT64_MAX;
        for (Parked *p = s->fenceq; p && s->drain.on; p = p->next) {
            uint64_t t = hv_vgpu3d_drain_due_at(&s->drain, p->parked_ns);
            if (t < drain_wake) drain_wake = t;
        }
        while (!s->kicked && !s->events && s->done_epoch == s->epoch) {
            if (s->nparked_global || drain_wake != UINT64_MAX) {
                uint64_t now = mono_ns();
                uint64_t wait = s->nparked_global ? 1000000ull : 1000000000ull;
                if (drain_wake != UINT64_MAX) {
                    uint64_t left = drain_wake > now ? drain_wake - now : 0;
                    if (left < wait) wait = left;
                }
                if (!wait) break;
                struct timespec ts;
                clock_gettime(CLOCK_REALTIME, &ts);
                ts.tv_sec += (time_t)(wait / 1000000000ull);
                ts.tv_nsec += (long)(wait % 1000000000ull);
                if (ts.tv_nsec >= 1000000000) ts.tv_sec++, ts.tv_nsec -= 1000000000;
                if (pthread_cond_timedwait(&s->cv, &s->mu, &ts) == ETIMEDOUT) break;
            } else {
                pthread_cond_wait(&s->cv, &s->mu);
            }
        }
        HvVgpu3dDrain drain = s->drain;
        s->kicked = 0;
        int cursor_pending = s->cursor_pending;
        uint32_t cursor_res = s->cursor_req;
        s->cursor_pending = 0;
        FenceEv *ev = s->events;
        s->events = NULL;
        uint32_t epoch = s->epoch;
        int need_reset = s->done_epoch != epoch;
        pthread_mutex_unlock(&s->mu);

        if (need_reset) {
            renderer_reset(s);
            pthread_mutex_lock(&s->mu);
            s->done_epoch = epoch;
            pthread_mutex_unlock(&s->mu);
        }
        while (ev) {
            FenceEv *n = ev->next;
            complete_fences(s, ev);
            free(ev);
            ev = n;
        }
        if (s->nparked_global) V.virgl_renderer_poll(); /* global fences retire from here */
        drain_parked(s, &drain);
        if (cursor_pending) {
            s->used = 1;
            fetch_cursor(s, cursor_res);
        }

        /* take what the driver queued */
        for (;;) {
            Parked *p = malloc(sizeof *p);
            if (!p) break;
            hv_dev_lock(v->m);
            /* Only a driver that took VIRGL is the worker's: after a switch to 2D the control queue is the 2D
               handler's (virtio_gpu.c notify), even when a late fence event or reset wakes this thread. */
            int got = (v->status & 4) && (v->driver_features & F_VIRGL) ? hv_virtq_pop(v, 0, &p->e) : 0;
            hv_dev_unlock(v->m);
            if (got <= 0) {
                free(p);
                break;
            }
            memset(req, 0, sizeof req);
            uint32_t n = hv_virtq_read(v, &p->e, 0, req, sizeof req);
            memcpy(&p->h, req, sizeof p->h);
            p->epoch = epoch;
            s->cmds++;
            if (n < HDR) {
                respond(s, &p->e, &p->h, epoch, RESP_ERR_UNSPEC, NULL, 0);
                free(p);
                continue;
            }
            if (s->cmds <= 200) LOG("cmd #%llu %#x ctx %u flags %#x\n", (unsigned long long)s->cmds, p->h.type, p->h.ctx_id, p->h.flags);
            int answered = 0;
            s->used = 1;
            /* not under g->mu: process() may wait for every CPU (sync_tlbs), and a CPU may be waiting for g->mu */
            uint32_t err = process(s, &p->e, &p->h, epoch, req + HDR, n - HDR, &answered);
            if (answered) {
                free(p);
                continue;
            }
            if (err) {
                s->errors++;
                if (s->errors <= 50) WARN("cmd %#x ctx %u failed: %#x\n", p->h.type, p->h.ctx_id, err);
                respond(s, &p->e, &p->h, epoch, err, NULL, 0);
                free(p);
                continue;
            }
            if (!(p->h.flags & FLAG_FENCE)) {
                respond(s, &p->e, &p->h, epoch, RESP_OK_NODATA, NULL, 0);
                free(p);
                continue;
            }
            /* fenced: answered when the renderer retires it */
            if (p->h.flags & FLAG_RING_IDX) {
                s->fenced_ring++;
                int rc = V.virgl_renderer_context_create_fence(p->h.ctx_id, VIRGL_RENDERER_FENCE_FLAG_MERGEABLE,
                                                               p->h.ring_idx, p->h.fence_id);
                if (rc != 0) {
                    s->errors++;
                    if (s->errors <= 50) WARN("ctx %u ring %u fence %llu: create_fence failed %d\n", p->h.ctx_id,
                                              p->h.ring_idx, (unsigned long long)p->h.fence_id, rc);
                    respond(s, &p->e, &p->h, epoch, RESP_OK_NODATA, NULL, 0); /* dead context: never retires */
                    free(p);
                    continue;
                }
            } else {
                /* A global fence waits only for vrend's (ctx 0) GL work, not for the commands' own context:
                   log which contexts (capsets) send them, to tell whether a Neptune context ever does. */
                s->fenced_global++;
                if (s->fenced_global <= 20)
                    LOG("global fence %llu: cmd %#x ctx %u (capset %u)\n", (unsigned long long)p->h.fence_id,
                        p->h.type, p->h.ctx_id, live_index(s, p->h.ctx_id) >= 0 ? s->live[live_index(s, p->h.ctx_id)].capset : 0);
                V.virgl_renderer_create_fence((int)p->h.fence_id, p->h.type);
                s->nparked_global++;
            }
            p->parked_ns = mono_ns();
            p->next = s->fenceq;
            s->fenceq = p;
        }
        flush_done(s);
    }
    return NULL;
}

/* ---- public ---- */
HvVgpu3d *hv_vgpu3d_create(HvVirtioGpu *g) {
    if (getenv("HV_NO_GPU3D") || !getenv("HV_GPU3D_FRAMEWORKS")) return NULL;
    HvVgpu3d *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->g = g;
    s->ram_idx = -1;
    pthread_mutex_init(&s->mu, NULL);
    pthread_cond_init(&s->cv, NULL);
    const char *hm = getenv("HV_GPU3D_HOSTMEM_MB");
    s->win_size = hm ? (uint64_t)strtoull(hm, NULL, 0) << 20 : HOSTMEM_DEFAULT;
    if (s->win_size < (64ull << 20)) s->win_size = 64ull << 20;
    /* a power of two for the BAR */
    uint64_t p2 = 1;
    while (p2 < s->win_size) p2 <<= 1;
    s->win_size = p2;
    if (pre_win && pre_win_size && !(pre_win_size & (pre_win_size - 1))) {
        s->win = pre_win;
        s->win_size = pre_win_size;
    } else {
        s->win = mmap(NULL, s->win_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    }
    s->page_host = calloc(s->win_size >> 12, sizeof *s->page_host);
    if (s->win == MAP_FAILED || !s->page_host) {
        WARN("hostmem window %lluMB: %s\n", (unsigned long long)(s->win_size >> 20), strerror(errno));
        free(s);
        return NULL;
    }
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 8u << 20);
    pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
    if (pthread_create(&s->th, &at, worker, s) != 0) {
        munmap(s->win, s->win_size);
        free(s);
        return NULL;
    }
    pthread_attr_destroy(&at);
    pthread_mutex_lock(&s->mu);
    while (!s->init_ok) pthread_cond_wait(&s->cv, &s->mu);
    int ok = s->init_ok > 0;
    pthread_mutex_unlock(&s->mu);
    if (!ok) {
        /* the worker has exited; keep the struct for the describe line, report no 3D */
        munmap(s->win, s->win_size);
        s->win = NULL;
        g_state = s;
        return NULL;
    }
    g_state = s;
    fprintf(stderr, "winvm: virtio-gpu 3D ready (%u capsets, hostmem %lluMB)\n", s->ncapsets,
            (unsigned long long)(s->win_size >> 20));
    return s;
}

uint64_t hv_vgpu3d_features(HvVgpu3d *s) {
    return s ? F_VIRGL | F_RESOURCE_BLOB | F_CONTEXT_INIT : 0;
}

uint32_t hv_vgpu3d_num_capsets(HvVgpu3d *s) {
    return s ? s->ncapsets : 0;
}

uint64_t hv_vgpu3d_hostmem_size(HvVgpu3d *s) {
    return s ? s->win_size : 0;
}

void hv_vgpu3d_kick(HvVgpu3d *s) {
    pthread_mutex_lock(&s->mu);
    s->kicked = 1;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

void hv_vgpu3d_reset(HvVgpu3d *s) {
    if (!s) return;
    pthread_mutex_lock(&s->mu);
    s->epoch++;
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mu);
}

void hv_vgpu3d_set_background(HvVgpu3d *s, int on) {
    if (!s) return;
    pthread_mutex_lock(&s->mu);
    int was = s->drain.on;
    hv_vgpu3d_drain_set(&s->drain, on, mono_ns());
    if (on && !was) s->drain_trips++;
    s->kicked = 1; /* the worker looks at its parked fences again */
    pthread_cond_signal(&s->cv);
    pthread_mutex_unlock(&s->mu);
    if ((on != 0) != was)
        fprintf(stderr, "winvm: virtio-gpu 3D background drain %s (parked fences answered after %llu ms)\n", on ? "on" : "off",
                (unsigned long long)(HV_VGPU3D_DRAIN_GRACE_NS / 1000000ull));
}

void hv_vgpu3d_bar_update(HvVgpu3d *s) {
    if (!s || !s->win) return;
    HvPciDev *d = &s->g->vio.pci;
    if (!hv_pci_mem_enabled(d)) return;
    uint64_t pa = hv_pci_bar_addr(d, HV_VGPU3D_HOSTMEM_BAR);
    if (!pa || (pa & (s->win_size - 1))) return; /* unassigned or being sized */
    if (pa == s->win_pa && s->ram_idx >= 0) return;
    if (s->ram_idx < 0) {
        s->ram_idx = hv_machine_add_ram_live(s->g->vio.m, pa, s->win_size, s->win, s->page_host);
        if (s->ram_idx < 0) {
            WARN("no RAM slot for the hostmem window\n");
            return;
        }
    } else {
        hv_machine_move_ram_live(s->g->vio.m, s->ram_idx, pa);
    }
    s->win_pa = pa;
    LOG("hostmem window at %#llx (%lluMB)\n", (unsigned long long)pa, (unsigned long long)(s->win_size >> 20));
}

int hv_vgpu3d_describe(HvVgpu3d *s, char *buf, unsigned len) {
    if (!s) s = g_state;
    if (!s) return snprintf(buf, len, "off");
    if (s->init_ok < 0) return snprintf(buf, len, "unavailable (%s)", s->why);
    pthread_mutex_lock(&s->mu);
    int drain_on = s->drain.on;
    pthread_mutex_unlock(&s->mu);
    return snprintf(buf, len,
                    "on capsets=%u ctxs=%llu cmds=%llu submits=%llu (%lluKB) blobs=%llu maps=%llu fences=%llu "
                    "(ring %llu global %llu) errors=%llu submit_errors=%llu live_ctxs=%u (neptune %u, peak %u) scanout=%u %ux%u%s "
                    "resets=%llu (skipped %llu) hostmem@%#llx drain=%s trips=%llu drained=%llu (ring %llu global %llu, this trip %llu, oldest %llums)",
                    s->ncapsets, (unsigned long long)s->ctxs, (unsigned long long)s->cmds,
                    (unsigned long long)s->submits, (unsigned long long)(s->submit_bytes >> 10),
                    (unsigned long long)s->blobs, (unsigned long long)s->maps, (unsigned long long)s->fences,
                    (unsigned long long)s->fenced_ring, (unsigned long long)s->fenced_global,
                    (unsigned long long)s->errors, (unsigned long long)s->submit_errors, s->nlive, s->nlive_npt, s->peak_live,
                    s->scanout_res, s->sc_w,
                    s->sc_h,
                    s->scanout_handle || (s->g && s->g->fb && s->g->fb->ovr_tex) ? " metal" : "",
                    (unsigned long long)s->resets, (unsigned long long)s->resets_skipped, (unsigned long long)s->win_pa,
                    drain_on ? "on" : "off", (unsigned long long)s->drain_trips,
                    (unsigned long long)(s->drained_ring + s->drained_global), (unsigned long long)s->drained_ring,
                    (unsigned long long)s->drained_global, (unsigned long long)s->drained_trip,
                    (unsigned long long)(s->drain_max_age_ns / 1000000ull));
}
