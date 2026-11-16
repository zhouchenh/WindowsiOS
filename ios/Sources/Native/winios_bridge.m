/* SPDX-License-Identifier: GPL-2.0-or-later */
#import "winios_bridge.h"
#include "virtio_gpu3d.h"

#include "hvsparse.h"
#include "fb_display.h"
#include <sys/sysctl.h>
#include "share.h"
#include "winios_jit.h"
#include "winvm.h"

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h> /* the mini-map's thumbnail */
#import <UIKit/UIKit.h>
#include <stdatomic.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <sys/stat.h>

static WinIOSBridge *s_shared_bridge = nil;

NSNotificationName const WinIOSDisplayStateDidChangeNotification = @"WinIOSDisplayStateDidChangeNotification";
NSNotificationName const WinIOSDisplayWillReshapeNotification = @"WinIOSDisplayWillReshapeNotification";

@interface WinIOSBridge () {
    BOOL _vmRunning;
    BOOL _unpacking;
    double _unpackProgress;
    NSString *_vmStatus;
    dispatch_queue_t _diagQueue;
    dispatch_source_t _diagTimer;
    CFAbsoluteTime _bootStartTime;
    uint64_t _configuredRamMB;
    int _configuredCPUs;
    CAMetalLayer *__weak _pendingLayer;
    uint64_t _diagTickCount;
    uint64_t _lastMachTicks;
    uint64_t _lastWfiTicks;
    double _lastWfiIdlePct;

    os_unfair_lock _metricsLock;
    CGSize _screenSizePts;
    uint32_t _gpuPrefW, _gpuPrefH;
    CGSize _displayViewPts;
    uint64_t _gpuPrefToken;
    BOOL _hiDPIDisplay;
    CGFloat _screenScale;
    NSInteger _hingeStatus;
    double _hingeAngleDegrees;
    BOOL _pausedInBackground;   /* the guest was stopped because the app went to the background */

    /* display sizing engine (main thread) */
    CGFloat _viewNativeScale;
    NSInteger _displayPreset, _displaySharpness;
    BOOL _displayImmersive, _immersiveKeeps;
    WinIOSDisplayPlan _committedPlan; /* sent to Windows (or to be sent at start) */
    CGSize _committedViewPts;
    WinIOSDisplayPlan _pendingPlan;
    CGSize _pendingViewPts;
    BOOL _hasPending, _reshapeAnnounced;
    WinIOSReshapeState _reshapeState;
    CFAbsoluteTime _reshapeStart;
    NSTimer *_reshapeWatch;
    BOOL _guestFollowsModes;
    NSUInteger _remodeCount;
    double _lastReshapeMs;
    WinIOSDisplayApplied _applied;
    NSDate *_appliedStamp;
    /* input the app has sent down, lifted on a reshape */
    double _tabletX, _tabletY;
    uint8_t _tabletButtons;
    uint8_t _keysDown[32];
}
- (void)handleVMExitWithReason:(NSString *)reason;
- (void)updateUnpackProgress:(double)frac;
- (void)startDiagTimer;
- (void)stopDiagTimer;
@end

static void vm_exit_trampoline(int reason) {
    NSString *r = [NSString stringWithUTF8String:hv_winvm_reason_name(reason)];
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_shared_bridge handleVMExitWithReason:r];
    });
}

typedef struct UnpackCtx {
    __unsafe_unretained WinIOSBridge *bridge;
    CFAbsoluteTime lastUpdate;
} UnpackCtx;

static void unpack_progress_cb(uint64_t done, uint64_t total, void *opaque) {
    UnpackCtx *ctx = (UnpackCtx *)opaque;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (done < total && now - ctx->lastUpdate < 0.2) return;
    ctx->lastUpdate = now;
    double frac = total ? (double)done / (double)total : 0.0;
    WinIOSBridge *b = ctx->bridge;
    dispatch_async(dispatch_get_main_queue(), ^{
        [b updateUnpackProgress:frac];
    });
}

/* On the device stderr goes nowhere useful (LiveContainer hands the app a pipe nobody reads): keep
   it in Documents/winvm.log (the previous run in winvm.prev.log) so a problem can be read
   afterwards. Set WINIOS_CONSOLE to leave stderr on the console instead. */
/* Documents/env.txt: KEY=VALUE lines set as environment variables before the machine starts, for
   switching diagnostics on a device that cannot be launched with an environment (LiveContainer).
   Lines starting with # are ignored. */
static void winios_load_env_file(NSString *docs) {
    NSString *text = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"env.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange eq = [line rangeOfString:@"="];
        if (!line.length || [line hasPrefix:@"#"] || eq.location == NSNotFound || eq.location == 0) continue;
        setenv([line substringToIndex:eq.location].UTF8String, [line substringFromIndex:eq.location + 1].UTF8String, 1);
    }
}

/* What the device's GPU offers, once per run, for comparing devices from their logs. */
static void winios_log_gpu_caps(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) { fprintf(stderr, "metal: no device\n"); return; }
    int fam = 0;
    for (int f = 1; f <= 12; f++) if ([d supportsFamily:(MTLGPUFamily)(1000 + f)]) fam = f; /* MTLGPUFamilyApple1 = 1001 */
    fprintf(stderr, "metal: %s apple%d bc=%d float32filter=%d rwtier=%d argbuf=%d maxbuf=%lluMB unified=%d\n",
            d.name.UTF8String, fam, (int)d.supportsBCTextureCompression, (int)d.supports32BitFloatFiltering,
            (int)d.readWriteTextureSupport, (int)d.argumentBuffersSupport,
            (unsigned long long)(d.maxBufferLength >> 20), (int)d.hasUnifiedMemory);
}

static int winios_log_to_file;
static void winios_capture_stderr(NSString *docs) {
    static int done;
    if (done) return;
    done = 1;
    if (getenv("WINIOS_CONSOLE")) return; /* a developer reading devicectl --console */
    NSString *log = [docs stringByAppendingPathComponent:@"winvm.log"];
    NSString *prev = [docs stringByAppendingPathComponent:@"winvm.prev.log"];
    rename(log.fileSystemRepresentation, prev.fileSystemRepresentation);
    if (freopen(log.fileSystemRepresentation, "w", stderr)) {
        setvbuf(stderr, NULL, _IOLBF, 0);
        winios_log_to_file = 1;
        fprintf(stderr, "winvm.log: stderr captured\n");
    }
}

@implementation WinIOSBridge

+ (WinIOSBridge *)shared {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_shared_bridge = [[WinIOSBridge alloc] init];
    });
    return s_shared_bridge;
}

- (instancetype)init {
    if ((self = [super init])) {
        _vmStatus = @"Idle";
        _metricsLock = OS_UNFAIR_LOCK_INIT;
        _screenSizePts = CGSizeZero;
        _screenScale = 3.0;
        _hingeStatus = 0;
        _hingeAngleDegrees = -1.0;
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        BOOL safariDefault = ([ud objectForKey:@"winios.safariOAuthV2"] == nil) ? YES : [ud boolForKey:@"winios.safariOAuthV2"];
        hv_share_set_url_handler_enabled(safariDefault ? 1 : 0);
        _hiDPIDisplay = [ud boolForKey:@"winios.hiDPIDisplay"];
        _displayPreset = 1;     /* DisplaySettings.swift pushes the saved choices at launch */
        _displaySharpness = 0;
        _guestFollowsModes = YES;
        _tabletX = _tabletY = 0.5;
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _diagQueue = dispatch_queue_create("me.ammaar.windowsios.diag", attr);
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        /* iOS refuses GPU work from the background while this app keeps running there (audio):
           everything Windows drew meanwhile was lost (missing tray, Start menu, text). So the guest
           CPUs stop when the app goes to the background and go on when it is back in front.
           Only the background counts: an app that is merely inactive (Control Center, a notification
           banner, the Face ID or passkey sheet during a Safari sign-in) is still on screen and may
           still use the GPU, and stopping Windows then would stall the sign-in it is waiting for. */
        [nc addObserver:self selector:@selector(onAppBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppBackgroundOrTerminate:) name:UIApplicationWillTerminateNotification object:nil];
        [nc addObserver:self selector:@selector(onAudioInterruption:) name:AVAudioSessionInterruptionNotification object:nil];
    }
    return self;
}

- (void)configureAudioSessionAndMicPermission {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategoryOptions opts = AVAudioSessionCategoryOptionDefaultToSpeaker |
                                         AVAudioSessionCategoryOptionAllowBluetooth |
                                         AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                         AVAudioSessionCategoryOptionMixWithOthers;
    NSError *err = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:&err]) {
        /* Fallback to Playback if PlayAndRecord temporarily rejected before permission */
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    }
    [session setPreferredSampleRate:48000.0 error:nil];
    [session setPreferredIOBufferDuration:0.010 error:nil];
    [session setActive:YES error:nil];

    if (@available(iOS 17.0, *)) {
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
            if (granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    AVAudioSession *s = [AVAudioSession sharedInstance];
                    [s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:opts error:nil];
                    [s setActive:YES error:nil];
                });
            }
        }];
    }
}

- (void)onAudioInterruption:(NSNotification *)note {
    NSNumber *typeNum = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (typeNum && typeNum.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    }
}

- (void)onAppBackground:(NSNotification *)note {
    (void)note;
    if (_vmRunning && !getenv("WINIOS_RUN_IN_BACKGROUND")) {
        hv_winvm_set_paused(1);
        _pausedInBackground = YES;
        fprintf(stderr, "winvm: paused (app in the background)\n");
    }
}

- (void)resumeFromBackground {
    if (!_pausedInBackground) return;
    _pausedInBackground = NO;
    if (_vmRunning) {
        hv_winvm_set_paused(0);
        fprintf(stderr, "winvm: resumed\n");
    }
}

- (void)onAppForeground:(NSNotification *)note {
    (void)note;
    /* While this notification is delivered the app is still in the background state, where GPU
       work is refused: go on once UIKit has finished moving it to the foreground (DidBecomeActive
       also resumes, for when that comes first). */
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
            [self resumeFromBackground];
        }
    });
}

- (void)onAppActive:(NSNotification *)note {
    (void)note;
    [self resumeFromBackground];
}

- (void)onAppBackgroundOrTerminate:(NSNotification *)note {
    (void)note;
    if (_vmRunning) {
        dispatch_async(_diagQueue, ^{
            hv_winvm_flush_disks();
        });
    }
}

- (void)notifyChanged {
    if ([NSThread isMainThread]) {
        if (self.onStateChanged) self.onStateChanged();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onStateChanged) self.onStateChanged();
        });
    }
}

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale {
    os_unfair_lock_lock(&_metricsLock);
    _screenSizePts = size;
    if (scale > 0.0) _screenScale = scale;
    os_unfair_lock_unlock(&_metricsLock);
}

static BOOL winios_machine_is_linux(void);

/* Points -> a mode virtio-gpu accepts: at least 960x600 (scaled up, aspect kept), even sizes. (Legacy sizing.) */
static void winios_gpu_mode_for(CGSize pts, uint32_t *w, uint32_t *h) {
    double fw = pts.width, fh = pts.height;
    if (fw < 1 || fh < 1) { *w = *h = 0; return; }
    /* A phone's view is only ~400 points wide: Windows needs about 960x600 to be usable. */
    double up = fmax(960.0 / fw, 600.0 / fh);
    if (up > 1.0) { fw *= up; fh *= up; }
    *w = ((uint32_t)fw) & ~1u;
    *h = ((uint32_t)fh) & ~1u;
}

