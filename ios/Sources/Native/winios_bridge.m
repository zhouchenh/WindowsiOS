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
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <sys/stat.h>

static WinIOSBridge *s_shared_bridge = nil;

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
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _diagQueue = dispatch_queue_create("me.ammaar.windowsios.diag", attr);
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        /* iOS refuses GPU work from the background while this app keeps running there (audio):
           everything Windows drew meanwhile was lost (missing tray, Start menu, text). So the guest
           CPUs stop as the app leaves the front and go on when it is back. */
        [nc addObserver:self selector:@selector(onAppInactive:) name:UIApplicationWillResignActiveNotification object:nil];
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

- (void)onAppInactive:(NSNotification *)note {
    (void)note;
    if (_vmRunning && !getenv("WINIOS_RUN_IN_BACKGROUND")) {
        hv_winvm_set_paused(1);
        fprintf(stderr, "winvm: paused (app not in front)\n");
    }
}

- (void)onAppActive:(NSNotification *)note {
    (void)note;
    if (_vmRunning) {
        hv_winvm_set_paused(0);
        fprintf(stderr, "winvm: resumed\n");
    }
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

/* Points -> a mode virtio-gpu accepts: at least 960x600 (scaled up, aspect kept), even sizes. */
static void winios_gpu_mode_for(CGSize pts, uint32_t *w, uint32_t *h) {
    double fw = pts.width, fh = pts.height;
    if (fw < 1 || fh < 1) { *w = *h = 0; return; }
    /* A phone's view is only ~400 points wide: Windows needs about 960x600 to be usable. */
    double up = fmax(960.0 / fw, 600.0 / fh);
    if (up > 1.0) { fw *= up; fh *= up; }
    *w = ((uint32_t)fw) & ~1u;
    *h = ((uint32_t)fh) & ~1u;
}

/* The size the guest should use, where the guest-side setup script reads it (http://10.0.2.4/res.txt). */
- (void)publishWantedResolution:(uint32_t)w height:(uint32_t)h {
    if (!w || !h) return;
    NSString *dir = [[self documentsPath] stringByAppendingPathComponent:@"Shared"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSString stringWithFormat:@"%ux%u", w, h] writeToFile:[dir stringByAppendingPathComponent:@"res.txt"]
                                                 atomically:YES encoding:NSASCIIStringEncoding error:nil];
}

- (BOOL)hiDPIDisplay {
    return _hiDPIDisplay;
}

- (void)setHiDPIDisplay:(BOOL)on {
    _hiDPIDisplay = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"winios.hiDPIDisplay"];
    os_unfair_lock_lock(&_metricsLock);
    CGSize pts = _displayViewPts;
    os_unfair_lock_unlock(&_metricsLock);
    if (pts.width > 0) [self updateDisplayViewSize:pts];
}

- (void)updateDisplayViewSize:(CGSize)size {
    uint32_t w = 0, h = 0;
    os_unfair_lock_lock(&_metricsLock);
    _displayViewPts = size;
    CGFloat scale = _screenScale > 0 ? _screenScale : 2.0;
    os_unfair_lock_unlock(&_metricsLock);
    CGSize px = _hiDPIDisplay ? CGSizeMake(size.width * scale, size.height * scale) : size;
    winios_gpu_mode_for(px, &w, &h);
    if (!w || !h) return;
    os_unfair_lock_lock(&_metricsLock);
    BOOL changed = (w != _gpuPrefW || h != _gpuPrefH);
    _gpuPrefW = w;
    _gpuPrefH = h;
    os_unfair_lock_unlock(&_metricsLock);
    if (!changed || !_vmRunning) return;
    /* Layout passes (bars appearing, rotation animations) change the view size for a moment:
       tell the guest only once a size has held for 1.5 s, or Windows keeps re-moding. */
    uint64_t token = ++_gpuPrefToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_gpuPrefToken || !self->_vmRunning) return;
        os_unfair_lock_lock(&self->_metricsLock);
        uint32_t fw = self->_gpuPrefW, fh = self->_gpuPrefH;
        os_unfair_lock_unlock(&self->_metricsLock);
        hv_winvm_set_preferred_display(fw, fh);
        [self publishWantedResolution:fw height:fh];
    });
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

- (uint32_t)framebufferWidth {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return w;
    return 0;
}

