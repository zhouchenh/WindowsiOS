#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>

#include <mach/mach_time.h>
#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fb_display.h"

/* The display's frame rate (Settings > Refresh rate): frames go out at most this often. */
static _Atomic int g_target_fps = 60;

void hv_fb_metal_set_fps(int fps) {
    if (fps < 10) fps = 10;
    if (fps > 240) fps = 240;
    atomic_store(&g_target_fps, fps);
}

int hv_fb_metal_fps(void) { return atomic_load(&g_target_fps); }

/* The app is in the background (hv_fb_metal_set_paused): nothing is presented. */
static _Atomic int g_paused;

/* ---- presentation engine state (one presenter per process) ---- */

static uint64_t fb_ns_to_mach(uint64_t ns) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return ns * tb.denom / tb.numer;
}

/* Hold the last good frame while the guest takes a new size (bridge: reshape pipeline). */
static _Atomic uint32_t g_hold_w, g_hold_h;
static _Atomic uint64_t g_hold_until; /* mach_absolute_time deadline, 0: no hold */
static _Atomic uint64_t g_last_input; /* mach_absolute_time of the last touch, key or pointer event */
static _Atomic int g_legacy_fit;

static os_unfair_lock g_stats_lock = OS_UNFAIR_LOCK_INIT;
static HvFbMetalStats g_stats;

static void (*_Atomic g_hold_end_fn)(void *);
static void *_Atomic g_hold_end_opaque;

void hv_fb_metal_set_hold_end_handler(void (*fn)(void *opaque), void *opaque) {
    atomic_store(&g_hold_end_opaque, opaque);
    atomic_store(&g_hold_end_fn, fn);
}

/* The hold whose deadline is until ended (a frame of its size came, or the deadline passed): cleared, once,
   and the handler told, so what follows the hold (the layer's gravity, the idle frame rate) is recomputed. */
static void fb_hold_end(uint64_t until) {
    if (!atomic_compare_exchange_strong(&g_hold_until, &until, 0)) return; /* a newer hold, or already ended */
    void (*fn)(void *) = atomic_load(&g_hold_end_fn);
    if (fn) fn(atomic_load(&g_hold_end_opaque));
}

/* A hold past its deadline ends even when no frame comes to end it (a static desktop, a guest that did not
   follow the new mode): fb_hold_blocks only runs for a changed frame. */
static void fb_hold_expire(void) {
    uint64_t until = atomic_load(&g_hold_until);
    if (until && mach_absolute_time() >= until) fb_hold_end(until);
}

void hv_fb_metal_hold_for_size(uint32_t w, uint32_t h, uint32_t ms) {
    atomic_store(&g_hold_until, 0);
    if (!w || !h || !ms) return;
    atomic_store(&g_hold_w, w);
    atomic_store(&g_hold_h, h);
    atomic_store(&g_hold_until, mach_absolute_time() + fb_ns_to_mach((uint64_t)ms * 1000000ull));
}

void hv_fb_metal_note_input(void) { atomic_store(&g_last_input, mach_absolute_time()); }

void hv_fb_metal_set_legacy_fit(int legacy) { atomic_store(&g_legacy_fit, legacy ? 1 : 0); }

void hv_fb_metal_get_stats(HvFbMetalStats *out) {
    if (!out) return;
    fb_hold_expire();
    os_unfair_lock_lock(&g_stats_lock);
    *out = g_stats;
    os_unfair_lock_unlock(&g_stats_lock);
    out->holding = atomic_load(&g_hold_until) != 0;
}

/* 1 while a frame of w x h must not be shown yet: a hold for another size is in effect. A frame of the
   awaited size, or the deadline passing, ends the hold. */
static int fb_hold_blocks(uint32_t w, uint32_t h) {
    uint64_t until = atomic_load(&g_hold_until);
    if (!until) return 0;
    if ((w == atomic_load(&g_hold_w) && h == atomic_load(&g_hold_h)) || mach_absolute_time() >= until) {
        fb_hold_end(until);
        return 0;
    }
    os_unfair_lock_lock(&g_stats_lock);
    g_stats.held++;
    os_unfair_lock_unlock(&g_stats_lock);
    return 1;
}

/* Where a frame of sw x sh goes in a drawable of dw x dh pixels. Whole-pixel placement: when the frame
   fits an integer number of times with a margin under two guest pixels (1:1 at Sharp, exactly 2x at
   Balanced: the mode was rounded to even sizes), it is drawn at that integer scale on whole pixels with
   nearest sampling: one guest pixel is exactly m x m panel pixels. Anything else (a frame of the old size
   after a hold, a kept resolution in immersive mode, a legacy point-sized mode) is fitted with its aspect
   kept and filtered linearly. Either way the picture is where an aspect fit puts it (to within 2 px), which
   is what the touch mapping (MetalCanvasUIView.normalizedPoint) assumes. */
typedef struct FbPlacement {
    MTLViewport vp;
    uint32_t nearest;
    float scale;
} FbPlacement;