/* ---- Display sizing: the guest mode is the picture area in native panel pixels / k, and Windows' scale
   is chosen with it so the workspace keeps a usable size (UX study, section 4.2).
     P = the view in native pixels (bounds x nativeScale), even
     k = 1 Sharp (1:1 pixels) or 2 Balanced (exactly half, shown at 2x)
     G = even(P / k), the mode Windows gets
     preset factor f / floor F: Larger Text 1.10 / 600, Default 0.92 / 680, More Space 0.74 / 820
     s_pref = the scale step nearest to 100 x nativeScale x f
     s = the largest step <= max(100, s_pref / k) with min(G) / (s / 100) >= F; none: 100% and the preset
         is not available here (Balanced then falls back to Sharp)
   Windows' workspace is G / (s / 100): the "Looks like" readout. ---- */
static const uint32_t kWinScaleSteps[] = {100, 125, 150, 175, 200, 225, 250, 300, 350};
#define WINIOS_NSTEPS (sizeof kWinScaleSteps / sizeof *kWinScaleSteps)
static const double kPresetFactor[3] = {1.10, 0.92, 0.74};
static const double kPresetFloor[3] = {600.0, 680.0, 820.0};

static uint32_t winios_even(double v) { return v < 2 ? 0 : ((uint32_t)v) & ~1u; }

static WinIOSDisplayPlan winios_plan_k(uint32_t pw, uint32_t ph, double n, NSInteger preset, int k) {
    WinIOSDisplayPlan p = {0};
    p.pictureWidth = pw; p.pictureHeight = ph; p.sharpness = k;
    uint32_t gw = winios_even((double)pw / k), gh = winios_even((double)ph / k);
    BOOL grown = gw < 640 || gh < 480;
    if (grown) { /* virtio-gpu's smallest mode (Balanced is then no exact 2x: not offered, see below) */
        double up = fmax(640.0 / fmax(gw, 1), 480.0 / fmax(gh, 1));
        gw = winios_even(ceil(gw * up) + 1); gh = winios_even(ceil(gh * up) + 1);
    }
    if (gw > 8192 || gh > 8192) {
        double dn = fmin(8192.0 / gw, 8192.0 / gh);
        gw = winios_even(gw * dn); gh = winios_even(gh * dn);
    }
    p.modeWidth = gw; p.modeHeight = gh;
    double want = 100.0 * n * kPresetFactor[preset];
    uint32_t pref = kWinScaleSteps[0];
    for (size_t i = 0; i < WINIOS_NSTEPS; i++)
        if (fabs(kWinScaleSteps[i] - want) < fabs(pref - want)) pref = kWinScaleSteps[i];
    double target = fmax(100.0, (double)pref / k);
    uint32_t s = 0;
    for (size_t i = WINIOS_NSTEPS; i-- > 0;) {
        uint32_t st = kWinScaleSteps[i];
        if (st <= target + 0.001 && fmin(gw, gh) * 100.0 / st >= kPresetFloor[preset]) { s = st; break; }
    }
    p.available = s != 0 && !(grown && k > 1);
    p.scalePercent = s ? s : 100;
    p.lookWidth = (uint32_t)lround(gw * 100.0 / p.scalePercent);
    p.lookHeight = (uint32_t)lround(gh * 100.0 / p.scalePercent);
    return p;
}

static WinIOSDisplayPlan winios_plan(CGSize pts, double n, NSInteger preset, NSInteger sharpness) {
    if (n <= 0) n = 2.0;
    if (preset < 0 || preset > 2) preset = 1;
    uint32_t pw = winios_even(floor(pts.width * n + 0.01)), ph = winios_even(floor(pts.height * n + 0.01));
    if (!pw || !ph) return (WinIOSDisplayPlan){0};
    int k = sharpness == 1 ? 1 : sharpness == 2 ? 2 : ((double)pw * ph > 2.6e6 ? 2 : 1);
    WinIOSDisplayPlan p = winios_plan_k(pw, ph, n, preset, k);
    if (k == 2 && !p.available) p = winios_plan_k(pw, ph, n, preset, 1); /* Balanced only where it fits */
    return p;
}

static BOOL winios_plans_equal(WinIOSDisplayPlan a, WinIOSDisplayPlan b) {
    return a.modeWidth == b.modeWidth && a.modeHeight == b.modeHeight && a.scalePercent == b.scalePercent &&
           a.legacy == b.legacy;
}

/* The size the guest should use, where the guest-side helper reads it (http://10.0.2.4/res.txt):
   "WxH@scale" (e.g. "2576x1812@250"), or "WxH" with legacy sizing. */
- (void)publishWantedPlan:(WinIOSDisplayPlan)plan {
    if (!plan.modeWidth || !plan.modeHeight) return;
    NSString *dir = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *line = plan.legacy ? [NSString stringWithFormat:@"%ux%u", plan.modeWidth, plan.modeHeight]
                                 : [NSString stringWithFormat:@"%ux%u@%u", plan.modeWidth, plan.modeHeight, plan.scalePercent];
    [line writeToFile:[dir stringByAppendingPathComponent:@"res.txt"] atomically:YES encoding:NSASCIIStringEncoding error:nil];
}

/* HV_DISPLAY_LEGACY=1 (Documents/env.txt): the sizing from before the 1:1 pipeline (points, at least
   960x600, 1.5 s settle, linear filtering, drawable at UIScreen.scale); =0 forces the new one. Unset:
   legacy for Linux guests only (nothing in them sets a scale), the new sizing for Windows. */
- (BOOL)displayLegacy {
    const char *v = getenv("HV_DISPLAY_LEGACY");
    if (v && *v) return *v != '0';
    return winios_machine_is_linux();
}

- (WinIOSDisplayPlan)planForView:(CGSize)pts preset:(NSInteger)preset sharpness:(NSInteger)sharpness {
    if (pts.width < 1 || pts.height < 1) return (WinIOSDisplayPlan){0};
    os_unfair_lock_lock(&_metricsLock);
    CGFloat scale = _screenScale > 0 ? _screenScale : 2.0;
    CGFloat n = _viewNativeScale > 0 ? _viewNativeScale : scale;
    os_unfair_lock_unlock(&_metricsLock);
    if (self.displayLegacy) {
        WinIOSDisplayPlan p = {0};
        uint32_t w = 0, h = 0;
        winios_gpu_mode_for(_hiDPIDisplay ? CGSizeMake(pts.width * scale, pts.height * scale) : pts, &w, &h);
        p.pictureWidth = w; p.pictureHeight = h; p.modeWidth = w; p.modeHeight = h;
        p.scalePercent = 0; p.lookWidth = w; p.lookHeight = h; p.available = 1; p.legacy = 1;
        p.sharpness = _hiDPIDisplay ? 1 : 0;
        return p;
    }
    return winios_plan(pts, n, preset, sharpness);
}

- (WinIOSDisplayPlan)displayPlanForPreset:(NSInteger)preset sharpness:(NSInteger)sharpness {
    os_unfair_lock_lock(&_metricsLock);
    CGSize pts = _displayViewPts;
    os_unfair_lock_unlock(&_metricsLock);
    return [self planForView:pts preset:preset sharpness:sharpness];
}

- (WinIOSDisplayPlan)currentDisplayPlan {
    return _hasPending ? _pendingPlan : _committedPlan;
}

- (BOOL)hiDPIDisplay {
    if (self.displayLegacy) return _hiDPIDisplay;
    WinIOSDisplayPlan p = self.currentDisplayPlan;
    return p.modeWidth ? p.sharpness == 1 : _displaySharpness == 1;
}

/* The former switch. With the new sizing it picks Sharp (on) or Balanced (off). */
- (void)setHiDPIDisplay:(BOOL)on {
    _hiDPIDisplay = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"winios.hiDPIDisplay"];
    if (self.displayLegacy) [self replanDisplay:@"hidpi"];
    else self.displaySharpness = on ? 1 : 2;
}

- (NSInteger)displaySizePreset { return _displayPreset; }
- (void)setDisplaySizePreset:(NSInteger)preset {
    preset = MAX(0, MIN(2, preset));
    if (preset == _displayPreset) return;
    _displayPreset = preset;
    [self replanDisplay:@"display size"];
}

- (NSInteger)displaySharpness { return _displaySharpness; }
- (void)setDisplaySharpness:(NSInteger)sharpness {
    sharpness = MAX(0, MIN(2, sharpness));
    if (sharpness == _displaySharpness) return;
    _displaySharpness = sharpness;
    [self replanDisplay:@"sharpness"];
}

- (BOOL)displayImmersive { return _displayImmersive; }
- (void)setDisplayImmersive:(BOOL)on {
    if (on == _displayImmersive) return;
    _displayImmersive = on;
    fprintf(stderr, "display: immersive %s (%s)\n", on ? "on" : "off", _immersiveKeeps ? "keeps the resolution" : "full panel");
    [self replanDisplay:@"immersive"];
}

- (BOOL)immersiveKeepsResolution { return _immersiveKeeps; }
- (void)setImmersiveKeepsResolution:(BOOL)keep {
    if (keep == _immersiveKeeps) return;
    _immersiveKeeps = keep;
    if (_displayImmersive) [self replanDisplay:@"immersive"];
}

- (void)updateDisplayViewSize:(CGSize)size {
    os_unfair_lock_lock(&_metricsLock);
    _displayViewPts = size;
    os_unfair_lock_unlock(&_metricsLock);
    [self replanDisplay:@"view"];
}

- (void)updateDisplayViewSize:(CGSize)size nativeScale:(CGFloat)nativeScale {
    os_unfair_lock_lock(&_metricsLock);
    _displayViewPts = size;
    if (nativeScale > 0) _viewNativeScale = nativeScale;
    os_unfair_lock_unlock(&_metricsLock);
    [self replanDisplay:@"view"];
}

- (void)postDisplayStateChanged {
    dispatch_block_t post = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:WinIOSDisplayStateDidChangeNotification object:self];
    };
    if ([NSThread isMainThread]) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

/* Reshape pipeline (UX study 4.3): only settled sizes reach Windows. A size is sent once it has held for
   300 ms; a change under 30 pt (bars, banners) waits 1 s and is dropped if it reverts meanwhile; a newer
   size replaces a waiting one. A real reshape first lifts what the app holds down (buttons, keys) and
   tells the views to cancel their touches. Main thread. */
