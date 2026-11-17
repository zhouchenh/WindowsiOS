/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Windows in Picture in Picture: see winios_pip.h. */
#import "winios_pip.h"
#import "winios_bridge.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "winvm.h"

NSNotificationName const WinIOSPiPEventNotification = @"WinIOSPiPEventNotification";

/* The picture in PiP is a small window: frames are at most this many pixels on their long side (fewer to copy). */
static const uint32_t kPiPMaxSide = 1920;
static const uint64_t kFeedIntervalNs = 100 * NSEC_PER_MSEC; /* 10 per second */

@interface WinIOSPictureInPicture () <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@end

@implementation WinIOSPictureInPicture {
    AVSampleBufferDisplayLayer *_layer;
    AVPictureInPictureController *_controller;
    UIView *__weak _host;
    BOOL _armed, _active, _shown; /* _shown: the layer holds a picture */
    /* the feed (its queue only) */
    dispatch_queue_t _feedQ;
    dispatch_source_t _feed;
    CVPixelBufferPoolRef _pool;
    uint32_t _poolW, _poolH;
    CVPixelBufferRef _last; /* the last frame, enqueued again after a flush */
    uint64_t _lastSerial;
    _Atomic uint64_t _frames;
    _Atomic int _gpuAllowed; /* the app is not in the background: a 3D frame may be read with a blit */
}