static FbPlacement fb_place(uint32_t sw, uint32_t sh, double dw, double dh) {
    FbPlacement p = {.vp = {0, 0, dw, dh, 0.0, 1.0}, .nearest = 0, .scale = 1.0f};
    if (!sw || !sh || dw < 1 || dh < 1) return p;
    int legacy = atomic_load(&g_legacy_fit);
    if (!legacy) {
        uint32_t m = (uint32_t)fmin(floor(dw / sw), floor(dh / sh));
        if (m >= 1) {
            double mw = dw - (double)sw * m, mh = dh - (double)sh * m;
            if (mw <= 2.0 * m && mh <= 2.0 * m) {
                p.vp.originX = floor(mw / 2);
                p.vp.originY = floor(mh / 2);
                p.vp.width = (double)sw * m;
                p.vp.height = (double)sh * m;
                p.nearest = 1;
                p.scale = (float)m;
                return p;
            }
        }
    }
    double s = fmin(dw / sw, dh / sh);
    double w = sw * s, h = sh * s;
    if (!legacy) {
        w = fmax(1, round(w));
        h = fmax(1, round(h));
    }
    p.vp.originX = legacy ? (dw - w) / 2 : floor((dw - w) / 2);
    p.vp.originY = legacy ? (dh - h) / 2 : floor((dh - h) / 2);
    p.vp.width = w;
    p.vp.height = h;
    p.scale = (float)s;
    return p;
}

static void fb_note_present(FbPlacement pl, uint32_t sw, uint32_t sh, CGSize dsize, uint64_t uploaded) {
    os_unfair_lock_lock(&g_stats_lock);
    g_stats.nearest = (int)pl.nearest;
    g_stats.src_w = sw; g_stats.src_h = sh;
    g_stats.dst_w = (uint32_t)dsize.width; g_stats.dst_h = (uint32_t)dsize.height;
    g_stats.scale_x100 = (uint32_t)lround(pl.scale * 100.0f);
    g_stats.upload_bytes += uploaded;
    os_unfair_lock_unlock(&g_stats_lock);
}

/* ---- Viewport pan/zoom (keyboard pan and viewport zoom, set by the app through the bridge) ----
   The picture, as fitted to the drawable, is scaled by zoom about the drawable's centre and then moved by
   (tx, ty), fractions of the drawable's width and height (y down). 1, 0, 0 shows it as fitted. Kept to
   this block, fb_compose() and the off uniform (buffer 2): fb_place() stays the placement, this sits on top. */
static os_unfair_lock g_view_lock = OS_UNFAIR_LOCK_INIT;
static float g_view_zoom = 1.0f, g_view_tx = 0.0f, g_view_ty = 0.0f;
static _Atomic uint64_t g_view_serial; /* folded into the frame hashes: a new transform redraws */

void hv_fb_metal_set_view_transform(float zoom, float tx, float ty) {
    if (!(zoom >= 1.0f)) zoom = 1.0f; /* also NaN */
    if (zoom > 8.0f) zoom = 8.0f;
    if (!(tx > -4.0f && tx < 4.0f)) tx = 0.0f;
    if (!(ty > -4.0f && ty < 4.0f)) ty = 0.0f;
    os_unfair_lock_lock(&g_view_lock);
    int same = g_view_zoom == zoom && g_view_tx == tx && g_view_ty == ty;
    g_view_zoom = zoom;
    g_view_tx = tx;
    g_view_ty = ty;
    os_unfair_lock_unlock(&g_view_lock);
    if (!same) atomic_fetch_add(&g_view_serial, 1);
}

static uint64_t fb_view_hash(void) { return atomic_load(&g_view_serial) * 0xc2b2ae3d27d4eb4full; }

/* The pan/zoom transform on top of the display placement pl, for a drawable of dw x dh pixels. Sets the
   vertex scale (NDC half sizes) and off (NDC centre) the quad and the cursor are drawn with, in pl->vp.
   With no transform: pl is left as placed (whole pixels, its own viewport), scale 1 and off 0. With one:
   the viewport becomes the whole drawable (a panned picture may leave the placed rectangle), the placed
   picture is zoomed about the drawable's centre and moved by (tx, ty) fractions of the drawable. A pure
   pan moves by whole drawable pixels, so nearest sampling stays exact; a zoom samples linearly. */
static void fb_compose(FbPlacement *pl, double dw, double dh, float scale[2], float off[2]) {
    os_unfair_lock_lock(&g_view_lock);
    float zoom = g_view_zoom, tx = g_view_tx, ty = g_view_ty;
    os_unfair_lock_unlock(&g_view_lock);
    scale[0] = scale[1] = 1.0f;
    off[0] = off[1] = 0.0f;
    if ((zoom == 1.0f && tx == 0.0f && ty == 0.0f) || dw < 1 || dh < 1) return;
    MTLViewport vp = pl->vp;
    double cx = (vp.originX + vp.width / 2) / dw * 2 - 1;
    double cy = 1 - (vp.originY + vp.height / 2) / dh * 2;
    double px = tx * dw, py = ty * dh;
    if (zoom == 1.0f) {
        px = round(px);
        py = round(py);
    } else {
        pl->nearest = 0;
    }
    scale[0] = (float)(vp.width / dw * zoom);
    scale[1] = (float)(vp.height / dh * zoom);
    off[0] = (float)(cx * zoom + 2 * px / dw);
    off[1] = (float)(cy * zoom - 2 * py / dh);
    pl->vp = (MTLViewport){0, 0, dw, dh, 0.0, 1.0};
}