- (void)replanDisplay:(NSString *)why {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self replanDisplay:why]; });
        return;
    }
    os_unfair_lock_lock(&_metricsLock);
    CGSize pts = _displayViewPts;
    os_unfair_lock_unlock(&_metricsLock);
    WinIOSDisplayPlan plan = [self planForView:pts preset:_displayPreset sharpness:_displaySharpness];
    if (!plan.modeWidth) return;
    if (_displayImmersive && _immersiveKeeps && _committedPlan.modeWidth && !plan.legacy) {
        /* immersive, keeping the resolution: no re-mode; the presenter fits the picture to the panel */
        if (_hasPending) {
            _gpuPrefToken++;
            _hasPending = NO;
            _reshapeAnnounced = NO;
            if (_reshapeState == WinIOSReshapeStateIdle) hv_fb_metal_hold_for_size(0, 0, 0);
            [self postDisplayStateChanged];
        }
        return;
    }
    if (winios_plans_equal(plan, _committedPlan)) {
        if (_hasPending) {
            _gpuPrefToken++;
            _hasPending = NO;
            _reshapeAnnounced = NO;
            if (_reshapeState == WinIOSReshapeStateIdle) hv_fb_metal_hold_for_size(0, 0, 0);
            fprintf(stderr, "display: %.0fx%.0f pt is back within the settle time: no re-mode\n", pts.width, pts.height);
            [self postDisplayStateChanged];
        }
        return;
    }
    if (_hasPending && winios_plans_equal(plan, _pendingPlan)) {
        _pendingViewPts = pts;
        return; /* already waiting for this one */
    }
    BOOL modeChanges = plan.modeWidth != _committedPlan.modeWidth || plan.modeHeight != _committedPlan.modeHeight;
    BOOL small = modeChanges && _committedPlan.modeWidth && fabs(pts.width - _committedViewPts.width) < 30 &&
                 fabs(pts.height - _committedViewPts.height) < 30;
    double delay = plan.legacy ? 1.5 : small ? 1.0 : 0.3;
    _pendingPlan = plan;
    _pendingViewPts = pts;
    _hasPending = YES;
    uint64_t token = ++_gpuPrefToken;
    if (!_vmRunning) { /* nothing to re-mode yet: this is what Windows gets when it starts */
        [self commitPendingPlan:why];
        return;
    }
    if (modeChanges && !small && !plan.legacy) {
        /* the last good frame stays (scaled by the layer) through the settle time too, not a letterboxed one */
        if (_guestFollowsModes && [self guestDisplayDriverUp])
            hv_fb_metal_hold_for_size(plan.modeWidth, plan.modeHeight, (uint32_t)((delay + 3.0) * 1000));
        if (!_reshapeAnnounced) {
            _reshapeAnnounced = YES;
            [self releaseAllInputForReshape];
            [[NSNotificationCenter defaultCenter] postNotificationName:WinIOSDisplayWillReshapeNotification object:self];
        }
    }
    [self postDisplayStateChanged];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_gpuPrefToken || !self->_hasPending) return;
        [self commitPendingPlan:why];
    });
}

/* The size of the picture Windows draws now (see framebufferWidth). */
- (void)guestPictureWidth:(uint32_t *)w height:(uint32_t *)h {
    *w = self.framebufferWidth;
    *h = self.framebufferHeight;
}

/* Is Windows' own display driver (virtio-gpu) running, so that a new mode can be followed at all? */
- (BOOL)guestDisplayDriverUp {
    char line[768] = "";
    if (!_vmRunning || hv_winvm_gpu_status(line, sizeof line) < 0) return NO;
    return strstr(line, "driver_ok=1") != NULL && strstr(line, "stage=os") != NULL;
}

- (void)commitPendingPlan:(NSString *)why {
    if (!_hasPending) return;
    WinIOSDisplayPlan plan = _pendingPlan, old = _committedPlan;
    _hasPending = NO;
    _reshapeAnnounced = NO;
    _committedPlan = plan;
    _committedViewPts = _pendingViewPts;
    os_unfair_lock_lock(&_metricsLock);
    _gpuPrefW = plan.modeWidth;
    _gpuPrefH = plan.modeHeight;
    CGFloat n = _viewNativeScale;
    os_unfair_lock_unlock(&_metricsLock);
    BOOL modeChanged = plan.modeWidth != old.modeWidth || plan.modeHeight != old.modeHeight;
    fprintf(stderr, "display: %s %ux%u@%u%% (view %.1fx%.1f pt, nativeScale %.4f, picture %ux%u px, k=%d, preset %ld%s), "
                    "looks like %ux%u [%s]\n",
            _vmRunning ? "request" : "planned", plan.modeWidth, plan.modeHeight, plan.scalePercent, _committedViewPts.width,
            _committedViewPts.height, n, plan.pictureWidth, plan.pictureHeight, plan.sharpness, (long)_displayPreset,
            plan.legacy ? ", legacy" : plan.available ? "" : ", preset not available here", plan.lookWidth, plan.lookHeight,
            why.UTF8String);
    if (_vmRunning) {
        if (modeChanged) {
            hv_winvm_set_preferred_display(plan.modeWidth, plan.modeHeight);
            _remodeCount++;
            uint32_t gw = 0, gh = 0;
            [self guestPictureWidth:&gw height:&gh];
            BOOL already = gw == plan.modeWidth && gh == plan.modeHeight;
            if ([self guestDisplayDriverUp] && !already) {
                /* the old picture stays (scaled by the layer) until Windows draws at the new size, 3 s at most;
                   not when Windows did not follow the last time (no helper or driver): no freeze for nothing */
                if (_guestFollowsModes && !plan.legacy) hv_fb_metal_hold_for_size(plan.modeWidth, plan.modeHeight, 3000);
                [self startReshapeWatch];
            } else {
                [self endReshapeWatch:WinIOSReshapeStateIdle];
            }
        }
        [self publishWantedPlan:plan];
    }
    [self postDisplayStateChanged];
    [self notifyChanged];
}

- (void)startReshapeWatch {
    [_reshapeWatch invalidate];
    _reshapeStart = CFAbsoluteTimeGetCurrent();
    _reshapeState = WinIOSReshapeStateWaiting;
    __weak typeof(self) weakSelf = self;
    _reshapeWatch = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        (void)t;
        [weakSelf reshapeWatchTick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_reshapeWatch forMode:NSRunLoopCommonModes]; /* also while scrolling */
    [self postDisplayStateChanged];
}

- (void)endReshapeWatch:(WinIOSReshapeState)state {
    [_reshapeWatch invalidate];
    _reshapeWatch = nil;
    if (_reshapeState != state) {
        _reshapeState = state;
        [self postDisplayStateChanged];
    }
}

- (void)reshapeWatchTick {
    if (!_vmRunning) {
        [self endReshapeWatch:WinIOSReshapeStateIdle];
        return;
    }
    double elapsed = CFAbsoluteTimeGetCurrent() - _reshapeStart;
    uint32_t gw = 0, gh = 0;
    [self guestPictureWidth:&gw height:&gh];
    if (gw == _committedPlan.modeWidth && gh == _committedPlan.modeHeight) {
        _lastReshapeMs = elapsed * 1000.0;
        _guestFollowsModes = YES;
        fprintf(stderr, "display: Windows is at %ux%u after %.0f ms (re-mode %lu)\n", _committedPlan.modeWidth,
                _committedPlan.modeHeight, _lastReshapeMs, (unsigned long)_remodeCount);
        [self endReshapeWatch:WinIOSReshapeStateIdle];
        [self refreshAppliedDisplay];
        return;
    }
    WinIOSReshapeState st = elapsed >= 10.0 ? WinIOSReshapeStateStuck
                          : elapsed >= 3.0  ? WinIOSReshapeStateSlow
                                            : WinIOSReshapeStateWaiting;
    if (st != _reshapeState) {
        _reshapeState = st;
        if (st == WinIOSReshapeStateStuck) {
            _guestFollowsModes = NO;
            fprintf(stderr, "display: Windows did not take %ux%u within 10 s (still %ux%u): display driver or helper missing?\n",
                    _committedPlan.modeWidth, _committedPlan.modeHeight, gw, gh);
        }
        [self postDisplayStateChanged];
    }
    if (elapsed > 600.0) [self endReshapeWatch:WinIOSReshapeStateIdle];
}

- (WinIOSReshapeState)displayReshapeState { return _reshapeState; }
- (NSUInteger)displayRemodeCount { return _remodeCount; }
- (double)lastReshapeMillis { return _lastReshapeMs; }

/* The helper's report (winkit/setres.ps1 PUTs res_applied.txt), e.g.
   "2576x1812@250 live min=100 max=300 rec=200": the mode, the scale Windows accepted, how (live,
   signout, failed) and the range Windows allows for this mode. */