+ (WinIOSPictureInPicture *)shared {
    static WinIOSPictureInPicture *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[WinIOSPictureInPicture alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _feedQ = dispatch_queue_create("applevm.pip.feed", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        atomic_store(&_gpuAllowed, 1);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(onResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(onBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)event:(NSString *)text {
    fprintf(stderr, "winvm: pip: %s\n", text.UTF8String);
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter postNotificationName:WinIOSPiPEventNotification object:self userInfo:@{@"event": text}];
    };
    if (NSThread.isMainThread) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

- (BOOL)supported { return [AVPictureInPictureController isPictureInPictureSupported]; }
- (BOOL)possible { return _controller.pictureInPicturePossible; }
- (BOOL)active { return _active; }
- (uint64_t)framesSent { return atomic_load(&_frames); }

- (BOOL)armed { return _armed; }
- (void)setArmed:(BOOL)armed {
    if (armed == _armed) return;
    _armed = armed;
    WinIOSBridge.shared.pipArmed = armed;
    if (armed) [self makeController];
    _controller.canStartPictureInPictureAutomaticallyFromInline = armed;
    [self event:[NSString stringWithFormat:@"%@ (supported %d, possible %d, audio %@)", armed ? @"armed" : @"disarmed",
                                           self.supported, self.possible, WinIOSBridge.shared.audioCategoryName]];
    if (!armed) {
        if (_active) [_controller stopPictureInPicture];
        else [self clearPicture];
    }
}

/* ---- the layer and the controller ---- */

- (void)attachToView:(UIView *)view {
    if (!_layer) {
        _layer = [AVSampleBufferDisplayLayer layer];
        _layer.videoGravity = AVLayerVideoGravityResizeAspect;
        _layer.backgroundColor = nil; /* empty: transparent over the Metal picture */
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_layer.superlayer != view.layer) {
        [_layer removeFromSuperlayer];
        [view.layer insertSublayer:_layer atIndex:0]; /* below the view's subviews (the screen map) */
    }
    _layer.frame = view.layer.bounds;
    [CATransaction commit];
    _host = view;
    if (_armed) [self makeController];
}

- (void)detachFromView:(UIView *)view {
    if (_host != view) return;
    _host = nil;
    if (_active) return; /* PiP shows it: it stays in the layer until PiP stops */
    [_layer removeFromSuperlayer];
}

- (void)viewDidLayout:(UIView *)view {
    if (_host != view || !_layer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.frame = view.layer.bounds;
    [CATransaction commit];
}

- (void)makeController {
    if (_controller || !_layer || !self.supported) return;
    AVPictureInPictureControllerContentSource *src =
        [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:_layer playbackDelegate:self];
    _controller = [[AVPictureInPictureController alloc] initWithContentSource:src];
    _controller.delegate = self;
    _controller.requiresLinearPlayback = YES; /* live: no skip buttons */
    _controller.canStartPictureInPictureAutomaticallyFromInline = _armed;
    [_controller addObserver:self forKeyPath:@"pictureInPicturePossible" options:NSKeyValueObservingOptionNew context:NULL];
    [self event:@"controller made"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)object, (void)change, (void)context;
    if ([keyPath isEqualToString:@"pictureInPicturePossible"])
        [self event:[NSString stringWithFormat:@"possible %d", _controller.pictureInPicturePossible]];
}

/* ---- the app's lifecycle ---- */

/* Inactive: the GPU still works. One snapshot (a 3D frame through one blit), nothing else. */
- (void)onResignActive:(NSNotification *)note {
    (void)note;
    if (!_armed || !_layer || !WinIOSBridge.shared.isVMRunning) return;
    atomic_store(&_gpuAllowed, 1);
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    uint32_t w = 0, h = 0;
    uint8_t *px = hv_winvm_display_snapshot(1, &w, &h);
    int isTex = 0;
    uint64_t serial = hv_winvm_display_serial(&isTex);
    if (!px) {
        [self event:@"snapshot: no picture"];
        return;
    }
    __block BOOL ok = NO;
    dispatch_sync(_feedQ, ^{
        ok = [self sendPixels:px width:w height:h];
        self->_lastSerial = serial;
    });
    free(px);
    if (ok) _shown = YES;
    [self event:[NSString stringWithFormat:@"snapshot %ux%u (%s) in %.1f ms%@", w, h, isTex ? "3D" : "2D",
                                           (CFAbsoluteTimeGetCurrent() - t0) * 1000.0, ok ? @"" : @": not sent"]];
}

- (void)onBackground:(NSNotification *)note {
    (void)note;
    atomic_store(&_gpuAllowed, 0);
    if (_armed && _shown) [self startFeed];
}

- (void)onActive:(NSNotification *)note {
    (void)note;
    atomic_store(&_gpuAllowed, 1);
    [self stopFeed];
    if (_active) [_controller stopPictureInPicture]; /* the app is on screen: the picture is in the app */
    else [self clearPicture];
}

- (void)clearPicture {
    if (!_shown || !_layer) return;
    _shown = NO;
    [_layer.sampleBufferRenderer flushWithRemovalOfDisplayedImage:YES completionHandler:nil];
}

/* ---- the feed ---- */

- (void)startFeed {
    if (_feed) return;
    _feed = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _feedQ);
    dispatch_source_set_timer(_feed, dispatch_time(DISPATCH_TIME_NOW, (int64_t)kFeedIntervalNs), kFeedIntervalNs, 20 * NSEC_PER_MSEC);
    __weak WinIOSPictureInPicture *weakSelf = self;
    dispatch_source_set_event_handler(_feed, ^{ [weakSelf feedTick]; });
    dispatch_resume(_feed);
}

- (void)stopFeed {
    if (!_feed) return;
    dispatch_source_cancel(_feed);
    _feed = nil;
}

/* The feed's queue: a new frame only when the screen changed; a 3D screen is only read while the GPU may be used. */
- (void)feedTick {
    AVSampleBufferVideoRenderer *r = _layer.sampleBufferRenderer;
    if (r.status == AVQueuedSampleBufferRenderingStatusFailed || r.requiresFlushToResumeDecoding) {
        [self event:[NSString stringWithFormat:@"layer %@: flushed", r.requiresFlushToResumeDecoding ? @"needs a flush" : @"failed"]];
        [r flush];
        if (_last) [self enqueue:_last];
    }
    int isTex = 0;
    uint64_t serial = hv_winvm_display_serial(&isTex);
    if (!serial || serial == _lastSerial) return;
    int gpu = atomic_load(&_gpuAllowed);
    if (isTex && !gpu) return; /* still 3D: the snapshot stays until the 2D driver is up */
    uint32_t w = 0, h = 0;
    uint8_t *px = hv_winvm_display_snapshot(gpu, &w, &h);
    if (!px) return;
    _lastSerial = serial;
    [self sendPixels:px width:w height:h];
    free(px);
}

/* Feed queue: BGRA pixels (rows of w * 4) into a pixel buffer, scaled down to kPiPMaxSide, onto the layer. */
- (BOOL)sendPixels:(uint8_t *)px width:(uint32_t)w height:(uint32_t)h {
    if (!w || !h) return NO;
    uint32_t ow = w, oh = h;
    uint32_t side = w > h ? w : h;
    if (side > kPiPMaxSide) {
        ow = (uint32_t)((uint64_t)w * kPiPMaxSide / side) & ~1u;
        oh = (uint32_t)((uint64_t)h * kPiPMaxSide / side) & ~1u;
        if (!ow || !oh) return NO;
    }
    if (!_pool || _poolW != ow || _poolH != oh) {
        if (_pool) CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
        NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                (id)kCVPixelBufferWidthKey: @(ow),
                                (id)kCVPixelBufferHeightKey: @(oh),
                                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &_pool) != kCVReturnSuccess) return NO;
        _poolW = ow;
        _poolH = oh;
    }
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, _pool, &pb) != kCVReturnSuccess || !pb) return NO;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
    size_t dstride = CVPixelBufferGetBytesPerRow(pb);
    if (ow == w && oh == h) {
        for (uint32_t y = 0; y < h; y++) memcpy(dst + (size_t)y * dstride, px + (size_t)y * w * 4, (size_t)w * 4);
    } else {
        vImage_Buffer s = {.data = px, .height = h, .width = w, .rowBytes = (size_t)w * 4};
        vImage_Buffer d = {.data = dst, .height = oh, .width = ow, .rowBytes = dstride};
        vImageScale_ARGB8888(&s, &d, NULL, kvImageNoFlags);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    BOOL ok = [self enqueue:pb];
    if (_last) CVPixelBufferRelease(_last);
    _last = pb; /* kept for a flush */
    return ok;
}