- (uint32_t)framebufferHeight {
    uint32_t w = 0, h = 0;
    if (_vmRunning && hv_winvm_display_size(&w, &h) == 0) return h;
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

/* Its marketing name. iOS has no public way to ask, so: the identifiers of recent devices, else
   "iPad (iPad99,9)". */
static NSString *winios_model_name(NSString *ident) {
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @"iPhone15,4": @"iPhone 15", @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone16,1": @"iPhone 15 Pro", @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
            @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus", @"iPhone17,5": @"iPhone 16e",
            @"iPhone18,1": @"iPhone 17 Pro", @"iPhone18,2": @"iPhone 17 Pro Max",
            @"iPhone19,2": @"iPhone 18 Pro",
            @"iPad13,4": @"iPad Pro 11-inch (M1)", @"iPad13,5": @"iPad Pro 11-inch (M1)",
            @"iPad13,6": @"iPad Pro 11-inch (M1)", @"iPad13,7": @"iPad Pro 11-inch (M1)",
            @"iPad13,8": @"iPad Pro 12.9-inch (M1)", @"iPad13,9": @"iPad Pro 12.9-inch (M1)",
            @"iPad13,10": @"iPad Pro 12.9-inch (M1)", @"iPad13,11": @"iPad Pro 12.9-inch (M1)",
            @"iPad13,16": @"iPad Air (M1)", @"iPad13,17": @"iPad Air (M1)",
            @"iPad14,3": @"iPad Pro 11-inch (M2)", @"iPad14,4": @"iPad Pro 11-inch (M2)",
            @"iPad14,5": @"iPad Pro 12.9-inch (M2)", @"iPad14,6": @"iPad Pro 12.9-inch (M2)",
            @"iPad14,8": @"iPad Air 11-inch (M2)", @"iPad14,9": @"iPad Air 11-inch (M2)",
            @"iPad14,10": @"iPad Air 13-inch (M2)", @"iPad14,11": @"iPad Air 13-inch (M2)",
            @"iPad16,3": @"iPad Pro 11-inch (M4)", @"iPad16,4": @"iPad Pro 11-inch (M4)",
            @"iPad16,5": @"iPad Pro 13-inch (M4)", @"iPad16,6": @"iPad Pro 13-inch (M4)",
            @"iPad17,1": @"iPad Pro 11-inch (M5)", @"iPad17,2": @"iPad Pro 11-inch (M5)",
            @"iPad17,3": @"iPad Pro 13-inch (M5)", @"iPad17,4": @"iPad Pro 13-inch (M5)",
        };
    });
    NSString *n = names[ident];
    if (n) return n;
    NSString *kind = [ident hasPrefix:@"iPad"] ? @"iPad" : [ident hasPrefix:@"iPhone"] ? @"iPhone" : @"Apple device";
    return [NSString stringWithFormat:@"%@ (%@)", kind, ident];
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

    char err[256] = {0};
    if (hv_winvm_create(&cfg, err, sizeof err) != 0) {
        _vmStatus = [NSString stringWithFormat:@"VM create failed: %s", err];
        dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
        [self notifyChanged];
        return;
    }

    os_unfair_lock_lock(&_metricsLock);
    uint32_t gpuW = _gpuPrefW, gpuH = _gpuPrefH;
    os_unfair_lock_unlock(&_metricsLock);
    if (gpuW && gpuH) hv_winvm_set_preferred_display(gpuW, gpuH); /* before the driver starts: no event needed */
    [self publishWantedResolution:gpuW height:gpuH];

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
    [txt writeToFile:statusFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)handleVMExitWithReason:(NSString *)reason {
    _vmRunning = NO;
    [self stopDiagTimer];
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    _vmStatus = [NSString stringWithFormat:@"Stopped (%@)", reason];
    dispatch_async(_diagQueue, ^{ [self writeDiagnosticsSnapshot]; });
    [self notifyChanged];
}

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel {
    if (!_vmRunning) return;
    hv_winvm_tablet(x, y, buttons, wheel);
}

- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, down ? 1 : 0);
}

- (void)tapKeyHid:(uint8_t)usage {
    if (!_vmRunning) return;
    hv_winvm_key_hid(usage, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        hv_winvm_key_hid(usage, 0);
    });
}

- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage {
    if (!_vmRunning) return;
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