- (void)refreshAppliedDisplay {
    NSString *f = [[[self documentsPath] stringByAppendingPathComponent:@"Shared"] stringByAppendingPathComponent:@"res_applied.txt"];
    NSDate *stamp = [[NSFileManager defaultManager] attributesOfItemAtPath:f error:nil][NSFileModificationDate];
    if (!stamp) return;
    if (_appliedStamp && [stamp isEqualToDate:_appliedStamp]) {
        _applied.age = -stamp.timeIntervalSinceNow;
        return;
    }
    NSString *t = [[NSString stringWithContentsOfFile:f encoding:NSASCIIStringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    WinIOSDisplayApplied a = {0};
    char method[16] = "";
    unsigned w = 0, h = 0, sc = 0, mn = 0, mx = 0, rec = 0;
    if (t.length && sscanf(t.UTF8String, "%ux%u@%u %15s min=%u max=%u rec=%u", &w, &h, &sc, method, &mn, &mx, &rec) >= 4) {
        a.modeWidth = w; a.modeHeight = h; a.scalePercent = sc;
        a.minPercent = mn; a.maxPercent = mx; a.recommendedPercent = rec;
        a.method = !strcmp(method, "live") ? 1 : !strcmp(method, "signout") ? 2 : 3;
    }
    a.age = -stamp.timeIntervalSinceNow;
    _applied = a;
    _appliedStamp = stamp;
    fprintf(stderr, "display: helper reports \"%s\"\n", t.length ? t.UTF8String : "");
    [self postDisplayStateChanged];
}

- (WinIOSDisplayApplied)appliedDisplay { return _applied; }

- (WinIOSPresenterStats)presenterStats {
    HvFbMetalStats s;
    hv_fb_metal_get_stats(&s);
    WinIOSPresenterStats o = {
        .frames = s.frames, .ticks = s.ticks, .held = s.held, .cpuNanos = s.cpu_ns, .uploadBytes = s.upload_bytes,
        .linkHz = s.link_hz, .idle = s.idle, .nearest = s.nearest, .holding = s.holding,
        .srcWidth = s.src_w, .srcHeight = s.src_h, .dstWidth = s.dst_w, .dstHeight = s.dst_h, .scaleX100 = s.scale_x100,
    };
    return o;
}

/* Lift every button and key the app has sent down: before Windows re-modes (a posture change mid-drag must
   not leave a button held) and whenever the UI asks. Modifiers are always lifted. Main thread. */
- (void)releaseAllInputForReshape {
    if (!_vmRunning) return;
    if (_tabletButtons) {
        _tabletButtons = 0;
        hv_winvm_tablet(_tabletX, _tabletY, 0, 0);
    }
    for (int u = 0; u < 256; u++) {
        BOOL mod = u >= 0xe0 && u <= 0xe7;
        if (mod || (_keysDown[u >> 3] & (1u << (u & 7)))) hv_winvm_key_hid((uint8_t)u, 0);
    }
    memset(_keysDown, 0, sizeof _keysDown);
}

/* display hooks in the input paths: what is held down (for the release above), and input for the presenter's
   idle throttling */
- (void)trackKey:(uint8_t)usage down:(BOOL)down {
    if (down) _keysDown[usage >> 3] |= (uint8_t)(1u << (usage & 7));
    else _keysDown[usage >> 3] &= (uint8_t)~(1u << (usage & 7));
    hv_fb_metal_note_input();
}

- (void)noteUserInput {
    hv_fb_metal_note_input();
}

- (void)trackTabletX:(double)x y:(double)y buttons:(uint8_t)buttons {
    _tabletX = x; _tabletY = y; _tabletButtons = buttons;
    hv_fb_metal_note_input();
}

- (void)updateHingeStatus:(NSInteger)status angleDegrees:(double)angleDegrees {
    os_unfair_lock_lock(&_metricsLock);
    _hingeStatus = status;
    _hingeAngleDegrees = angleDegrees;
    os_unfair_lock_unlock(&_metricsLock);
}

- (void)installTrapGuard {
    winios_jit_install_trap_handler();
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    [self configureAudioSessionAndMicPermission];
    UIScreen *mainScreen = [UIScreen mainScreen];
    [self updateScreenSize:mainScreen.bounds.size scale:mainScreen.scale];
    [self notifyChanged];
}

- (BOOL)tryAcquireJIT:(BOOL)detachAfter {
    BOOL ok = winios_jit_acquire(winios_jit_configured_bytes(), detachAfter);
    dispatch_async(_diagQueue, ^{
        [self writeDiagnosticsSnapshot];
    });
    [self notifyChanged];
    return ok;
}

- (BOOL)isJITLive {
    return winios_jit_is_live();
}

- (BOOL)isDebuggerAttached {
    return winios_jit_is_debugger_attached();
}

- (BOOL)isVMRunning {
    return _vmRunning;
}

- (BOOL)isUnpacking {
    return _unpacking;
}

- (double)unpackProgress {
    return _unpackProgress;
}

- (NSString *)jitStatusText {
    return [NSString stringWithUTF8String:winios_jit_status_text()];
}

- (NSString *)vmStatusText {
    return _vmStatus;
}

/* The picture on screen: the presenter's last frame when there is one (with 3D the scanout is a Metal
   texture that the 2D framebuffer size does not follow), else the 2D framebuffer. */
- (uint32_t)framebufferWidth {
    if (!_vmRunning) return 0;
    HvFbMetalStats s;
    hv_fb_metal_get_stats(&s);
    if (s.frames && s.src_w && s.src_h) return s.src_w;
    uint32_t w = 0, h = 0;
    if (hv_winvm_display_size(&w, &h) == 0) return w;
    return 0;
}

- (uint32_t)framebufferHeight {
    if (!_vmRunning) return 0;
    HvFbMetalStats s;
    hv_fb_metal_get_stats(&s);
    if (s.frames && s.src_w && s.src_h) return s.src_h;
    uint32_t w = 0, h = 0;
    if (hv_winvm_display_size(&w, &h) == 0) return h;
    return 0;
}

- (uint64_t)presentedFrames {
    return _vmRunning ? hv_winvm_display_frames() : 0;
}

- (uint64_t)availableMemoryMB {
    return (uint64_t)(winios_available_memory_bytes() >> 20);
}

- (BOOL)usbKeyboardReady {
    if (!_vmRunning) return NO;
    int kr = 0;
    hv_winvm_usb_stats(&kr, NULL, NULL);
    return kr != 0;
}

- (BOOL)usbTabletReady {
    if (!_vmRunning) return NO;
    int tr = 0;
    hv_winvm_usb_stats(NULL, &tr, NULL);
    return tr != 0;
}

- (uint64_t)usbEventsDelivered {
    if (!_vmRunning) return 0;
    uint64_t d = 0;
    hv_winvm_usb_stats(NULL, NULL, &d);
    return d;
}

- (NSString *)documentsPath {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
}

/* The device's model identifier, e.g. "iPad17,1". */
static NSString *winios_model_identifier(void) {
    char buf[64] = {0};
    size_t len = sizeof buf - 1;
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0 || !buf[0]) return @"Apple";
    return @(buf);
}

/* Its marketing name and chip. iOS has no public way to ask, so: a table of recent devices, else
   "iPad (iPad99,9)" and no chip. Names and chips follow Henge's ios/Henge/DeviceIdentity.swift
   (Leviidev/Henge 7b55730, GPL-2.0, itself from adamawolf/3048717 and AppleDB), plus the M5 iPads. */
static NSArray<NSString *> *winios_model_entry(NSString *ident) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"iPhone13,1": @[@"iPhone 12 mini", @"Apple A14"], @"iPhone13,2": @[@"iPhone 12", @"Apple A14"],
            @"iPhone13,3": @[@"iPhone 12 Pro", @"Apple A14"], @"iPhone13,4": @[@"iPhone 12 Pro Max", @"Apple A14"],
            @"iPhone14,2": @[@"iPhone 13 Pro", @"Apple A15"], @"iPhone14,3": @[@"iPhone 13 Pro Max", @"Apple A15"],
            @"iPhone14,4": @[@"iPhone 13 mini", @"Apple A15"], @"iPhone14,5": @[@"iPhone 13", @"Apple A15"],
            @"iPhone14,6": @[@"iPhone SE (A15)", @"Apple A15"],
            @"iPhone14,7": @[@"iPhone 14", @"Apple A15"], @"iPhone14,8": @[@"iPhone 14 Plus", @"Apple A15"],
            @"iPhone15,2": @[@"iPhone 14 Pro", @"Apple A16"], @"iPhone15,3": @[@"iPhone 14 Pro Max", @"Apple A16"],
            @"iPhone15,4": @[@"iPhone 15", @"Apple A16"], @"iPhone15,5": @[@"iPhone 15 Plus", @"Apple A16"],
            @"iPhone16,1": @[@"iPhone 15 Pro", @"Apple A17 Pro"], @"iPhone16,2": @[@"iPhone 15 Pro Max", @"Apple A17 Pro"],
            @"iPhone17,1": @[@"iPhone 16 Pro", @"Apple A18 Pro"], @"iPhone17,2": @[@"iPhone 16 Pro Max", @"Apple A18 Pro"],
            @"iPhone17,3": @[@"iPhone 16", @"Apple A18"], @"iPhone17,4": @[@"iPhone 16 Plus", @"Apple A18"],
            @"iPhone17,5": @[@"iPhone 16e", @"Apple A18"],
            @"iPhone18,1": @[@"iPhone 17 Pro", @"Apple A19 Pro"], @"iPhone18,2": @[@"iPhone 17 Pro Max", @"Apple A19 Pro"],
            @"iPhone18,3": @[@"iPhone 17", @"Apple A19"], @"iPhone18,4": @[@"iPhone Air", @"Apple A19 Pro"],
            @"iPhone18,5": @[@"iPhone 17e", @"Apple A19"],
            @"iPhone19,2": @[@"iPhone 18 Pro", @"Apple A20 Pro"], @"iPhone19,3": @[@"iPhone 18 Pro Max", @"Apple A20 Pro"],
            @"iPhone19,7": @[@"iPhone 18 Pro Max", @"Apple A20 Pro"],
            @"iPhone19,4": @[@"iPhone Duo", @"Apple A20 Pro"],
            @"iPad13,1": @[@"iPad Air (A14)", @"Apple A14"], @"iPad13,2": @[@"iPad Air (A14)", @"Apple A14"],
            @"iPad13,4": @[@"iPad Pro 11-inch (M1)", @"Apple M1"], @"iPad13,5": @[@"iPad Pro 11-inch (M1)", @"Apple M1"],
            @"iPad13,6": @[@"iPad Pro 11-inch (M1)", @"Apple M1"], @"iPad13,7": @[@"iPad Pro 11-inch (M1)", @"Apple M1"],
            @"iPad13,8": @[@"iPad Pro 12.9-inch (M1)", @"Apple M1"], @"iPad13,9": @[@"iPad Pro 12.9-inch (M1)", @"Apple M1"],
            @"iPad13,10": @[@"iPad Pro 12.9-inch (M1)", @"Apple M1"], @"iPad13,11": @[@"iPad Pro 12.9-inch (M1)", @"Apple M1"],
            @"iPad13,16": @[@"iPad Air (M1)", @"Apple M1"], @"iPad13,17": @[@"iPad Air (M1)", @"Apple M1"],
            @"iPad13,18": @[@"iPad (10th generation)", @"Apple A14"], @"iPad13,19": @[@"iPad (10th generation)", @"Apple A14"],
            @"iPad14,1": @[@"iPad mini (A15)", @"Apple A15"], @"iPad14,2": @[@"iPad mini (A15)", @"Apple A15"],
            @"iPad14,3": @[@"iPad Pro 11-inch (M2)", @"Apple M2"], @"iPad14,4": @[@"iPad Pro 11-inch (M2)", @"Apple M2"],
            @"iPad14,5": @[@"iPad Pro 12.9-inch (M2)", @"Apple M2"], @"iPad14,6": @[@"iPad Pro 12.9-inch (M2)", @"Apple M2"],
            @"iPad14,8": @[@"iPad Air 11-inch (M2)", @"Apple M2"], @"iPad14,9": @[@"iPad Air 11-inch (M2)", @"Apple M2"],
            @"iPad14,10": @[@"iPad Air 13-inch (M2)", @"Apple M2"], @"iPad14,11": @[@"iPad Air 13-inch (M2)", @"Apple M2"],
            @"iPad15,3": @[@"iPad Air 11-inch (M3)", @"Apple M3"], @"iPad15,4": @[@"iPad Air 11-inch (M3)", @"Apple M3"],
            @"iPad15,5": @[@"iPad Air 13-inch (M3)", @"Apple M3"], @"iPad15,6": @[@"iPad Air 13-inch (M3)", @"Apple M3"],
            @"iPad15,7": @[@"iPad (A16)", @"Apple A16"], @"iPad15,8": @[@"iPad (A16)", @"Apple A16"],
            @"iPad16,1": @[@"iPad mini (A17 Pro)", @"Apple A17 Pro"], @"iPad16,2": @[@"iPad mini (A17 Pro)", @"Apple A17 Pro"],
            @"iPad16,3": @[@"iPad Pro 11-inch (M4)", @"Apple M4"], @"iPad16,4": @[@"iPad Pro 11-inch (M4)", @"Apple M4"],
            @"iPad16,5": @[@"iPad Pro 13-inch (M4)", @"Apple M4"], @"iPad16,6": @[@"iPad Pro 13-inch (M4)", @"Apple M4"],
            @"iPad17,1": @[@"iPad Pro 11-inch (M5)", @"Apple M5"], @"iPad17,2": @[@"iPad Pro 11-inch (M5)", @"Apple M5"],
            @"iPad17,3": @[@"iPad Pro 13-inch (M5)", @"Apple M5"], @"iPad17,4": @[@"iPad Pro 13-inch (M5)", @"Apple M5"],
        };
    });
    return table[ident];
}