/* The guest draws sRGB values (Windows' and Linux's desktops are sRGB). Tagging the layer sRGB has Core
   Animation colour-match them to the screen. An untagged layer goes to a wide-gamut (Display P3) panel
   unmanaged, its colours stretched to the panel's gamut: oversaturated. HV_NO_COLOR_MATCH=1 (an
   environment variable, or a Documents/env.txt line on iOS) leaves the layer untagged, as before.
   After Henge (Leviidev/Henge, GPL-2.0-or-later) commit 7f3398c (SonNX), which tags its display layer. */
static CGColorSpaceRef fb_layer_colorspace(void) {
    static CGColorSpaceRef cs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *off = getenv("HV_NO_COLOR_MATCH");
        if (!(off && *off && *off != '0')) cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    return cs;
}

static NSString *const kFbShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut {\n"
     "    float4 pos [[position]];\n"
     "    float2 uv;\n"
     "};\n"
     "vertex VOut fb_vs(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]], constant float4 &uvr [[buffer(1)]],\n"
     "                  constant float2 &off [[buffer(2)]]) {\n"
     "    const float2 quad[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "    const float2 uvs[4]  = { float2(0,1),   float2(1,1),  float2(0,0),  float2(1,0) };\n"
     "    VOut o;\n"
     "    o.pos = float4(quad[vid] * scale + off, 0.0, 1.0);\n"
     "    o.uv  = uvr.xy + uvs[vid] * uvr.zw;\n"
     "    return o;\n"
     "}\n"
     "fragment float4 fb_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant uint &nearest [[buffer(0)]]) {\n"
     "    constexpr sampler sl(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
     "    constexpr sampler sn(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);\n"
     "    float4 c = nearest ? tex.sample(sn, in.uv) : tex.sample(sl, in.uv);\n"
     "    return float4(c.rgb, 1.0);\n"
     "}\n"
     "vertex VOut cur_vs(uint vid [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
     "    VOut o;\n"
     "    o.pos = float4((vid & 1) ? r.z : r.x, (vid & 2) ? r.y : r.w, 0.0, 1.0);\n"
     "    o.uv  = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 0.0 : 1.0);\n"
     "    return o;\n"
     "}\n"
     "fragment float4 cur_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
     "    constexpr sampler s(mag_filter::nearest, min_filter::linear, address::clamp_to_zero);\n"
     "    return tex.sample(s, in.uv);\n"
     "}\n";

@interface HvFbMetalPresenter : NSObject {
@public
    HvFbDisplay *fb;
    os_unfair_lock lock;
    CAMetalLayer *layer;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLRenderPipelineState> curPipeline; /* the hardware cursor, blended over the frame */
    id<MTLTexture> curTex;
    uint64_t curImgSerial;
    uint32_t curPx[64 * 64];
    id<MTLTexture> texture;
    uint32_t texW, texH;
    dispatch_source_t timer;
#if TARGET_OS_IPHONE
    CADisplayLink *link; /* iOS: frames go out on the screen's own refresh (vsync), on linkThread */
    NSThread *linkThread;
#endif
    _Atomic(uint64_t) framesPresented;
    uint64_t lastHash;
    CGSize lastDrawableSize;
    uint64_t lastPresentMach; /* when a frame last went out (idle throttling) */
    int linkPreferred;        /* the rate last given to the display link */
}
- (instancetype)initWithDisplay:(HvFbDisplay *)display;
- (void)setTargetLayer:(CAMetalLayer *)newLayer;
- (void)tick;
- (BOOL)presentTexture:(BOOL *)presented;
#if TARGET_OS_IPHONE
+ (void)applyRate:(CADisplayLink *)l;
#endif
@end

@implementation HvFbMetalPresenter

- (instancetype)initWithDisplay:(HvFbDisplay *)display {
    if ((self = [super init])) {
        fb = display;
        lock = OS_UNFAIR_LOCK_INIT;
        device = MTLCreateSystemDefaultDevice();
        if (device) {
            queue = [device newCommandQueue];
            NSError *err = nil;
            id<MTLLibrary> lib = [device newLibraryWithSource:kFbShaderSource options:nil error:&err];
            if (lib) {
                MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
                pd.vertexFunction = [lib newFunctionWithName:@"fb_vs"];
                pd.fragmentFunction = [lib newFunctionWithName:@"fb_fs"];
                pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
                MTLRenderPipelineDescriptor *cd = [[MTLRenderPipelineDescriptor alloc] init];
                cd.vertexFunction = [lib newFunctionWithName:@"cur_vs"];
                cd.fragmentFunction = [lib newFunctionWithName:@"cur_fs"];
                cd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                cd.colorAttachments[0].blendingEnabled = YES; /* premultiplied alpha (KMS cursor planes) */
                cd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
                cd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                cd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
                cd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                curPipeline = [device newRenderPipelineStateWithDescriptor:cd error:&err];
            }
        }
    }
    return self;
}

- (void)setTargetLayer:(CAMetalLayer *)newLayer {
    os_unfair_lock_lock(&lock);
    layer = newLayer;
    lastHash = 0;
    lastDrawableSize = CGSizeZero;
    if (layer && device) {
        dispatch_block_t cfg = ^{
            newLayer.device = self->device;
            newLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            newLayer.framebufferOnly = YES;
            newLayer.colorspace = fb_layer_colorspace();
        };
        if ([NSThread isMainThread]) cfg();
        else dispatch_async(dispatch_get_main_queue(), cfg);

#if TARGET_OS_IPHONE
        /* A free-running 60 Hz timer drifts against the screen: frames then reach it at uneven
           intervals. The display link calls once per refresh instead, capped at 60 per second. */
        if (!linkThread) {
            linkThread = [[NSThread alloc] initWithTarget:self selector:@selector(linkMain) object:nil];
            linkThread.name = @"fbmetal-vsync";
            linkThread.qualityOfService = NSQualityOfServiceUserInteractive;
            [linkThread start];
        }
        if (link) link.paused = atomic_load(&g_paused) != 0;
#else
        if (!timer) {
            dispatch_queue_t q = dispatch_queue_create("me.ammaar.windowsios.fbmetal", DISPATCH_QUEUE_SERIAL);
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, 2 * NSEC_PER_MSEC);
            __weak HvFbMetalPresenter *weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                [weakSelf tick];
            });
            dispatch_resume(timer);
        }
