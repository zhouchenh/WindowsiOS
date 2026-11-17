/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Exercise the real snapshot/PNG/presenter code with a deterministic fake Metal
 * backend, plus one tiny real-Metal readback when available. No CAMetalLayer,
 * guest, or phone is required. The late-producer
 * case demonstrates the presenter's cache assumption; it does not assert that
 * the Windows driver violates its present-completion contract.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../devices/fb_metal.m"

void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) { (void)m; (void)pa; (void)len; return NULL; }
int hv_fw_cfg_add_writable_file(HvFwCfg *f, const char *n, uint32_t s, HvFwCfgWriteCb cb, void *p) {
    (void)f; (void)n; (void)s; (void)cb; (void)p; return 0;
}

@class FakeDevice, FakeQueue, FakeBuffer;
@interface FakeTexture : NSObject {
@public
    FakeDevice *owner;
    MTLPixelFormat format;
    uint32_t width, height, pixels[64];
}
- (id<MTLDevice>)device;
- (MTLPixelFormat)pixelFormat;
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)stride fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level;
@end
@implementation FakeTexture
- (id<MTLDevice>)device { return (id<MTLDevice>)owner; }
- (MTLPixelFormat)pixelFormat { return format; }
- (void)getBytes:(void *)bytes bytesPerRow:(NSUInteger)stride fromRegion:(MTLRegion)r mipmapLevel:(NSUInteger)level {
    assert(!level && r.origin.x + r.size.width <= width && r.origin.y + r.size.height <= height);
    for (NSUInteger y = 0; y < r.size.height; y++)
        memcpy((char *)bytes + y * stride, pixels + (r.origin.y + y) * width + r.origin.x, r.size.width * 4);
}
@end

@interface FakeDevice : NSObject {
@public
    int failAllocation, failQueue, failBuffer, failEncoder, failGPU;
    unsigned queueCalls, draws;
}
- (id<MTLCommandQueue>)newCommandQueue;
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc;
@end
@interface FakeQueue : NSObject { @public FakeDevice *owner; }
- (id<MTLCommandBuffer>)commandBuffer;
@end
@interface FakeBlit : NSObject
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level
          sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
      destinationSlice:(NSUInteger)dslice destinationLevel:(NSUInteger)dlevel destinationOrigin:(MTLOrigin)dorigin;
- (void)endEncoding;
@end
@interface FakeRender : NSObject { @public FakeDevice *owner; FakeTexture *src, *dst; }
- (void)setViewport:(MTLViewport)v;
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p;
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)n atIndex:(NSUInteger)i;
- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)n atIndex:(NSUInteger)i;
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i;
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n;
- (void)endEncoding;
@end
@interface FakeBuffer : NSObject { @public FakeDevice *owner; }
- (id<MTLBlitCommandEncoder>)blitCommandEncoder;
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d;
- (void)presentDrawable:(id<MTLDrawable>)d;
- (void)commit;
- (void)waitUntilCompleted;
- (MTLCommandBufferStatus)status;
@end
@implementation FakeDevice
- (id<MTLCommandQueue>)newCommandQueue {
    queueCalls++; if (failQueue) return nil;
    FakeQueue *q = [FakeQueue new]; q->owner = self; return (id<MTLCommandQueue>)q;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    if (failAllocation) return nil;
    assert(desc.width * desc.height <= 64);
    FakeTexture *t = [FakeTexture new]; t->owner = self; t->format = desc.pixelFormat;
    t->width = (uint32_t)desc.width; t->height = (uint32_t)desc.height;
    return (id<MTLTexture>)t;
}
@end
@implementation FakeQueue
- (id<MTLCommandBuffer>)commandBuffer {
    if (owner->failBuffer) return nil;
    FakeBuffer *b = [FakeBuffer new]; b->owner = owner; return (id<MTLCommandBuffer>)b;
}
@end
@implementation FakeBlit
- (void)copyFromTexture:(id<MTLTexture>)s sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level
          sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)n toTexture:(id<MTLTexture>)d
      destinationSlice:(NSUInteger)dslice destinationLevel:(NSUInteger)dlevel destinationOrigin:(MTLOrigin)to {
    FakeTexture *src = (FakeTexture *)s, *dst = (FakeTexture *)d;
    assert(!slice && !level && !dslice && !dlevel && !o.z && !to.x && !to.y && !to.z && n.depth == 1);
    assert(o.x + n.width <= src->width && o.y + n.height <= src->height);
    for (NSUInteger y = 0; y < n.height; y++)
        memcpy(dst->pixels + y * dst->width, src->pixels + (o.y + y) * src->width + o.x, n.width * 4);
}
- (void)endEncoding {}
@end
@implementation FakeRender
- (void)setViewport:(MTLViewport)v { assert(v.width && v.height); }
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p { assert(p); }
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)n atIndex:(NSUInteger)i { (void)bytes; (void)n; (void)i; }
- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)n atIndex:(NSUInteger)i { (void)bytes; (void)n; (void)i; }
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i { assert(!i); src = (FakeTexture *)t; }
- (void)drawPrimitives:(MTLPrimitiveType)t vertexStart:(NSUInteger)s vertexCount:(NSUInteger)n {
    assert(t == MTLPrimitiveTypeTriangleStrip && !s && n == 4);
    memcpy(dst->pixels, src->pixels, sizeof(src->pixels)); owner->draws++;
}
- (void)endEncoding {}
@end
@implementation FakeBuffer
- (id<MTLBlitCommandEncoder>)blitCommandEncoder { return owner->failEncoder ? nil : (id<MTLBlitCommandEncoder>)[FakeBlit new]; }
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)d {
    assert(d.colorAttachments[0].loadAction == MTLLoadActionClear);
    assert(d.colorAttachments[0].storeAction == MTLStoreActionStore);
    FakeRender *e = [FakeRender new]; e->owner = owner; e->dst = (FakeTexture *)d.colorAttachments[0].texture;
    memset(e->dst->pixels, 0, sizeof(e->dst->pixels)); return (id<MTLRenderCommandEncoder>)e;
}
- (void)presentDrawable:(id<MTLDrawable>)d { assert(d); }
- (void)commit {}
- (void)waitUntilCompleted {}
- (MTLCommandBufferStatus)status { return owner->failGPU ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted; }
@end
@interface FakeDrawable : NSObject { @public FakeTexture *texture; }
- (id<MTLTexture>)texture;
@end
@implementation FakeDrawable
- (id<MTLTexture>)texture { return (id<MTLTexture>)texture; }
@end
@interface FakeLayer : NSObject { @public FakeDrawable *drawable; }
- (CGSize)drawableSize;
- (id<CAMetalDrawable>)nextDrawable;
@end
@implementation FakeLayer
- (CGSize)drawableSize { return CGSizeMake(8, 8); }
- (id<CAMetalDrawable>)nextDrawable { return (id<CAMetalDrawable>)drawable; }
@end