static NSString *winios_model_name(NSString *ident) {
    NSString *n = winios_model_entry(ident).firstObject;
    if (n) return n;
    NSString *kind = [ident hasPrefix:@"iPad"] ? @"iPad" : [ident hasPrefix:@"iPhone"] ? @"iPhone" : @"Apple device";
    return [NSString stringWithFormat:@"%@ (%@)", kind, ident];
}

/* The device's chip ("Apple A20 Pro"), nil when the table does not know the device. */
static NSString *winios_model_chip(NSString *ident) {
    NSArray<NSString *> *e = winios_model_entry(ident);
    return e.count > 1 ? e[1] : nil;
}

/* Which machine the launch page picked: "Win11" (default) or "Arch" (Arch Linux ARM). Each has its
   own folder under Documents/Machines with the same file names (code.fd, vars.fd, windows11.*). */
static BOOL winios_machine_is_linux(void) {
    return [[[NSUserDefaults standardUserDefaults] stringForKey:@"winios.machine"] isEqualToString:@"Arch"];
}

/* One of the app's raw-DEFLATE resources (scripts/build_arch_installer.py) unpacked to a file. */
static NSString *winios_unpack_resource(NSString *name, NSString *dst) {
    NSString *src = [[NSBundle mainBundle] pathForResource:name ofType:@"z"];
    if (!src) return [NSString stringWithFormat:@"the app has no %@", name];
    NSData *z = [NSData dataWithContentsOfFile:src options:NSDataReadingMappedIfSafe error:nil];
    NSError *err = nil;
    NSData *raw = [z decompressedDataUsingAlgorithm:NSDataCompressionAlgorithmZlib error:&err];
    if (!raw) return [NSString stringWithFormat:@"unpacking %@: %@", name, err.localizedDescription];
    if (![raw writeToFile:dst options:NSDataWritingAtomic error:&err])
        return [NSString stringWithFormat:@"writing %@: %@", dst.lastPathComponent, err.localizedDescription];
    return nil;
}

/* A new Arch Linux machine, installed by the machine itself: the firmware, a blank (sparse) system disk
   of sizeGB and the installer disk (installer.img), which the firmware starts while the system disk is
   blank. The installer downloads Arch Linux ARM, then the installed system's first boot adds the desktop
   and the GPU drivers; both report to Documents/Shared/arch_install_status.txt. nil when ready. */
- (nullable NSString *)prepareArchInstallWithSizeGB:(NSUInteger)sizeGB {
    if (!winios_machine_is_linux()) return @"not the Arch machine";
    if (_vmRunning) return @"the machine is running";
    NSString *dir = [self machineDirectory];
    NSString *disk = [dir stringByAppendingPathComponent:@"windows11.img"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:disk]) return @"there is a system disk already";
    NSString *e;
    if ((e = winios_unpack_resource(@"arch-code.fd", [dir stringByAppendingPathComponent:@"code.fd"]))) return e;
    if ((e = winios_unpack_resource(@"arch-vars.fd", [dir stringByAppendingPathComponent:@"vars.fd"]))) return e;
    if ((e = winios_unpack_resource(@"arch-installer.img", [dir stringByAppendingPathComponent:@"installer.img"]))) return e;
    int fd = open(disk.fileSystemRepresentation, O_CREAT | O_EXCL | O_RDWR, 0644);
    if (fd < 0 || ftruncate(fd, (off_t)MAX(sizeGB, 8u) << 30) != 0) {
        NSString *msg = [NSString stringWithFormat:@"creating the system disk: %s", strerror(errno)];
        if (fd >= 0) close(fd);
        unlink(disk.fileSystemRepresentation);
        return msg;
    }
    close(fd);
    NSString *shared = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    [[NSFileManager defaultManager] createDirectoryAtPath:shared withIntermediateDirectories:YES attributes:nil error:nil];
    [@"0 waiting to start\n" writeToFile:[shared stringByAppendingPathComponent:@"arch_install_status.txt"]
                             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return nil;
}

- (void)setDisplayFrameRate:(NSInteger)fps {
    hv_fb_metal_set_fps((int)fps);
}

/* The installation's last report ("<percent> <message>", or "error ..."), nil when there is none. */
- (nullable NSString *)archInstallStatus {
    NSString *f = [[[self documentsPath] stringByAppendingPathComponent:@"Shared"] stringByAppendingPathComponent:@"arch_install_status.txt"];
    NSString *t = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding error:nil];
    t = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return t.length ? t : nil;
}

/* Is a new Arch installation still under way (the installer disk is there, or the first boot has not finished)? */
- (BOOL)archInstallPending {
    if (!winios_machine_is_linux()) return NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[self machineDirectory] stringByAppendingPathComponent:@"installer.img"]]) return YES;
    NSString *st = [self archInstallStatus];
    return st && ![st hasPrefix:@"100"];
}

- (NSString *)machineDirectory {
    NSString *docs = [self documentsPath];
    if (winios_machine_is_linux()) {
        /* WINIOS_ARCH_DIR: another folder for Arch (testing a fresh installation next to a used one) */
        const char *alt = getenv("WINIOS_ARCH_DIR");
        NSString *archDir = [docs stringByAppendingPathComponent:alt && *alt ? @(alt) : @"Machines/Arch"];
        [[NSFileManager defaultManager] createDirectoryAtPath:archDir withIntermediateDirectories:YES attributes:nil error:nil];
        return archDir;
    }
    NSString *win11Dir = [docs stringByAppendingPathComponent:@"Machines/Win11"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:[win11Dir stringByAppendingPathComponent:@"code.fd"]]) {
        return win11Dir;
    }
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"code.fd"]]) {
        return docs;
    }
    [fm createDirectoryAtPath:win11Dir withIntermediateDirectories:YES attributes:nil error:nil];
    return win11Dir;
}

- (BOOL)hasRawDiskImageAt:(NSString *)dir {
    NSString *raw = [dir stringByAppendingPathComponent:@"windows11.img"];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:raw error:nil];
    return attrs && [attrs fileSize] >= (64ull << 20);
}

- (BOOL)needsSparseUnpack {
    NSString *dir = [self machineDirectory];
    NSString *sparse = [dir stringByAppendingPathComponent:@"windows11.hvsparse"];
    return [[NSFileManager defaultManager] fileExistsAtPath:sparse];
}

- (BOOL)hasProvisionedMachine {
    NSString *dir = [self machineDirectory];
    NSFileManager *fm = [NSFileManager defaultManager];
    /* WINIOS_ARCH_PREPARE_GB (testing): set up a new installation when the Arch folder has no system disk */
    const char *prep = getenv("WINIOS_ARCH_PREPARE_GB");
    if (prep && winios_machine_is_linux() && !_vmRunning &&
        ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"windows11.img"]]) {
        NSString *e = [self prepareArchInstallWithSizeGB:(NSUInteger)atoi(prep)];
        fprintf(stderr, "winvm: new Arch installation: %s\n", e ? e.UTF8String : "prepared");
    }
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"code.fd"]]) return NO;
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"vars.fd"]]) return NO;
    return [self hasRawDiskImageAt:dir] || [self needsSparseUnpack];
}

- (void)updateUnpackProgress:(double)frac {
    _unpackProgress = frac;
    _vmStatus = [NSString stringWithFormat:@"Unpacking Windows 11 NVMe image (%.0f%%)...", frac * 100.0];
    dispatch_async(_diagQueue, ^{
        [self writeDiagnosticsSnapshot];
    });
    [self notifyChanged];
}

- (void)bindMetalLayer:(nullable CAMetalLayer *)layer {
    _pendingLayer = layer;
    if (_vmRunning) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }
}

- (void)prepareAndStartWithLayer:(nullable CAMetalLayer *)layer {
    if (layer) _pendingLayer = layer;
    if (_vmRunning || _unpacking) return;

    if (!self.isJITLive) {
        [self tryAcquireJIT:YES];
        if (!self.isJITLive) {
            _vmStatus = @"Waiting for TXM JIT (attach StikDebug or launch_on_duo.sh)";
            dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
            [self notifyChanged];
            return;
        }
    }

    if (![self hasProvisionedMachine]) {
        _vmStatus = @"Import the machine's files (code.fd, vars.fd and the disk) on the launch page";
        dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
        [self notifyChanged];
        return;
    }

    NSString *dir = [self machineDirectory];
    if ([self needsSparseUnpack]) {
        _unpacking = YES;
        _unpackProgress = 0.0;
        _vmStatus = @"Unpacking Windows 11 NVMe image (0%)...";
        dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
        [self notifyChanged];

        NSString *src = [dir stringByAppendingPathComponent:@"windows11.hvsparse"];
        NSString *dst = [dir stringByAppendingPathComponent:@"windows11.img"];
        NSString *tmpDst = [dir stringByAppendingPathComponent:@"windows11.img.unpacking"];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            unlink(tmpDst.fileSystemRepresentation);
            unlink(dst.fileSystemRepresentation);
            UnpackCtx ctx = {.bridge = self, .lastUpdate = 0};
            int rc = hv_sparse_unpack(src.fileSystemRepresentation, tmpDst.fileSystemRepresentation, unpack_progress_cb, &ctx);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_unpacking = NO;
                if (rc == 0) {
                    unlink(dst.fileSystemRepresentation);
                    rename(tmpDst.fileSystemRepresentation, dst.fileSystemRepresentation);
                    unlink(src.fileSystemRepresentation);
                    self->_unpackProgress = 1.0;
                    [self startConfiguredVMInDirectory:dir];
                } else {
                    unlink(tmpDst.fileSystemRepresentation);
                    self->_vmStatus = @"Error: failed to unpack windows11.hvsparse";
                    dispatch_async(self->_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
                    [self notifyChanged];
                }
            });
        });
        return;
    }

    [self startConfiguredVMInDirectory:dir];
}