#endif
    } else if (!layer && timer) {
        dispatch_source_cancel(timer);
        timer = nil;
    }
#if TARGET_OS_IPHONE
    if (!layer && link) link.paused = YES;
#endif
    os_unfair_lock_unlock(&lock);
}

#if TARGET_OS_IPHONE
- (void)linkMain {
    @autoreleasepool {
        CADisplayLink *l = [CADisplayLink displayLinkWithTarget:self selector:@selector(onLink:)];
        [HvFbMetalPresenter applyRate:l];
        [l addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        os_unfair_lock_lock(&lock);
        link = l;
        l.paused = (layer == nil) || atomic_load(&g_paused);
        os_unfair_lock_unlock(&lock);
        for (;;) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
            }
        }
    }
}

+ (void)applyRate:(CADisplayLink *)l {
    int fps = atomic_load(&g_target_fps);
    if (@available(iOS 15.0, *)) l.preferredFrameRateRange = CAFrameRateRangeMake(fps, fps, fps);
    else l.preferredFramesPerSecond = fps;
}

/* Idle throttling: after 1.5 s with no new guest frame and no input the link slows to about 20 Hz (it
   still looks for new frames, so a spinner keeps turning); a new frame or any input brings the full rate
   back at once. HV_DISPLAY_NO_IDLE=1 keeps the full rate. */
static int fb_idle_allowed(void) {
    static int allowed = -1;
    if (allowed < 0) {
        const char *v = getenv("HV_DISPLAY_NO_IDLE");
        allowed = !(v && *v && *v != '0');
    }
    return allowed;
}

- (void)onLink:(CADisplayLink *)l {
    if (atomic_load(&g_paused)) return; /* in the background: the link is being paused */
    /* a changed setting: the link follows it here, on its own thread */
    int fps = atomic_load(&g_target_fps);
    fb_hold_expire();
    uint64_t now = mach_absolute_time();
    uint64_t quiet = fb_ns_to_mach(1500ull * 1000000ull);
    int idle = fb_idle_allowed() && atomic_load(&g_hold_until) == 0 && now - lastPresentMach > quiet &&
               now - atomic_load(&g_last_input) > quiet;
    int pref = idle ? (fps < 20 ? fps : 20) : fps;
    if (pref != linkPreferred) {
        linkPreferred = pref;
        if (@available(iOS 15.0, *)) {
            float lo = idle ? (fps < 10 ? fps : 10) : (fps < 60 ? fps : 60);
            float hi = idle ? (fps < 30 ? fps : 30) : fps;
            l.preferredFrameRateRange = CAFrameRateRangeMake(lo, hi, pref);
        } else {
            l.preferredFramesPerSecond = pref;
        }
        os_unfair_lock_lock(&g_stats_lock);
        g_stats.link_hz = pref;
        g_stats.idle = idle;
        os_unfair_lock_unlock(&g_stats_lock);
    }
    [self tick];
}
#endif

