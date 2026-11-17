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
    BOOL _armed, _active;
    /* PiP sessions (main): numbered at willStart; the one that last reached didStart. A didStop that arrives after a
       newer session began (left again during the stop animation) is not that session's: it leaves the feed alone. */
    uint64_t _session, _startedSession;
    /* the feed (main starts and stops it; the rest is its queue's) */
    dispatch_queue_t _feedQ;
    dispatch_source_t _feed;
    CVPixelBufferPoolRef _pool;
    uint32_t _poolW, _poolH;
    CVPixelBufferRef _last; /* the last frame, enqueued again after a flush */
    uint64_t _lastSerial;
    unsigned _flushes;
    _Atomic uint64_t _frames;
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
        else {
            [self stopFeed];
            [self clearPicture];
            [self setLayerHidden:YES];
        }
    }
}

/* ---- the layer and the controller ---- */

- (void)attachToView:(UIView *)view {
    if (!_layer) {
        _layer = [AVSampleBufferDisplayLayer layer];
        _layer.videoGravity = AVLayerVideoGravityResizeAspect;
        _layer.backgroundColor = nil; /* empty: transparent over the Metal picture */
        _layer.hidden = YES;          /* shown only from didEnterBackground or PiP's willStart (setLayerHidden:) */
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

/* Hidden in the front and while the app is only inactive: the Metal presenter draws the picture with its own zoom,
   pan and placement, which the layer's whole-screen fit would not match. */
- (void)setLayerHidden:(BOOL)hidden {
    if (!_layer || _layer.hidden == hidden) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _layer.hidden = hidden;
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

/* Inactive: the GPU still works. One snapshot (a 3D frame through one blit, the only GPU work PiP ever does), into
   the hidden layer; nothing else. */
- (void)onResignActive:(NSNotification *)note {
    (void)note;
    if (!_armed || !_layer || !WinIOSBridge.shared.isVMRunning) return;
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
    [self event:[NSString stringWithFormat:@"snapshot %ux%u (%s) in %.1f ms%@", w, h, isTex ? "3D" : "2D",
                                           (CFAbsoluteTimeGetCurrent() - t0) * 1000.0, ok ? @"" : @": not sent"]];
}

/* Off screen now: the layer may show (PiP takes it, and the app switcher's picture). The feed starts with PiP only. */
- (void)onBackground:(NSNotification *)note {
    (void)note;
    if (_armed) [self setLayerHidden:NO];
}

/* Back in front: the feed stops (and its last tick ends) before the final flush, so no frame stays over the live
   picture; PiP stops. */
- (void)onActive:(NSNotification *)note {
    (void)note;
    [self stopFeed];
    [self clearPicture];
    if (_active) [_controller stopPictureInPicture]; /* didStop hides the layer once PiP has let go of it */
    else [self setLayerHidden:YES];
}

/* Main, with the feed stopped: empties the layer (always, whatever it was showing). */
- (void)clearPicture {
    if (!_layer) return;
    dispatch_sync(_feedQ, ^{
        self->_lastSerial = 0; /* the next snapshot or frame is sent whatever it shows */
        if (self->_last) CVPixelBufferRelease(self->_last);
        self->_last = NULL;
    });
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

/* Returns once a tick already running has ended (cancel does not wait for it). */
- (void)stopFeed {
    if (!_feed) return;
    dispatch_source_cancel(_feed);
    _feed = nil;
    dispatch_sync(_feedQ, ^{});
}

/* The feed's queue: a new frame only when the 2D screen changed. Never the GPU: while the screen is a 3D texture the
   willResignActive snapshot stays, until the 2D driver is up. */
- (void)feedTick {
    AVSampleBufferVideoRenderer *r = _layer.sampleBufferRenderer;
    if (r.status == AVQueuedSampleBufferRenderingStatusFailed || r.requiresFlushToResumeDecoding) {
        unsigned n = ++_flushes;
        if (n <= 3 || n % 100 == 0)
            [self event:[NSString stringWithFormat:@"layer %@: flushed (%u)", r.requiresFlushToResumeDecoding ? @"needs a flush" : @"failed", n]];
        [r flush];
        if (_last) [self enqueue:_last];
    }
    int isTex = 0;
    uint64_t serial = hv_winvm_display_serial(&isTex);
    if (!serial || serial == _lastSerial || isTex) return;
    uint32_t w = 0, h = 0;
    uint8_t *px = hv_winvm_display_snapshot(0, &w, &h);
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
    _session++;
    [self event:@"willStart"];
    [self setLayerHidden:NO];
    [self startFeed];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)c {
    _active = YES;
    _startedSession = _session;
    [self event:@"didStart"];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [c stopPictureInPicture]; /* the app came back while PiP was starting: the picture is in the app */
        return;
    }
    [self startFeed];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c failedToStartPictureInPictureWithError:(NSError *)error {
    (void)c;
    [self event:[NSString stringWithFormat:@"failed to start: %@ %ld (%@)", error.domain, (long)error.code, error.localizedDescription]];
    [self stopFeed];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [self clearPicture];
        [self setLayerHidden:YES];
    }
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)c {
    (void)c;
    [self event:@"willStop"];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)c {
    (void)c;
    _active = NO;
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL current = _startedSession == _session; /* no newer session began meanwhile */
    [self event:[NSString stringWithFormat:@"didStop%@", current ? @"" : @" (a newer session began: its feed goes on)"]];
    if (front || current) [self stopFeed];
    if (front) {
        [self clearPicture];
        [self setLayerHidden:YES];
    }
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