- (void)startConfiguredVMInDirectory:(NSString *)dir {
    if (_vmRunning) return;
    [self configureAudioSessionAndMicPermission];

    WinIosDualMapping jit = winios_jit_mapping();
    if (!jit.rx_addr || !jit.rw_addr) {
        _vmStatus = @"Error: JIT region missing";
        [self notifyChanged];
        return;
    }

    NSString *ramBacking = [NSTemporaryDirectory() stringByAppendingPathComponent:@"win11_guest_ram.bin"];
    winios_load_env_file([self documentsPath]);
    BOOL linuxGuest = winios_machine_is_linux();
    /* Linux: its console on the serial port goes to the log (winvm.log), the boot can be followed there. */
    if (linuxGuest) setenv("HV_SERIAL_STDERR", "1", 1);
    if (getenv("HV_SMBIOS_SKU") && !strcmp(getenv("HV_SMBIOS_SKU"), "WINIOS-CLI")) unsetenv("HV_SMBIOS_SKU"); /* the former command-line mode */
    winios_capture_stderr([self documentsPath]);
    winios_log_gpu_caps();
    /* A running Windows keeps the screen on: auto-lock would suspend the whole machine. */
    dispatch_async(dispatch_get_main_queue(), ^{ UIApplication.sharedApplication.idleTimerDisabled = YES; });
    setenv("HV_RAM_FILE", ramBacking.fileSystemRepresentation, 1);

    uint64_t preallocBytes = 0;
    void *preallocRam = winios_jit_guest_ram(&preallocBytes);
    uint64_t ramMB = 3072;
    if (preallocRam && preallocBytes >= (1024ull << 20)) {
        ramMB = preallocBytes >> 20;
    } else {
        uint64_t availMB = [self availableMemoryMB];
        if (availMB >= 5000) ramMB = 4096;
        else if (availMB >= 4200) ramMB = 3584;
        else if (availMB < 3400 && availMB > 1800) ramMB = (availMB - 768) & ~127ull;
        else if (availMB <= 1800) ramMB = 2048;
    }

    NSString *sharedDir = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    [[NSFileManager defaultManager] createDirectoryAtPath:sharedDir withIntermediateDirectories:YES attributes:nil error:nil];
    /* Keep AF_UNIX sun_path well under Darwin's 104-byte limit (~82 bytes vs 106 bytes) */
    NSString *rawTmp = [NSTemporaryDirectory() stringByReplacingOccurrencesOfString:@"/private/var/" withString:@"/var/"];
    NSString *shareSock = [rawTmp stringByAppendingPathComponent:@"s"];
    unlink(shareSock.fileSystemRepresentation);

    NSString *codePath = [dir stringByAppendingPathComponent:@"code.fd"];
    NSString *varsPath = [dir stringByAppendingPathComponent:@"vars.fd"];
    NSString *diskPath = [dir stringByAppendingPathComponent:@"windows11.img"];
    /* Optional read-only second disk (e.g. drivers.img with NetKVM) shown to Windows as an extra drive. */
    NSString *disk1Path = [dir stringByAppendingPathComponent:@"drivers.img"];
    BOOL hasDisk1 = [[NSFileManager defaultManager] fileExistsAtPath:disk1Path];
    if (winios_machine_is_linux()) {
        /* The installer disk: started by the firmware while the system disk is blank. Once the installer
           has put the system on it (it reports 75 or more), it is not needed any more. */
        NSString *inst = [dir stringByAppendingPathComponent:@"installer.img"];
        hasDisk1 = [[NSFileManager defaultManager] fileExistsAtPath:inst];
        disk1Path = inst;
        NSString *st = [self archInstallStatus];
        if (hasDisk1 && st && st.intValue >= 75 && ![st hasPrefix:@"error"]) {
            [[NSFileManager defaultManager] removeItemAtPath:inst error:nil];
            hasDisk1 = NO;
            fprintf(stderr, "winvm: Arch installer done (%s): its disk is removed\n", st.UTF8String);
        }
    }
    /* The app carries the WinKit disk itself (winkit.img, put in by scripts/embed_gpu3d.sh): used when
       none was imported, or when the imported one is older than the app's, so a new app brings its
       scripts and drivers along. */
    NSString *bundledKit = [[NSBundle mainBundle] pathForResource:@"winkit" ofType:@"img"];
    if (bundledKit && !winios_machine_is_linux()) { /* Windows drivers and scripts: nothing for Linux */
        NSDate *mine = [[NSFileManager defaultManager] attributesOfItemAtPath:bundledKit error:nil][NSFileModificationDate];
        NSDate *theirs = hasDisk1 ? [[NSFileManager defaultManager] attributesOfItemAtPath:disk1Path error:nil][NSFileModificationDate] : nil;
        if (!hasDisk1 || (mine && theirs && [mine compare:theirs] == NSOrderedDescending)) {
            fprintf(stderr, "winvm: WinKit disk from the app (%s)\n", hasDisk1 ? "the imported one is older" : "none imported");
            disk1Path = bundledKit;
            hasDisk1 = YES;
        }
    }

    _configuredRamMB = ramMB;
    _configuredCPUs = 4;

    /* virtio-gpu 3D: virglrenderer + DXMT frameworks embedded in the app (see virtio_gpu3d.c). */
    NSString *fwDir = [[NSBundle mainBundle] privateFrameworksPath];
    NSString *vrPath = [fwDir stringByAppendingPathComponent:@"virglrenderer.1.framework/virglrenderer.1"];
    /* Opt-in while the Windows 3D driver is unfinished: Documents/gpu3d.on turns it on. */
    NSString *gpu3dFlag = [[self documentsPath] stringByAppendingPathComponent:@"gpu3d.on"];
    /* Two places: Documents/gpu3d.on, and Documents/Shared/gpu3d.on which the guest can write
       (http://10.0.2.4/), so the Windows-side setup can switch host 3D on by itself. 3D is on when
       either file exists and does not say "off". */
    BOOL gpu3dOn = NO;
    for (NSString *flag in @[gpu3dFlag, [[[self documentsPath] stringByAppendingPathComponent:@"Shared"]
                                            stringByAppendingPathComponent:@"gpu3d.on"]]) {
        NSString *t = [[[NSString stringWithContentsOfFile:flag encoding:NSUTF8StringEncoding error:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if (t != nil && ![t hasPrefix:@"off"] && ![t hasPrefix:@"0"]) gpu3dOn = YES;
    }
    /* Linux: always 3D. Its Mesa (virgl driver) draws OpenGL through virglrenderer's VIRGL capset,
       which this renderer runs on ANGLE/Metal; nothing has to be installed on the guest side first. */
    if (winios_machine_is_linux()) gpu3dOn = getenv("HV_NO_GPU3D") == NULL;
    /* Venus: Vulkan 1.4 for Linux guests, run on the host's Vulkan through the manifests the app
       carries. MoltenVK by default: KosmicKrisp hangs the app when the guest starts Vulkan (and
       trips a Metal validation assert: linear 2D-array textures). OpenGL stays on virgl.
       HV_NO_VENUS=1 turns it off, HV_VK_DRIVER=kosmickrisp picks the other driver. */
    if (winios_machine_is_linux() && !getenv("HV_NO_VENUS")) setenv("HV_GPU3D_VENUS", "1", 0);
    if (winios_machine_is_linux()) {
        NSString *icd = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"vulkan/icd.d"];
        const char *drv = getenv("HV_VK_DRIVER");
        NSString *json = [icd stringByAppendingPathComponent:(drv && !strcmp(drv, "kosmickrisp")) ? @"kosmickrisp_mesa_icd.json" : @"MoltenVK_icd.json"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:json]) setenv("VK_DRIVER_FILES", json.fileSystemRepresentation, 0);
    }
    if (fwDir && [[NSFileManager defaultManager] fileExistsAtPath:vrPath] && gpu3dOn) {
        NSString *dxmt = [fwDir stringByAppendingPathComponent:@"dxmt-native.framework/dxmt-native"];
        setenv("HV_GPU3D_FRAMEWORKS", fwDir.fileSystemRepresentation, 1);
        setenv("NPT_BACKEND", "dxmt", 0);
        setenv("NPT_D3D11_LIBRARY_PATH", dxmt.fileSystemRepresentation, 0);
        setenv("NPT_DXGI_LIBRARY_PATH", dxmt.fileSystemRepresentation, 0);
        setenv("NPT_D3D12_LIBRARY_PATH", dxmt.fileSystemRepresentation, 0);
        setenv("DXMT_LOG_LEVEL", winios_log_to_file ? "warn" : "none", 0);
        /* The renderer says why something failed; Linux guests (OpenGL through virgl) make it warn on
           every texture upload, so only errors for them. */
        setenv("VIRGL_LOG_LEVEL", winios_machine_is_linux() ? "error" : "warning", 0);
        if (winios_log_to_file) setenv("DXMT_LOG_PATH", [self documentsPath].fileSystemRepresentation, 0);
        /* Metal on iOS has no logic ops, which D3D 11.1 requires: a driver claiming 11.1 without them is
           rejected by the D3D11 runtime (DXGI_ERROR_DRIVER_INTERNAL_ERROR). */
        setenv("DXMT_CONFIG", "d3d11.maxFeatureLevel=11_0", 0);
        uint64_t winBytes = 0;
        void *win = winios_gpu_window(&winBytes);
        if (win) hv_vgpu3d_set_window(win, winBytes);
    }

    /* The CPU name Windows shows: Documents/cpu_name.txt if present, else from the device's chip. */
    {
        NSString *nameFile = [[self documentsPath] stringByAppendingPathComponent:@"cpu_name.txt"];
        NSString *cpuName = [[NSString stringWithContentsOfFile:nameFile encoding:NSUTF8StringEncoding error:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!cpuName.length) cpuName = winios_model_chip(winios_model_identifier());
        if (cpuName.length) setenv("HV_CPU_NAME", cpuName.UTF8String, 1);
    }

    /* The screen's refresh rate (Settings > Refresh rate): what the virtual display's EDID offers the guest.
       Linux only: Windows' display driver drops a preferred mode that is not 60 Hz, and with it the
       screen's own resolution, so Windows always gets 60. */
    {
        NSInteger hz = [[NSUserDefaults standardUserDefaults] integerForKey:@"winios.fps"];
        if (hz <= 0 || !winios_machine_is_linux()) hz = 60;
        setenv("HV_DISPLAY_HZ", [NSString stringWithFormat:@"%ld", (long)hz].UTF8String, 1);
    }

    /* The machine's product name (what fastfetch shows as Host, Windows as the system model): the device
       it runs on. Documents/product_name.txt overrides it. */
    {
        NSString *nameFile = [[self documentsPath] stringByAppendingPathComponent:@"product_name.txt"];
        NSString *product = [[NSString stringWithContentsOfFile:nameFile encoding:NSUTF8StringEncoding error:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *model = winios_model_identifier();
        if (!product.length) product = winios_model_name(model);
        setenv("HV_SMBIOS_PRODUCT", product.UTF8String, 1);
        setenv("HV_SMBIOS_MODEL", model.UTF8String, 1);
    }

    /* A vCPU waiting for an interrupt spins briefly before it sleeps: wake-ups (input, vsync, IPIs)
       then cost microseconds, not a scheduler round trip. */
    setenv("HV_WFI_SPIN", "40", 0);

    HvWinVmConfig cfg = {
        .code_fd = codePath.fileSystemRepresentation,
        .vars_fd = varsPath.fileSystemRepresentation,
        .disk0 = diskPath.fileSystemRepresentation,
        .disk1 = hasDisk1 ? disk1Path.fileSystemRepresentation : NULL,
        .share_dir = sharedDir.fileSystemRepresentation,
        .share_sock = shareSock.fileSystemRepresentation,
        .ncpus = _configuredCPUs,
        .ram_mb = _configuredRamMB,
        .jit_bytes = jit.size,
        .jit_rx = jit.rx_addr,
        .jit_rw = jit.rw_addr,
        .prealloc_ram = preallocRam,
        .no_net = 0,
        .enable_sound = 1,
        .log = 0,
        .stats_interval = getenv("HV_STATS") ? atoi(getenv("HV_STATS")) : 0, /* seconds between engine stats lines on stderr */
    };

    [self usePortForwardsOfMachineDirectory:dir]; /* portfwd hook: this machine's saved forwards open with its network */
    char err[256] = {0};
    if (hv_winvm_create(&cfg, err, sizeof err) != 0) {
        _vmStatus = [NSString stringWithFormat:@"VM create failed: %s", err];
        dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
        [self notifyChanged];
        return;
    }

    /* display sizing: env.txt is loaded now (HV_DISPLAY_LEGACY), so plan again from the view's size */
    hv_fb_metal_set_legacy_fit(self.displayLegacy);
    [self replanDisplay:@"start"];
    if (_hasPending) [self commitPendingPlan:@"start"];
    uint32_t gpuW = _committedPlan.modeWidth, gpuH = _committedPlan.modeHeight;
    if (gpuW && gpuH) hv_winvm_set_preferred_display(gpuW, gpuH); /* before the driver starts: no event needed */
    [self publishWantedPlan:_committedPlan];
    [self postDisplayStateChanged];

    CAMetalLayer *layer = _pendingLayer;
    if (layer) {
        hv_winvm_set_display_layer((__bridge void *)layer);
    }

    _vmRunning = YES;
    _bootStartTime = CFAbsoluteTimeGetCurrent();
    _diagTickCount = 0;
    _lastMachTicks = mach_absolute_time();
    _lastWfiTicks = 0;
    _lastWfiIdlePct = 0.0;
    _vmStatus = [NSString stringWithFormat:@"Running %@ (%d vCPUs, %llu MB RAM)",
                 winios_machine_is_linux() ? @"Arch Linux ARM" : @"Windows 11 ARM64", _configuredCPUs, _configuredRamMB];
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];

    hv_winvm_start(1, vm_exit_trampoline);

    [self startDiagTimer];
    dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
    [self notifyChanged];
}

- (void)startDiagTimer {
    [self stopDiagTimer];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _diagQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                              8ull * NSEC_PER_SEC,
                              1ull * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf onDiagTickBackground];
    });
    _diagTimer = timer;
    dispatch_resume(timer);
}