/* What the cursor looks like now, folded into the frame hashes: moving it alone redraws. */
static uint64_t cursor_hash(HvFbDisplay *fb) {
    uint64_t serial = 0;
    int vis = hv_fb_display_cursor_get(fb, NULL, NULL, NULL, NULL, NULL, NULL, &serial);
    return (serial * 0x9e3779b97f4a7c15ull) ^ (uint64_t)vis;
}

/* The hardware cursor over a frame of fw x fh pixels drawn at scale (NDC half sizes). Under lock. */
static void draw_cursor(HvFbMetalPresenter *p, id<MTLRenderCommandEncoder> enc, const float scale[2], const float off[2],
                        uint32_t fw, uint32_t fh) {
    uint32_t cw = 0, ch = 0;
    int32_t cx = 0, cy = 0;
    uint64_t img = p->curImgSerial;
    if (!p->curPipeline || !fw || !fh ||
        !hv_fb_display_cursor_get(p->fb, p->curPx, &p->curImgSerial, &cw, &ch, &cx, &cy, NULL) || !cw || !ch)
        return;
    if (!p->curTex || img != p->curImgSerial) {
        if (!p->curTex) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:64
                                                                                         height:64
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            p->curTex = [p->device newTextureWithDescriptor:td];
        }
        static uint32_t full[64 * 64];
        memset(full, 0, sizeof full);
        for (uint32_t r = 0; r < ch; r++) memcpy(full + r * 64, p->curPx + r * cw, cw * 4);
        [p->curTex replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:full bytesPerRow:64 * 4];
    }
    float rect[4] = {off[0] - scale[0] + 2 * scale[0] * (float)cx / fw, off[1] + scale[1] - 2 * scale[1] * (float)cy / fh,
                     off[0] - scale[0] + 2 * scale[0] * (float)(cx + 64) / fw,
                     off[1] + scale[1] - 2 * scale[1] * (float)(cy + 64) / fh};
    [enc setRenderPipelineState:p->curPipeline];
    [enc setVertexBytes:rect length:sizeof(rect) atIndex:0];
    [enc setFragmentTexture:p->curTex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static uint64_t quick_frame_hash(const uint8_t *px, uint32_t w, uint32_t h, uint32_t stride) {
    uint64_t hash = ((uint64_t)w << 32) ^ h ^ stride;
    uint32_t step_y = h > 128 ? h / 128 : 1;
    for (uint32_t y = 0; y < h; y += step_y) {
        const uint64_t *row = (const uint64_t *)(px + (size_t)y * stride);
        uint32_t qwords = (w * 4) / 8;
        uint32_t step_x = qwords > 64 ? qwords / 64 : 1;
        for (uint32_t x = 0; x < qwords; x += step_x) {
            hash = (hash ^ row[x]) * 0x9e3779b97f4a7c15ull;
        }
    }
    return hash ? hash : 1;
}

- (BOOL)presentTexture:(BOOL *)presented {
    void *tref = NULL;
    uint32_t tw = 0, th = 0, rx = 0, ry = 0, rw = 0, rh = 0;
    if (hv_fb_display_get_texture(fb, &tref, &tw, &th, &rx, &ry, &rw, &rh) != 0) return NO;
    id<MTLTexture> src = (__bridge_transfer id<MTLTexture>)tref;
    os_unfair_lock_lock(&lock);
    CAMetalLayer *curLayer = layer;
    if (!curLayer || !device || !pipeline || !queue) {
        os_unfair_lock_unlock(&lock);
        return YES;
    }
    CGSize dsize = curLayer.drawableSize;
    uint64_t serial = __atomic_load_n(&fb->ovr_serial, __ATOMIC_RELAXED);
    uint64_t hval = (serial * 0xff51afd7ed558ccdull) ^ (uint64_t)(uintptr_t)tref ^ 0x5bd1e995 ^ cursor_hash(fb) ^ fb_view_hash();
    if (dsize.width < 4 || dsize.height < 4 ||
        (hval == lastHash && CGSizeEqualToSize(dsize, lastDrawableSize)) || fb_hold_blocks(rw, rh)) {
        os_unfair_lock_unlock(&lock);
        return YES;
    }
    id<CAMetalDrawable> drawable = [curLayer nextDrawable];
    if (!drawable) {
        os_unfair_lock_unlock(&lock);
        return YES;
    }
    FbPlacement pl = fb_place(rw, rh, dsize.width, dsize.height);
    float scale[2], off[2];
    fb_compose(&pl, dsize.width, dsize.height, scale, off); /* pan/zoom on top of the placement */
    float uvr[4] = {(float)rx / tw, (float)ry / th, (float)rw / tw, (float)rh / th};
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setViewport:pl.vp];
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:scale length:sizeof(scale) atIndex:0];
    [enc setVertexBytes:uvr length:sizeof(uvr) atIndex:1];
    [enc setVertexBytes:off length:sizeof(off) atIndex:2];
    [enc setFragmentBytes:&pl.nearest length:sizeof(pl.nearest) atIndex:0];
    [enc setFragmentTexture:src atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    draw_cursor(self, enc, scale, off, rw, rh);
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
    lastHash = hval;
    lastDrawableSize = dsize;
    atomic_fetch_add_explicit(&framesPresented, 1, memory_order_relaxed);
    os_unfair_lock_unlock(&lock);
    fb_note_present(pl, rw, rh, dsize, 0);
    *presented = YES;
    return YES;
}