- (BOOL)enqueue:(CVPixelBufferRef)pb {
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &fmt) != noErr) return NO;
    CMSampleTimingInfo timing = {.duration = kCMTimeInvalid,
                                 .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
                                 .decodeTimeStamp = kCMTimeInvalid};
    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, fmt, &timing, &sb);
    CFRelease(fmt);
    if (st != noErr || !sb) return NO;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFMutableDictionaryRef a = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        CFDictionarySetValue(a, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    [_layer.sampleBufferRenderer enqueueSampleBuffer:sb];
    CFRelease(sb);
    uint64_t n = atomic_fetch_add(&_frames, 1) + 1;
    if (n <= 3 || n % 600 == 0) [self event:[NSString stringWithFormat:@"frame %llu (%zux%zu)", (unsigned long long)n,
                                                                       CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)]];
    return YES;
}

/* ---- AVPictureInPictureControllerDelegate ---- */

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)c {
    (void)c;
    [self event:@"willStart"];
    if (_shown) [self startFeed];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)c {
    (void)c;
    _active = YES;
    [self event:@"didStart"];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c failedToStartPictureInPictureWithError:(NSError *)error {
    (void)c;
    [self event:[NSString stringWithFormat:@"failed to start: %@ %ld (%@)", error.domain, (long)error.code, error.localizedDescription]];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)c {
    (void)c;
    [self event:@"willStop"];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)c {
    (void)c;
    _active = NO;
    [self event:@"didStop"];
    [self stopFeed];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self clearPicture];
    if (!_host) [_layer removeFromSuperlayer];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    (void)c;
    [self event:@"restore (back to the app)"];
    completionHandler(YES); /* the Windows view is the app's only content: it is there */
}

/* ---- AVPictureInPictureSampleBufferPlaybackDelegate: live, always playing ---- */

- (void)pictureInPictureController:(AVPictureInPictureController *)c setPlaying:(BOOL)playing {
    [self event:[NSString stringWithFormat:@"play/pause pressed (%d): stays live", playing]];
    [c invalidatePlaybackState];
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)c {
    (void)c;
    return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity); /* live */
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)c {
    (void)c;
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c didTransitionToRenderSize:(CMVideoDimensions)size {
    (void)c;
    [self event:[NSString stringWithFormat:@"render size %dx%d", size.width, size.height]];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c skipByInterval:(CMTime)interval
                 completionHandler:(void (^)(void))completionHandler {
    (void)c, (void)interval;
    completionHandler();
}

- (BOOL)pictureInPictureControllerShouldProhibitBackgroundAudioPlayback:(AVPictureInPictureController *)c {
    (void)c;
    return NO; /* Windows' sound (and the silent keep-alive) goes on */
}

@end