- (void)stopDiagTimer {
    if (_diagTimer) {
        dispatch_source_cancel(_diagTimer);
        _diagTimer = nil;
    }
}

/* Recovery aid (no working guest display): Documents/type.request holds one command line; the app
   opens the Run box, types it, starts it elevated and accepts the UAC prompt. Runs on a worker thread. */
static void winios_key(uint8_t usage, int shift) {
    if (shift) { hv_winvm_key_hid(0xe1, 1); usleep(30000); }
    hv_winvm_key_hid(usage, 1); usleep(45000);
    hv_winvm_key_hid(usage, 0); usleep(30000);
    if (shift) { hv_winvm_key_hid(0xe1, 0); usleep(30000); }
}

static void winios_type_run(NSString *text) {
    int plain = [text hasPrefix:@"!"]; /* "!": plain Enter, no elevation */
    int direct = [text hasPrefix:@">"]; /* ">": typed where the cursor is (a console), no Run box */
    if (plain || direct) text = [text substringFromIndex:1];
    if (direct) {
        plain = 1;
    } else {
        winios_key(0x29, 0); /* Esc: wake the screen / close a stray box */
        sleep(1);
        hv_winvm_key_hid(0xe3, 1); usleep(40000);            /* Win+R */
        hv_winvm_key_hid(0x15, 1); usleep(50000);
        hv_winvm_key_hid(0x15, 0); usleep(30000);
        hv_winvm_key_hid(0xe3, 0);
        sleep(7);
    }
    const char *c = text.UTF8String;
    for (; *c; c++) {
        char ch = *c;
        if (ch >= 'a' && ch <= 'z') winios_key((uint8_t)(0x04 + ch - 'a'), 0);
        else if (ch >= 'A' && ch <= 'Z') winios_key((uint8_t)(0x04 + ch - 'A'), 1);
        else if (ch >= '1' && ch <= '9') winios_key((uint8_t)(0x1e + ch - '1'), 0);
        else if (ch == '0') winios_key(0x27, 0);
        else if (ch == ' ') winios_key(0x2c, 0);
        else if (ch == '-') winios_key(0x2d, 0);
        else if (ch == '_') winios_key(0x2d, 1);
        else if (ch == '.') winios_key(0x37, 0);
        else if (ch == '/') winios_key(0x38, 0);
        else if (ch == '|') winios_key(0x31, 1);
        else if (ch == '"') winios_key(0x34, 1);
        else if (ch == ':') winios_key(0x33, 1);
        else if (ch == ';') winios_key(0x33, 0);
        else if (ch == '=') winios_key(0x2e, 0);
    }
    sleep(1);
    if (plain) {
        winios_key(0x28, 0);
        return;
    }
    hv_winvm_key_hid(0xe0, 1); usleep(30000);            /* Ctrl+Shift+Enter: run elevated */
    hv_winvm_key_hid(0xe1, 1); usleep(30000);
    hv_winvm_key_hid(0x28, 1); usleep(60000);
    hv_winvm_key_hid(0x28, 0); usleep(30000);
    hv_winvm_key_hid(0xe1, 0); hv_winvm_key_hid(0xe0, 0);
    for (int i = 0; i < 6; i++) {                        /* Alt+Y: Yes on the UAC prompt, whenever it shows */
        sleep(7);
        hv_winvm_key_hid(0xe2, 1); usleep(40000);
        hv_winvm_key_hid(0x1c, 1); usleep(60000);
        hv_winvm_key_hid(0x1c, 0); usleep(30000);
        hv_winvm_key_hid(0xe2, 0);
    }
}

- (void)onDiagTickBackground {
    _diagTickCount++;
    if (_vmRunning) {
        /* Documents/serial.in (dropped in over USB): typed into the guest's serial console as is. */
        NSString *serialReq = [[self documentsPath] stringByAppendingPathComponent:@"serial.in"];
        NSData *serialData = [NSData dataWithContentsOfFile:serialReq];
        if (serialData.length) {
            unlink(serialReq.fileSystemRepresentation);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                hv_winvm_serial_send(serialData.bytes, serialData.length);
            });
        }
        NSString *typeReq = [[self documentsPath] stringByAppendingPathComponent:@"type.request"];
        NSString *text = [NSString stringWithContentsOfFile:typeReq encoding:NSUTF8StringEncoding error:nil];
        if (text.length) {
            unlink(typeReq.fileSystemRepresentation);
            text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ winios_type_run(text); });
        }
        /* Documents/pointer.request (testing over USB): lines "x y [buttons]", 0..1 across the screen,
           sent as tablet moves 16 ms apart, like a finger on the trackpad. */
        NSString *ptrReq = [[self documentsPath] stringByAppendingPathComponent:@"pointer.request"];
        NSString *ptr = [NSString stringWithContentsOfFile:ptrReq encoding:NSUTF8StringEncoding error:nil];
        if (ptr.length) {
            unlink(ptrReq.fileSystemRepresentation);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                for (NSString *line in [ptr componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                    NSArray<NSString *> *f = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                        componentsSeparatedByString:@" "];
                    if (f.count < 2) continue;
                    hv_winvm_tablet(f[0].doubleValue, f[1].doubleValue, f.count > 2 ? (uint8_t)f[2].intValue : 0, 0);
                    usleep(16000);
                }
            });
        }
    }
    [self writeDiagnosticsSnapshot];
    if (_vmRunning) dispatch_async(dispatch_get_main_queue(), ^{ [self refreshAppliedDisplay]; }); /* display hook */
    if (_vmRunning) {
        if ((_diagTickCount % 4u) == 0u) {
            hv_winvm_flush_disks();
        }
        double uptime = CFAbsoluteTimeGetCurrent() - _bootStartTime;
        NSString *docs = [self documentsPath];
        /* Documents/screenshot.request (dropped in over USB) asks for one fresh latest_screen.png. */
        NSString *req = [docs stringByAppendingPathComponent:@"screenshot.request"];
        BOOL requested = unlink(req.fileSystemRepresentation) == 0;
        if (uptime <= 240.0 || requested || getenv("WINIOS_ALWAYS_SCREENSHOT") != NULL) {
            NSString *tmpPng = [docs stringByAppendingPathComponent:@"latest_screen.png.tmp"];
            NSString *dstPng = [docs stringByAppendingPathComponent:@"latest_screen.png"];
            if (hv_winvm_save_png(tmpPng.fileSystemRepresentation) == 0) {
                rename(tmpPng.fileSystemRepresentation, dstPng.fileSystemRepresentation);
            }
        }
    }
    [self notifyChanged];
}