- (void)tick {
    if (atomic_load(&g_paused)) return;
    uint64_t cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    BOOL presented = NO;
    @autoreleasepool {
        [self tickPresenting:&presented];
    }
    uint64_t cpu1 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    if (presented) lastPresentMach = mach_absolute_time();
    os_unfair_lock_lock(&g_stats_lock);
    g_stats.ticks++;
    if (presented) g_stats.frames++;
    if (cpu1 > cpu0) g_stats.cpu_ns += cpu1 - cpu0;
    os_unfair_lock_unlock(&g_stats_lock);
}

- (void)tickPresenting:(BOOL *)presented {
    {
        if ([self presentTexture:presented]) return;
        const uint8_t *px = NULL;
        uint32_t w = 0, h = 0, stride = 0;
        if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) return;

        os_unfair_lock_lock(&lock);
        CAMetalLayer *curLayer = layer;
        if (!curLayer || !device || !pipeline || !queue) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        CGSize dsize = curLayer.drawableSize;
        if (dsize.width < 4 || dsize.height < 4) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        uint64_t hval = quick_frame_hash(px, w, h, stride) ^
                        (__atomic_load_n(&fb->ovr_serial, __ATOMIC_RELAXED) * 0xff51afd7ed558ccdull) ^ cursor_hash(fb) ^
                        fb_view_hash();
        BOOL sizeChanged = !CGSizeEqualToSize(dsize, lastDrawableSize);
        if ((hval == lastHash && !sizeChanged && texW == w && texH == h) || fb_hold_blocks(w, h)) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        if (!texture || texW != w || texH != h) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            texture = [device newTextureWithDescriptor:td];
            texW = w;
            texH = h;
        }

        [texture replaceRegion:MTLRegionMake2D(0, 0, w, h)
                   mipmapLevel:0
                     withBytes:px
                   bytesPerRow:stride];

        id<CAMetalDrawable> drawable = [curLayer nextDrawable];
        if (!drawable) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        FbPlacement pl = fb_place(w, h, dsize.width, dsize.height);
        float scale[2], off[2];
        fb_compose(&pl, dsize.width, dsize.height, scale, off); /* pan/zoom on top of the placement */

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setViewport:pl.vp];
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBytes:scale length:sizeof(scale) atIndex:0];
        static const float uvr_full[4] = {0, 0, 1, 1};
        [enc setVertexBytes:uvr_full length:sizeof(uvr_full) atIndex:1];
        [enc setVertexBytes:off length:sizeof(off) atIndex:2];
        [enc setFragmentBytes:&pl.nearest length:sizeof(pl.nearest) atIndex:0];
        [enc setFragmentTexture:texture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        draw_cursor(self, enc, scale, off, w, h);
        [enc endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];

        lastHash = hval;
        lastDrawableSize = dsize;
        atomic_fetch_add_explicit(&framesPresented, 1, memory_order_relaxed);
        os_unfair_lock_unlock(&lock);
        fb_note_present(pl, w, h, dsize, (uint64_t)stride * h);
        *presented = YES;
    }
}

@end

static HvFbMetalPresenter *ensure_presenter(HvFbDisplay *fb) {
    if (!fb) return nil;
    pthread_mutex_lock(&fb->mu);
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    if (!p) {
        p = [[HvFbMetalPresenter alloc] initWithDisplay:fb];
        fb->metal = (__bridge_retained void *)p;
    }
    pthread_mutex_unlock(&fb->mu);
    return p;
}

void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer) {
    HvFbMetalPresenter *p = ensure_presenter(fb);
    if (!p) return;
    [p setTargetLayer:(__bridge CAMetalLayer *)ca_metal_layer];
}

uint64_t hv_fb_metal_frames(HvFbDisplay *fb) {
    if (!fb || !fb->metal) return 0;
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    return atomic_load_explicit(&p->framesPresented, memory_order_relaxed);
}

typedef struct FbCaptureInfo {
    const char *source, *error;
    uint64_t serial_before, serial_after;
    uint32_t width, height;
    long gpu_status;
} FbCaptureInfo;

/* The mini-map also captures every few seconds. Keep repeated identical
 * results quiet; a changed source, notification serial, or error is logged. */
