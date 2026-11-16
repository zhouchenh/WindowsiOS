#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>

#include <os/lock.h>
#include <stdatomic.h>
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

/* ---- Viewport pan/zoom (keyboard pan and viewport zoom, set by the app through the bridge) ----
   The picture, as fitted to the drawable, is scaled by zoom about the drawable's centre and then moved by
   (tx, ty), fractions of the drawable's width and height (y down). 1, 0, 0 shows it as fitted. Kept to
   this block, fb_view_transform() and the off uniform (buffer 2) so the fitting code stays independent. */
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

/* The fitted picture's NDC half sizes (scale) -> zoomed, and the NDC offset to draw it at (off). */
static void fb_view_transform(float scale[2], float off[2]) {
    os_unfair_lock_lock(&g_view_lock);
    scale[0] *= g_view_zoom;
    scale[1] *= g_view_zoom;
    off[0] = 2.0f * g_view_tx;
    off[1] = -2.0f * g_view_ty;
    os_unfair_lock_unlock(&g_view_lock);
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
     "fragment float4 fb_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
     "    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
     "    float4 c = tex.sample(s, in.uv);\n"
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
}
- (instancetype)initWithDisplay:(HvFbDisplay *)display;
- (void)setTargetLayer:(CAMetalLayer *)newLayer;
- (void)tick;
- (BOOL)presentTexture;
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
        if (link) link.paused = NO;
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
        l.paused = (layer == nil);
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

- (void)onLink:(CADisplayLink *)l {
    /* a changed setting: the link follows it here, on its own thread */
    int fps = atomic_load(&g_target_fps);
    BOOL differs;
    if (@available(iOS 15.0, *)) differs = (int)l.preferredFrameRateRange.preferred != fps;
    else differs = l.preferredFramesPerSecond != fps;
    if (differs) [HvFbMetalPresenter applyRate:l];
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

- (BOOL)presentTexture {
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
        (hval == lastHash && CGSizeEqualToSize(dsize, lastDrawableSize))) {
        os_unfair_lock_unlock(&lock);
        return YES;
    }
    id<CAMetalDrawable> drawable = [curLayer nextDrawable];
    if (!drawable) {
        os_unfair_lock_unlock(&lock);
        return YES;
    }
    float dstAspect = (float)(dsize.width / dsize.height);
    float srcAspect = (float)rw / (float)rh;
    float scale[2] = {1.0f, 1.0f};
    if (dstAspect > srcAspect) scale[0] = srcAspect / dstAspect;
    else scale[1] = dstAspect / srcAspect;
    float uvr[4] = {(float)rx / tw, (float)ry / th, (float)rw / tw, (float)rh / th};
    float off[2] = {0, 0};
    fb_view_transform(scale, off); /* pan/zoom */
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:scale length:sizeof(scale) atIndex:0];
    [enc setVertexBytes:uvr length:sizeof(uvr) atIndex:1];
    [enc setVertexBytes:off length:sizeof(off) atIndex:2];
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
    return YES;
}

- (void)tick {
    @autoreleasepool {
        if ([self presentTexture]) return;
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
        if (hval == lastHash && !sizeChanged && texW == w && texH == h) {
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

        float dstAspect = (float)(dsize.width / dsize.height);
        float srcAspect = (float)w / (float)h;
        float scale[2] = {1.0f, 1.0f};
        if (dstAspect > srcAspect) {
            scale[0] = srcAspect / dstAspect;
        } else {
            scale[1] = dstAspect / srcAspect;
        }
        float off[2] = {0, 0};
        fb_view_transform(scale, off); /* pan/zoom */

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBytes:scale length:sizeof(scale) atIndex:0];
        static const float uvr_full[4] = {0, 0, 1, 1};
        [enc setVertexBytes:uvr_full length:sizeof(uvr_full) atIndex:1];
        [enc setVertexBytes:off length:sizeof(off) atIndex:2];
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

/* The 3D scanout is a GPU texture (possibly private storage): copy it into a shared one and read that. */
static uint8_t *copy_texture_pixels(HvFbDisplay *fb, uint32_t *ow, uint32_t *oh) {
    void *tref = NULL;
    uint32_t tw = 0, th = 0, rx = 0, ry = 0, rw = 0, rh = 0;
    if (hv_fb_display_get_texture(fb, &tref, &tw, &th, &rx, &ry, &rw, &rh) != 0) return NULL;
    id<MTLTexture> src = (__bridge_transfer id<MTLTexture>)tref;
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    id<MTLDevice> dev = src.device;
    id<MTLCommandQueue> q = (p && p->queue && p->device == dev) ? p->queue : [dev newCommandQueue];
    if (!q || !rw || !rh) return NULL;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                  width:rw
                                                                                 height:rh
                                                                              mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> dst = [dev newTextureWithDescriptor:td];
    if (!dst) return NULL;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(rx, ry, 0)
               sourceSize:MTLSizeMake(rw, rh, 1) toTexture:dst destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return NULL;
    uint8_t *px = malloc((size_t)rw * rh * 4);
    if (!px) return NULL;
    [dst getBytes:px bytesPerRow:rw * 4 fromRegion:MTLRegionMake2D(0, 0, rw, rh) mipmapLevel:0];
    MTLPixelFormat f = src.pixelFormat;
    if (f == MTLPixelFormatRGBA8Unorm || f == MTLPixelFormatRGBA8Unorm_sRGB) /* to BGRA for the encoder below */
        for (size_t i = 0; i < (size_t)rw * rh; i++) {
            uint8_t t = px[i * 4];
            px[i * 4] = px[i * 4 + 2];
            px[i * 4 + 2] = t;
        }
    *ow = rw;
    *oh = rh;
    return px;
}

int hv_fb_save_png(HvFbDisplay *fb, const char *path) {
    if (!fb || !path) return -1;
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    uint8_t *texpx = NULL;
    @autoreleasepool {
        texpx = copy_texture_pixels(fb, &w, &h);
    }
    if (texpx) stride = w * 4;
    else if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) return -1;

    @autoreleasepool {
        size_t total = (size_t)stride * h;
        uint8_t *copy = texpx ? texpx : malloc(total);
        if (!copy) return -1;
        if (!texpx) memcpy(copy, px, total);
        { /* the hardware cursor, as the screen shows it */
            static uint32_t cpx[64 * 64];
            uint64_t none = ~0ull;
            uint32_t cw = 0, ch = 0;
            int32_t cx = 0, cy = 0;
            if (hv_fb_display_cursor_get(fb, cpx, &none, &cw, &ch, &cx, &cy, NULL))
                for (uint32_t r = 0; r < ch; r++)
                    for (uint32_t c = 0; c < cw; c++) {
                        int64_t X = (int64_t)cx + c, Y = (int64_t)cy + r;
                        if (X < 0 || Y < 0 || X >= w || Y >= h) continue;
                        const uint8_t *sp = (const uint8_t *)&cpx[r * cw + c];
                        uint8_t *dp = copy + (size_t)Y * stride + (size_t)X * 4;
                        for (int k = 0; k < 3; k++) dp[k] = (uint8_t)(sp[k] + dp[k] * (255 - sp[3]) / 255);
                    }
        }
        /* Ensure alpha byte is 0xff (XRGB8888 leaves X=0x00) */
        for (uint32_t y = 0; y < h; y++) {
            uint8_t *row = copy + (size_t)y * stride;
            for (uint32_t x = 0; x < w; x++) row[x * 4 + 3] = 0xff;
        }

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
        return rc;
    }
}