- (void)writeDiagnosticsSnapshot {
    NSString *docs = [self documentsPath];
    NSString *statusFile = [docs stringByAppendingPathComponent:@"boot_status.txt"];
    BOOL running = _vmRunning;
    double uptime = running ? (CFAbsoluteTimeGetCurrent() - _bootStartTime) : 0.0;
    uint32_t w = [self framebufferWidth], h = [self framebufferHeight];
    uint64_t frames = [self presentedFrames];

    int kbdReady = 0, tabReady = 0;
    uint64_t usbDelivered = 0;
    uint64_t jitUsedBytes = 0, jitCapBytes = 0, jitFullFlushes = 0, wfiTicks = 0;
    double wfiIdlePct = _lastWfiIdlePct;
    if (running) {
        hv_winvm_usb_stats(&kbdReady, &tabReady, &usbDelivered);
        hv_winvm_engine_stats(&jitUsedBytes, &jitCapBytes, &jitFullFlushes, &wfiTicks);
        uint64_t nowMach = mach_absolute_time();
        if (_lastMachTicks > 0 && nowMach > _lastMachTicks && wfiTicks >= _lastWfiTicks && _configuredCPUs > 0) {
            double pct = 100.0 * (double)(wfiTicks - _lastWfiTicks) /
                         ((double)(nowMach - _lastMachTicks) * (double)_configuredCPUs);
            if (pct < 0.0) pct = 0.0;
            if (pct > 100.0) pct = 100.0;
            wfiIdlePct = pct;
            _lastWfiIdlePct = pct;
        }
        _lastMachTicks = nowMach;
        _lastWfiTicks = wfiTicks;
    }

    os_unfair_lock_lock(&_metricsLock);
    CGSize pt = _screenSizePts;
    CGFloat scale = _screenScale;
    NSInteger hingeStatus = _hingeStatus;
    double hingeDeg = _hingeAngleDegrees;
    os_unfair_lock_unlock(&_metricsLock);

    char gpuLine[768] = "none";
    if (running && hv_winvm_gpu_status(gpuLine, sizeof gpuLine) < 0) snprintf(gpuLine, sizeof gpuLine, "none");

    NSString *txt = [NSString stringWithFormat:
        @"vm_running: %@\n"
        @"vm_status: %@\n"
        @"jit_live: %@\n"
        @"jit_status: %@\n"
        @"uptime_sec: %.1f\n"
        @"cpus: %d\n"
        @"ram_mb: %llu\n"
        @"avail_mem_mb: %llu\n"
        @"jit_used_mb: %.1f\n"
        @"jit_cap_mb: %.0f\n"
        @"jit_full_flushes: %llu\n"
        @"wfi_idle_pct: %.1f\n"
        @"fb_size: %ux%u\n"
        @"frames_presented: %llu\n"
        @"usb_kbd_ready: %d\n"
        @"usb_tab_ready: %d\n"
        @"usb_delivered: %llu\n"
        @"share_up: %d\n"
        @"oauth_safari: %d\n"
        @"hinge_status: %ld\n"
        @"hinge_angle_deg: %.1f\n"
        @"screen_pts: %.0fx%.0f @%.0fx\n"
        @"gpu: %s\n"
        @"gpu_hidpi: %d\n",
        running ? @"true" : @"false",
        _vmStatus ?: @"",
        self.isJITLive ? @"true" : @"false",
        self.jitStatusText ?: @"",
        uptime,
        _configuredCPUs,
        _configuredRamMB,
        [self availableMemoryMB],
        (double)jitUsedBytes / (1024.0 * 1024.0),
        (double)jitCapBytes / (1024.0 * 1024.0),
        jitFullFlushes,
        wfiIdlePct,
        w, h,
        frames,
        kbdReady,
        tabReady,
        usbDelivered,
        running ? hv_winvm_share_up() : 0,
        hv_share_url_handler_enabled(),
        (long)hingeStatus,
        hingeDeg,
        pt.width, pt.height, scale,
        gpuLine,
        (int)_hiDPIDisplay];
    { /* display sizing and the presenter (UX P0-1, P0-3): what was asked, what Windows took, what it costs */
        WinIOSDisplayPlan p = _committedPlan;
        WinIOSDisplayApplied a = _applied;
        HvFbMetalStats ps;
        hv_fb_metal_get_stats(&ps);
        txt = [txt stringByAppendingFormat:
            @"display_plan: %ux%u@%u looks=%ux%u picture=%ux%u k=%d preset=%ld available=%d legacy=%d native_scale=%.4f\n"
            @"display_reshape: state=%ld remodes=%lu last_ms=%.0f follows=%d immersive=%d keep=%d\n"
            @"display_applied: %ux%u@%u method=%d min=%u max=%u rec=%u age=%.0f\n"
            @"presenter: frames=%llu ticks=%llu held=%llu cpu_ms=%.0f upload_mb=%.0f link_hz=%d idle=%d nearest=%d src=%ux%u dst=%ux%u scale=%.2f\n",
            p.modeWidth, p.modeHeight, p.scalePercent, p.lookWidth, p.lookHeight, p.pictureWidth, p.pictureHeight,
            p.sharpness, (long)_displayPreset, p.available, p.legacy, _viewNativeScale,
            (long)_reshapeState, (unsigned long)_remodeCount, _lastReshapeMs, (int)_guestFollowsModes,
            (int)_displayImmersive, (int)_immersiveKeeps,
            a.modeWidth, a.modeHeight, a.scalePercent, a.method, a.minPercent, a.maxPercent, a.recommendedPercent, a.age,
            ps.frames, ps.ticks, ps.held, ps.cpu_ns / 1e6, ps.upload_bytes / 1048576.0, ps.link_hz, ps.idle, ps.nearest,
            ps.src_w, ps.src_h, ps.dst_w, ps.dst_h, ps.scale_x100 / 100.0];
    }
    [txt writeToFile:statusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)handleVMExitWithReason:(NSString *)reason {
    _vmRunning = NO;
    [self stopDiagTimer];
    [self endReshapeWatch:WinIOSReshapeStateIdle]; /* display hook */
    hv_fb_metal_hold_for_size(0, 0, 0);
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    _vmStatus = [NSString stringWithFormat:@"Stopped (%@)", reason];
    dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
    [self notifyChanged];
}

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel {
    if (!_vmRunning) return;
    [self trackTabletX:x y:y buttons:buttons]; /* display hook: reshape release, idle throttling */
    hv_winvm_tablet(x, y, buttons, wheel);
}

- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down {
    if (!_vmRunning) return;
    [self trackKey:usage down:down]; /* display hook */
    hv_winvm_key_hid(usage, down ? 1 : 0);
}

- (void)tapKeyHid:(uint8_t)usage {
    if (!_vmRunning) return;
    hv_fb_metal_note_input(); /* display hook: idle throttling */
    hv_winvm_key_hid(usage, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        hv_winvm_key_hid(usage, 0);
    });
}

- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage {
    if (!_vmRunning) return;
    hv_fb_metal_note_input(); /* display hook: idle throttling */
    for (NSNumber *m in modifiers) {
        hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 1);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (usage != 0) hv_winvm_key_hid(usage, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(38 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (usage != 0) hv_winvm_key_hid(usage, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                for (NSNumber *m in [modifiers reverseObjectEnumerator]) {
                    hv_winvm_key_hid((uint8_t)m.unsignedCharValue, 0);
                }
            });
        });
    });
}

- (void)sendWindowsKey {
    [self tapKeyHid:0xe3]; /* Left GUI / Windows key */
}

- (void)sendEscape {
    [self tapKeyHid:0x29]; /* Escape */
}

- (void)sendAltTab {
    [self sendKeyComboWithModifiers:@[@(0xe2)] key:0x2b];
}

- (void)sendCtrlAltDel {
    if (!_vmRunning) return;
    hv_winvm_send_ctrl_alt_del();
}

- (void)pressPowerButton {
    if (!_vmRunning) return;
    hv_winvm_power_button();
}

- (void)flushDisks {
    if (!_vmRunning) return;
    hv_winvm_flush_disks();
}

- (void)stopVM {
    if (!_vmRunning) return;
    hv_winvm_stop();
}

- (BOOL)useSafariForGuestLinks {
    return hv_share_url_handler_enabled() != 0;
}

- (void)setUseSafariForGuestLinks:(BOOL)useSafariForGuestLinks {
    hv_share_set_url_handler_enabled(useSafariForGuestLinks ? 1 : 0);
    [[NSUserDefaults standardUserDefaults] setBool:useSafariForGuestLinks forKey:@"winios.safariOAuthV2"];
}

/* ---- Keyboard, text and zoom ---- */

NSNotificationName const WinIOSFocusReportNotification = @"WinIOSFocusReportNotification";

/* A report of the WinKit focus agent (a connection thread of share.c): decoded and posted on the main thread. */
static void winios_focus_report(const char *json, size_t len, void *opaque) {
    (void)opaque;
    NSData *data = [NSData dataWithBytes:json length:len];
    dispatch_async(dispatch_get_main_queue(), ^{
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) return;
        [[NSNotificationCenter defaultCenter] postNotificationName:WinIOSFocusReportNotification
                                                            object:nil
                                                          userInfo:@{@"report": obj}];
    });
}

__attribute__((constructor)) static void winios_focus_register(void) {
    hv_share_set_focus_handler(winios_focus_report, NULL);
}

- (void)setViewZoom:(double)zoom translateX:(double)tx y:(double)ty {
    hv_fb_metal_set_view_transform((float)zoom, (float)tx, (float)ty);
}

- (BOOL)sendUnicodeText:(NSString *)text {
    if (!_vmRunning || !text.length) return NO;
    return hv_share_focus_send_text(text.UTF8String) == 0;
}

- (NSInteger)focusAgentSeenSeconds {
    return hv_share_focus_agent_seen();
}

- (BOOL)unicodeTextBusy {
    return hv_share_focus_text_busy() != 0;
}

- (void)makeScreenThumbnailMaxPixels:(NSInteger)maxPixels completion:(void (^)(CGImageRef _Nullable))completion {
    static _Atomic int running;
    int idle = 0;
    if (!_vmRunning || !atomic_compare_exchange_strong(&running, &idle, 1)) {
        completion(NULL);
        return;
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"minimap.png"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        CGImageRef thumb = NULL;
        if (hv_winvm_save_png(path.fileSystemRepresentation) == 0) {
            CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
            if (src) {
                NSDictionary *opts = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                       (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(16, maxPixels)),
                                       (id)kCGImageSourceShouldCacheImmediately: @YES};
                thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
                CFRelease(src);
            }
            unlink(path.fileSystemRepresentation);
        }
        atomic_store(&running, 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(thumb);
            if (thumb) CGImageRelease(thumb);
        });
    });
}

- (nullable NSString *)takeGuestOpenURL {
    char *raw = hv_share_take_open_url();
    if (!raw) return nil;
    NSString *s = [NSString stringWithUTF8String:raw];
    free(raw);
    return s;
}

- (BOOL)takeGuestOAuthDone {
    return hv_share_take_oauth_done() != 0;
}

@end

/* ---- port forwards (portfwd) ---- */

#include "net_slirp.h"

@interface WinIOSBridge (PortForwardingMachine) /* implemented in the class itself, above */
- (NSString *)machineDirectory;
@end

@implementation WinIOSBridge (PortForwarding)

- (void)usePortForwardsOfMachineDirectory:(NSString *)dir {
    NSString *path = [dir stringByAppendingPathComponent:@"port_forwards.json"];
    hv_net_fwd_set_store(path.fileSystemRepresentation); /* the same path again does nothing */
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* iOS may take a suspended app's listening sockets away: open the forwards again on the way back. */
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
                                                          (void)note;
                                                          hv_net_fwd_reopen();
                                                      }];
    });
}

/* While no machine runs, the forwards shown are the selected machine's (it may have changed on the launch page). */
- (void)usePortForwardsOfCurrentMachine {
    if (!self.isVMRunning) [self usePortForwardsOfMachineDirectory:[self machineDirectory]];
}

static NSString *winios_take_json(char *s, NSString *fallback) {
    if (!s) return fallback;
    NSString *r = [NSString stringWithUTF8String:s] ?: fallback;
    free(s);
    return r;
}

- (NSString *)portForwardsJSON {
    [self usePortForwardsOfCurrentMachine];
    return winios_take_json(hv_net_fwd_list_json(), @"{\"running\":false,\"rules\":[]}");
}

- (nullable NSString *)savePortForwardWithID:(NSString *)forwardID
                                        name:(NSString *)name
                                   protocols:(NSInteger)protocols
                                    hostPort:(NSInteger)hostPort
                                   guestPort:(NSInteger)guestPort
                                       scope:(NSInteger)scope
                                     enabled:(BOOL)enabled {
    [self usePortForwardsOfCurrentMachine];
    HvFwdRule r = {0};
    snprintf(r.id, sizeof r.id, "%s", forwardID.UTF8String ?: "");
    snprintf(r.name, sizeof r.name, "%s", name.UTF8String ?: "");
    r.proto = (int)protocols;
    r.host_port = (int)MAX(MIN(hostPort, 70000), -1);
    r.guest_port = (int)MAX(MIN(guestPort, 70000), -1);
    r.scope = (int)scope;
    r.enabled = enabled ? 1 : 0;
    char err[160] = {0};
    if (hv_net_fwd_put(&r, HV_FWD_SAVED, err, sizeof err) != 0) return [NSString stringWithUTF8String:err] ?: @"failed";
    NSLog(@"portfwd: saved \"%s\" %s %d -> %d scope %d %s", r.name, r.proto == 3 ? "tcp+udp" : r.proto == 2 ? "udp" : "tcp",
          r.host_port, r.guest_port, r.scope, r.enabled ? "on" : "off");
    return nil;
}

- (BOOL)removePortForwardWithID:(NSString *)forwardID {
    [self usePortForwardsOfCurrentMachine];
    return hv_net_fwd_remove(forwardID.UTF8String ?: "", 0) == 0;
}

- (NSString *)portForwardAddressesJSON {
    return winios_take_json(hv_net_fwd_addresses_json(), @"{\"lan\":[],\"vpn\":[]}");
}

- (void)refreshPortForwards {
    hv_net_fwd_refresh();
}

@end