static FakeTexture *texture(FakeDevice *d) {
    FakeTexture *t = [FakeTexture new]; t->owner = d; t->format = MTLPixelFormatBGRA8Unorm; t->width = t->height = 8;
    for (unsigned i = 0; i < 64; i++) t->pixels[i] = 0xff305070;
    return t;
}
static void init_fb(HvFbDisplay *fb, uint32_t *cpu) {
    memset(fb, 0, sizeof(*fb)); pthread_mutex_init(&fb->mu, NULL);
    hv_fb_display_set_override(fb, (uint8_t *)cpu, 2, 2, 8);
}
static void assert_empty(const char *path) { struct stat st; assert(!stat(path, &st) && !st.st_size); }
static void snapshot_failures(const char *path) {
    uint32_t cpu[4] = {0xffaabbcc, 0xffaabbcc, 0xffaabbcc, 0xffaabbcc};
    HvFbDisplay fb; init_fb(&fb, cpu);
    FakeDevice *d = [FakeDevice new]; FakeTexture *t = texture(d);
    hv_fb_display_set_texture(&fb, (__bridge void *)t, 8, 8, 1, 1, 2, 2);
    int *failures[] = {&d->failQueue, &d->failAllocation, &d->failBuffer, &d->failEncoder, &d->failGPU};
    for (unsigned i = 0; i < sizeof(failures)/sizeof(*failures); i++) {
        *failures[i] = 1;
        assert(hv_fb_save_png(&fb, path) == -1); assert_empty(path);
        *failures[i] = 0;
    }
    unsigned calls = d->queueCalls;
    atomic_store(&g_paused, 1);
    assert(hv_fb_save_png(&fb, path) == -1); assert_empty(path); assert(d->queueCalls == calls);
    atomic_store(&g_paused, 0);
    t->format = MTLPixelFormatRGBA16Float;
    assert(hv_fb_save_png(&fb, path) == -1); assert_empty(path); assert(d->queueCalls == calls);
    t->format = MTLPixelFormatBGRA8Unorm;
    d->failGPU = 1;
    uint32_t w = 0, h = 0;
    assert(!hv_fb_metal_snapshot(&fb, 1, &w, &h));
    uint8_t *fallback = hv_fb_metal_snapshot(&fb, 2, &w, &h);
    assert(fallback && w == 2 && h == 2 && ((uint32_t *)fallback)[0] == cpu[0]); free(fallback);
    hv_fb_display_set_texture(&fb, NULL, 0, 0, 0, 0, 0, 0); pthread_mutex_destroy(&fb.mu);
}
static void snapshot_pixels(const char *path) {
    uint32_t cpu[4] = {0x00112233, 0x00445566, 0x00778899, 0x00aabbcc};
    HvFbDisplay fb; init_fb(&fb, cpu);
    assert(!hv_fb_save_png(&fb, path));
    struct stat st; assert(!stat(path, &st) && st.st_size > 32);
    FakeDevice *d = [FakeDevice new]; FakeTexture *t = texture(d);
    t->format = MTLPixelFormatRGBA8Unorm;
    t->pixels[9] = 0x00112233; t->pixels[10] = 0x00445566; t->pixels[17] = 0x00778899; t->pixels[18] = 0x00aabbcc;
    hv_fb_display_set_texture(&fb, (__bridge void *)t, 8, 8, 1, 1, 2, 2);
    uint32_t w, h;
    uint8_t *pixels = hv_fb_metal_snapshot(&fb, 1, &w, &h);
    assert(pixels && w == 2 && h == 2);
    assert(((uint32_t *)pixels)[0] == 0xff332211 && ((uint32_t *)pixels)[3] == 0xffccbbaa);
    free(pixels); assert(!hv_fb_save_png(&fb, path));
    hv_fb_display_set_texture(&fb, NULL, 0, 0, 0, 0, 0, 0); pthread_mutex_destroy(&fb.mu);
}
static void late_producer_cache_repro(void) {
    HvFbDisplay fb; init_fb(&fb, NULL);
    FakeDevice *d = [FakeDevice new]; FakeTexture *t = texture(d);
    hv_fb_display_set_texture(&fb, (__bridge void *)t, 8, 8, 0, 0, 8, 8);
    FakeDrawable *drawable = [FakeDrawable new]; drawable->texture = texture(d);
    FakeLayer *layer = [FakeLayer new]; layer->drawable = drawable;
    HvFbMetalPresenter *p = [HvFbMetalPresenter alloc];
    p->fb = &fb; p->lock = OS_UNFAIR_LOCK_INIT; p->device = (id<MTLDevice>)d;
    p->queue = [d newCommandQueue]; p->pipeline = (id<MTLRenderPipelineState>)[NSObject new];
    p->layer = (CAMetalLayer *)layer;
    hv_fb_display_override_flushed(&fb); /* simulate flush before source GPU completion */
    BOOL presented = NO;
    assert([p presentTexture:&presented] && presented && d->draws == 1);
    uint32_t old = drawable->texture->pixels[0];
    t->pixels[0] ^= 0x00ffffff; /* producer finishes without another flush */
    presented = NO; assert([p presentTexture:&presented] && !presented && d->draws == 1);
    assert(drawable->texture->pixels[0] == old);
    hv_fb_metal_set_view_transform(1.1f, 0, 0); /* host-only redraw diagnostic */
    assert([p presentTexture:&presented] && presented && d->draws == 2);
    assert(drawable->texture->pixels[0] == t->pixels[0]);
    hv_fb_metal_set_view_transform(1, 0, 0);
    hv_fb_display_set_texture(&fb, NULL, 0, 0, 0, 0, 0, 0); pthread_mutex_destroy(&fb.mu);
}
static void real_metal_readback(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) { puts("SKIP: real Metal device unavailable"); return; }
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:2 height:2 mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> upload = [d newTextureWithDescriptor:desc]; assert(upload);
    uint32_t original[4] = {0xff112233, 0xff445566, 0xff778899, 0xffaabbcc};
    [upload replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:original bytesPerRow:8];
    desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> src = [d newTextureWithDescriptor:desc]; assert(src);
    id<MTLCommandQueue> queue = [d newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:upload sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(2, 2, 1) toTexture:src destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; assert(cb.status == MTLCommandBufferStatusCompleted);
    HvFbDisplay fb; init_fb(&fb, NULL);
    hv_fb_display_set_texture(&fb, (__bridge void *)src, 2, 2, 0, 0, 2, 2);
    uint32_t w, h; uint8_t *copy = hv_fb_metal_snapshot(&fb, 1, &w, &h);
    assert(copy && w == 2 && h == 2 && !memcmp(copy, original, sizeof(original)));
    free(copy); hv_fb_display_set_texture(&fb, NULL, 0, 0, 0, 0, 0, 0); pthread_mutex_destroy(&fb.mu);
    puts("PASS: real Metal private-texture readback matches all pixels");
}
int main(void) {
    @autoreleasepool {
        char failed[] = "/tmp/applevm-capture-fail-XXXXXX", good[] = "/tmp/applevm-capture-ok-XXXXXX";
        int f = mkstemp(failed), g = mkstemp(good); assert(f >= 0 && g >= 0); close(f); close(g);
        snapshot_failures(failed);
        snapshot_pixels(good);
        late_producer_cache_repro();
        real_metal_readback();
        unlink(failed); unlink(good);
        puts("PASS: strict GPU capture errors cannot write CPU PNG; 2D and cropped RGBA work");
        puts("PASS: actual presenter reproduces early-flush stale cache; host transform redraws it");
    }
    return 0;
}