static void log_capture(const FbCaptureInfo *info) {
    static os_unfair_lock capture_lock = OS_UNFAIR_LOCK_INIT;
    static FbCaptureInfo previous;
    static uint64_t suppressed;
    os_unfair_lock_lock(&capture_lock);
    if (previous.source && !strcmp(previous.source, info->source) && !strcmp(previous.error, info->error) &&
        previous.serial_before == info->serial_before && previous.serial_after == info->serial_after &&
        previous.width == info->width && previous.height == info->height && previous.gpu_status == info->gpu_status) {
        suppressed++;
        os_unfair_lock_unlock(&capture_lock);
        return;
    }
    uint64_t skipped = suppressed;
    suppressed = 0;
    previous = *info;
    os_unfair_lock_unlock(&capture_lock);
    fprintf(stderr, "winvm: capture source=%s serial=%llu->%llu size=%ux%u gpu_status=%ld error=%s suppressed=%llu\n",
            info->source, (unsigned long long)info->serial_before, (unsigned long long)info->serial_after,
            info->width, info->height, info->gpu_status, info->error, (unsigned long long)skipped);
}

/* Read the single retained texture selected by the capture, including its crop.
 * Do not look up a second scanout: a mode change could select a different source. */
static uint8_t *copy_texture_pixels(HvFbDisplay *fb, id<MTLTexture> src, uint32_t rx, uint32_t ry,
                                    uint32_t rw, uint32_t rh, FbCaptureInfo *info) {
    if (atomic_load(&g_paused)) { info->error = "gpu-paused"; return NULL; }
    MTLPixelFormat f = src.pixelFormat;
    if (f != MTLPixelFormatBGRA8Unorm && f != MTLPixelFormatBGRA8Unorm_sRGB &&
        f != MTLPixelFormatRGBA8Unorm && f != MTLPixelFormatRGBA8Unorm_sRGB) {
        info->error = "unsupported-texture-format";
        return NULL;
    }
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    id<MTLDevice> dev = src.device;
    id<MTLCommandQueue> q = (p && p->queue && p->device == dev) ? p->queue : [dev newCommandQueue];
    if (!q || !rw || !rh) { info->error = "no-readback-queue-or-size"; return NULL; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f
                                                                                  width:rw
                                                                                 height:rh
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> dst = [dev newTextureWithDescriptor:td];
    if (!dst) { info->error = "readback-texture-allocation"; return NULL; }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    if (!cb) { info->error = "no-command-buffer"; return NULL; }
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (!blit) { info->error = "no-blit-encoder"; return NULL; }
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(rx, ry, 0)
               sourceSize:MTLSizeMake(rw, rh, 1) toTexture:dst destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    info->gpu_status = (long)cb.status;
    if (cb.status != MTLCommandBufferStatusCompleted) { info->error = "gpu-readback-failed"; return NULL; }
    uint8_t *px = malloc((size_t)rw * rh * 4);
    if (!px) { info->error = "pixel-allocation"; return NULL; }
    [dst getBytes:px bytesPerRow:rw * 4 fromRegion:MTLRegionMake2D(0, 0, rw, rh) mipmapLevel:0];
    if (f == MTLPixelFormatRGBA8Unorm || f == MTLPixelFormatRGBA8Unorm_sRGB) /* to BGRA for the encoder below */
        for (size_t i = 0; i < (size_t)rw * rh; i++) {
            uint8_t t = px[i * 4];
            px[i * 4] = px[i * 4 + 2];
            px[i * 4 + 2] = t;
        }
    return px;
}

/* The hardware cursor blended over px (w x h, rows of stride bytes), as the screen shows it. */
static void blend_cursor(HvFbDisplay *fb, uint8_t *px, uint32_t w, uint32_t h, uint32_t stride) {
    uint32_t *cpx = malloc(64 * 64 * 4);
    if (!cpx) return;
    uint64_t none = ~0ull;
    uint32_t cw = 0, ch = 0;
    int32_t cx = 0, cy = 0;
    if (hv_fb_display_cursor_get(fb, cpx, &none, &cw, &ch, &cx, &cy, NULL))
        for (uint32_t r = 0; r < ch; r++)
            for (uint32_t c = 0; c < cw; c++) {
                int64_t X = (int64_t)cx + c, Y = (int64_t)cy + r;
                if (X < 0 || Y < 0 || X >= w || Y >= h) continue;
                const uint8_t *sp = (const uint8_t *)&cpx[r * cw + c];
                uint8_t *dp = px + (size_t)Y * stride + (size_t)X * 4;
                for (int k = 0; k < 3; k++) dp[k] = (uint8_t)(sp[k] + dp[k] * (255 - sp[3]) / 255);
            }
    free(cpx);
}

static uint8_t *capture_pixels(HvFbDisplay *fb, int allow_gpu, uint32_t *ow, uint32_t *oh, FbCaptureInfo *info) {
    *info = (FbCaptureInfo){.source = "none", .error = "none", .gpu_status = -1};
    if (!fb) { info->error = "no-display"; return NULL; }
    info->serial_before = __atomic_load_n(&fb->ovr_serial, __ATOMIC_RELAXED);
    uint32_t w = 0, h = 0;
    uint8_t *copy = NULL;
    void *tref = NULL;
    uint32_t tw, th, rx, ry, rw, rh;
    int texture = hv_fb_display_get_texture(fb, &tref, &tw, &th, &rx, &ry, &rw, &rh) == 0;
    if (texture) {
        info->source = "texture";
        info->width = w = rw;
        info->height = h = rh;
        @autoreleasepool {
            id<MTLTexture> src = (__bridge_transfer id<MTLTexture>)tref;
            if (allow_gpu) copy = copy_texture_pixels(fb, src, rx, ry, rw, rh, info);
            else info->error = "gpu-readback-disallowed";
        }
        if (!copy && allow_gpu < 2) return NULL;
    }
    if (!copy) {
        info->source = texture ? "cpu-fallback" : "cpu";
        const uint8_t *px = NULL;
        uint32_t stride = 0;
        if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0 || !w || !h) {
            info->error = "no-cpu-frame";
            return NULL;
        }
        info->width = w;
        info->height = h;
        copy = malloc((size_t)w * h * 4);
        if (!copy) { info->error = "pixel-allocation"; return NULL; }
        for (uint32_t y = 0; y < h; y++) memcpy(copy + (size_t)y * w * 4, px + (size_t)y * stride, (size_t)w * 4);
    }
    blend_cursor(fb, copy, w, h, w * 4);
    /* opaque (XRGB8888 leaves X = 0x00) */
    for (size_t i = 0; i < (size_t)w * h; i++) copy[i * 4 + 3] = 0xff;
    *ow = w;
    *oh = h;
    return copy;
}

uint8_t *hv_fb_metal_snapshot(HvFbDisplay *fb, int allow_gpu, uint32_t *ow, uint32_t *oh) {
    FbCaptureInfo info;
    return capture_pixels(fb, allow_gpu, ow, oh, &info);
}

uint64_t hv_fb_metal_screen_serial(HvFbDisplay *fb, int *is_texture) {
    if (is_texture) *is_texture = 0;
    if (!fb) return 0;
    uint64_t serial = __atomic_load_n(&fb->ovr_serial, __ATOMIC_RELAXED) * 0xff51afd7ed558ccdull;
    void *tref = NULL;
    uint32_t tw, th, rx, ry, rw, rh;
    if (hv_fb_display_get_texture(fb, &tref, &tw, &th, &rx, &ry, &rw, &rh) == 0) {
        uint64_t v = serial ^ (uint64_t)(uintptr_t)tref ^ 0x5bd1e995 ^ cursor_hash(fb) ^ ((uint64_t)rw << 32 | rh);
        CFRelease(tref);
        if (is_texture) *is_texture = 1;
        return v ? v : 1;
    }
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0 || !w || !h) return 0;
    uint64_t v = quick_frame_hash(px, w, h, stride) ^ serial ^ cursor_hash(fb);
    return v ? v : 1;
}

void hv_fb_metal_set_paused(HvFbDisplay *fb, int paused) {
    paused = paused != 0;
    if (atomic_exchange(&g_paused, paused) == paused) return;
    HvFbMetalPresenter *p = fb ? (__bridge HvFbMetalPresenter *)fb->metal : nil;
    if (p) {
        os_unfair_lock_lock(&p->lock);
#if TARGET_OS_IPHONE
        if (p->link) p->link.paused = paused || !p->layer;
#endif
        if (!paused) {
            p->lastHash = 0; /* draw the current frame at once */
            p->lastDrawableSize = CGSizeZero;
        }
        os_unfair_lock_unlock(&p->lock);
    }
    fprintf(stderr, "winvm: presenter %s\n", paused ? "paused (app in the background)" : "running again");
}

int hv_fb_save_png(HvFbDisplay *fb, const char *path) {
    if (!fb || !path) return -1;
    uint32_t w = 0, h = 0;
    FbCaptureInfo info;
    /* A raw-screen diagnostic must not silently substitute stale ramfb pixels
     * when the active 3D texture cannot be read. CPU-only displays still work. */
    uint8_t *copy = capture_pixels(fb, 1, &w, &h, &info);
    info.serial_after = __atomic_load_n(&fb->ovr_serial, __ATOMIC_RELAXED);
    if (!copy) {
        log_capture(&info);
        return -1;
    }
    @autoreleasepool {
        uint32_t stride = w * 4;
        size_t total = (size_t)stride * h;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, copy, total, NULL);
        CGBitmapInfo bmi = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
        CGImageRef img = CGImageCreate(w, h, 8, 32, stride, cs, bmi, prov, NULL, false, kCGRenderingIntentDefault);
        int rc = -1;
        if (img) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (dst) {
                CGImageDestinationAddImage(dst, img, NULL);
                if (CGImageDestinationFinalize(dst)) rc = 0;
                CFRelease(dst);
            }
            CGImageRelease(img);
        }
        CGDataProviderRelease(prov);
        CGColorSpaceRelease(cs);
        free(copy);
        info.error = rc ? "png-encode-or-write" : "none";
        log_capture(&info);
        return rc;
    }
}
