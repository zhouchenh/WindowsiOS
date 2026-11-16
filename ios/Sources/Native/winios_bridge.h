/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WinIOSStateCallback)(void);

/* ---- Display sizing (DisplaySettings.swift is the UI side) ---- */

/// What Windows is asked for in one view: the guest mode in pixels, the Windows scale, and the effective
/// workspace Windows then has (mode / scale), the "Looks like W x H" readout.
typedef struct WinIOSDisplayPlan {
    uint32_t pictureWidth, pictureHeight; /* the view in native panel pixels (even) */
    uint32_t modeWidth, modeHeight;       /* the guest mode */
    uint32_t scalePercent;                /* the Windows scale asked for */
    uint32_t lookWidth, lookHeight;       /* modeWidth / (scalePercent / 100), the workspace in DIPs */
    int32_t sharpness;                    /* 1 Sharp (1:1 pixels), 2 Balanced (half, shown at exactly 2x) */
    int32_t available;                    /* the preset keeps the workspace above its floor at this sharpness */
    int32_t legacy;                       /* HV_DISPLAY_LEGACY sizing (points, at least 960x600, no scale) */
} WinIOSDisplayPlan;

/// What the WinKit helper reported it applied (Documents/Shared/res_applied.txt).
typedef struct WinIOSDisplayApplied {
    uint32_t modeWidth, modeHeight;
    uint32_t scalePercent;  /* what Windows accepted (0: unknown) */
    uint32_t minPercent, maxPercent, recommendedPercent;
    int32_t method;         /* 0 none yet, 1 live (per-monitor DPI), 2 after sign-out (registry), 3 failed */
    double age;             /* seconds since the report */
} WinIOSDisplayApplied;

/// Reshape progress: 0 idle, 1 waiting for Windows (< 3 s), 2 slow ("Windows is taking the new size"),
/// 3 stuck (> 10 s: the display driver or the helper is probably missing).
typedef NS_ENUM(NSInteger, WinIOSReshapeState) {
    WinIOSReshapeStateIdle = 0,
    WinIOSReshapeStateWaiting = 1,
    WinIOSReshapeStateSlow = 2,
    WinIOSReshapeStateStuck = 3,
};

/// Presenter counters (frames, display-link rate, presenter CPU), for Settings > Status.
typedef struct WinIOSPresenterStats {
    uint64_t frames, ticks, held, cpuNanos, uploadBytes;
    int32_t linkHz, idle, nearest, holding;
    uint32_t srcWidth, srcHeight, dstWidth, dstHeight, scaleX100;
} WinIOSPresenterStats;

/// Posted (main thread) when the display plan, the reshape state or the helper's report changes.
extern NSNotificationName const WinIOSDisplayStateDidChangeNotification;
/// Posted (main thread) when the view takes a new shape that will re-mode Windows: in-flight touches
/// should be cancelled (the bridge itself releases buttons and keys it has sent down).
extern NSNotificationName const WinIOSDisplayWillReshapeNotification;

@interface WinIOSBridge : NSObject

@property (class, nonatomic, readonly) WinIOSBridge *shared;

@property (nonatomic, readonly) BOOL isJITLive;
@property (nonatomic, readonly) BOOL isDebuggerAttached;
@property (nonatomic, readonly) BOOL isVMRunning;
@property (nonatomic, readonly) BOOL isUnpacking;
@property (nonatomic, readonly) double unpackProgress;
@property (nonatomic, readonly) NSString *jitStatusText;
@property (nonatomic, readonly) NSString *vmStatusText;
@property (nonatomic, readonly) uint32_t framebufferWidth;
@property (nonatomic, readonly) uint32_t framebufferHeight;
@property (nonatomic, readonly) uint64_t presentedFrames;
@property (nonatomic, readonly) uint64_t availableMemoryMB;
@property (nonatomic, readonly) BOOL usbKeyboardReady;
@property (nonatomic, readonly) BOOL usbTabletReady;
@property (nonatomic, readonly) uint64_t usbEventsDelivered;
@property (nonatomic, assign) BOOL useSafariForGuestLinks;
@property (nonatomic, copy, nullable) WinIOSStateCallback onStateChanged;

- (nullable NSString *)takeGuestOpenURL;
- (BOOL)takeGuestOAuthDone;

- (void)installTrapGuard;
- (BOOL)tryAcquireJIT:(BOOL)detachAfter;

- (BOOL)hasProvisionedMachine;
- (BOOL)needsSparseUnpack;
- (void)prepareAndStartWithLayer:(nullable CAMetalLayer *)layer;
- (void)bindMetalLayer:(nullable CAMetalLayer *)layer;

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale;
/// Size (points) of the view Windows is drawn in; becomes the virtio-gpu preferred mode.
- (void)updateDisplayViewSize:(CGSize)size;
/// The same, with the screen's nativeScale (panel pixels per point) the view is on.
- (void)updateDisplayViewSize:(CGSize)size nativeScale:(CGFloat)nativeScale;
/// Former switch: on is Sharp, off Balanced (see displaySharpness). Persisted.
@property (nonatomic) BOOL hiDPIDisplay;

/// Display Size: 0 Larger Text, 1 Default, 2 More Space.
@property (nonatomic) NSInteger displaySizePreset;
/// Sharpness: 0 automatic (Sharp up to 2.6 MP, Balanced above), 1 Sharp, 2 Balanced.
@property (nonatomic) NSInteger displaySharpness;
/// Immersive (full panel) is shown; with immersiveKeepsResolution Windows keeps its mode meanwhile
/// (no re-mode, the picture is shown 1:1 or scaled), otherwise it re-modes to the full panel.
@property (nonatomic) BOOL displayImmersive;
@property (nonatomic) BOOL immersiveKeepsResolution;
/// HV_DISPLAY_LEGACY=1 (Documents/env.txt): the former sizing, drawable at UIScreen.scale.
@property (nonatomic, readonly) BOOL displayLegacy;
/// The plan for the current view with another preset / sharpness (for the pickers' readouts).
- (WinIOSDisplayPlan)displayPlanForPreset:(NSInteger)preset sharpness:(NSInteger)sharpness;
/// The plan last sent to Windows (or that will be, once the size settles).
@property (nonatomic, readonly) WinIOSDisplayPlan currentDisplayPlan;
@property (nonatomic, readonly) WinIOSDisplayApplied appliedDisplay;
@property (nonatomic, readonly) WinIOSReshapeState displayReshapeState;
/// Re-modes asked of Windows since start, and the last one's time to its first frame (ms, 0 unknown).
@property (nonatomic, readonly) NSUInteger displayRemodeCount;
@property (nonatomic, readonly) double lastReshapeMillis;
- (WinIOSPresenterStats)presenterStats;
/// Lift every mouse button and key the app has sent down (also done by itself on a reshape).
- (void)releaseAllInputForReshape;
/// A touch began (before anything is sent to Windows): the display goes back to its full frame rate now.
/// Pointer and key events sent through this bridge already count.
- (void)noteUserInput;
/// Re-read the helper's report now (it is also read every few seconds).
- (void)refreshAppliedDisplay;
- (void)updateHingeStatus:(NSInteger)status angleDegrees:(double)angleDegrees;

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel;
- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down;
- (void)tapKeyHid:(uint8_t)usage;
- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage;
- (void)sendWindowsKey;
- (void)sendCtrlAltDel;
- (void)sendAltTab;
- (void)sendEscape;
- (void)pressPowerButton;
- (void)flushDisks;
- (void)stopVM;
/* Refresh rate of the machine's screen (global, any time). */
- (void)setDisplayFrameRate:(NSInteger)fps;
/* A new Arch Linux machine that installs itself (see winios_bridge.m); nil when ready, else why not. */
- (nullable NSString *)prepareArchInstallWithSizeGB:(NSUInteger)sizeGB;
- (nullable NSString *)archInstallStatus;
- (BOOL)archInstallPending;

/* ---- Keyboard, text and zoom ---- */
/// Pan/zoom of the shown picture: zoom (>= 1) about the view's centre, then moved by (tx, ty) as fractions
/// of the view's width and height (y down). 1, 0, 0 shows it as fitted.
- (void)setViewZoom:(double)zoom translateX:(double)tx y:(double)ty;
/// Text a USB keyboard cannot type (Chinese, accents, emoji), typed in Windows by the WinKit focus agent
/// (\b is Backspace, \n Enter). NO when no agent is listening.
- (BOOL)sendUnicodeText:(NSString *)text;
/// Seconds since the WinKit focus agent was last heard from, -1 if never.
@property (nonatomic, readonly) NSInteger focusAgentSeenSeconds;
/// Text sent through the focus agent may still be on its way: keys sent by USB now could overtake it.
@property (nonatomic, readonly) BOOL unicodeTextBusy;
/// A small picture of the whole Windows screen (the mini-map), made off the main thread; the completion
/// runs on the main thread, with nil when there is none. One at a time: a call while one runs gets nil.
- (void)makeScreenThumbnailMaxPixels:(NSInteger)maxPixels completion:(void (^)(CGImageRef _Nullable image))completion;

@end

/* Port forwards (host/net_slirp.h, ios/Sources/PortForwardingView.swift): saved per machine in
   <machine folder>/port_forwards.json and opened when the machine's network starts. All callable any time, from any
   thread; the network thread applies changes. */
@interface WinIOSBridge (PortForwarding)
/// The forwards with their live state, as JSON (hv_net_fwd_list_json).
- (NSString *)portForwardsJSON NS_SWIFT_NAME(portForwardsJSON());
/// Adds a saved forward, or replaces the one with this id. nil when done, else why not (in English).
/// protocols: 1 TCP, 2 UDP, 3 both. scope: 0 this device only, 1 local network, 2 VPN.
- (nullable NSString *)savePortForwardWithID:(NSString *)forwardID
                                        name:(NSString *)name
                                   protocols:(NSInteger)protocols
                                    hostPort:(NSInteger)hostPort
                                   guestPort:(NSInteger)guestPort
                                       scope:(NSInteger)scope
                                     enabled:(BOOL)enabled
    NS_SWIFT_NAME(savePortForward(id:name:protocols:hostPort:guestPort:scope:enabled:));
- (BOOL)removePortForwardWithID:(NSString *)forwardID NS_SWIFT_NAME(removePortForward(id:));
/// The device's addresses others can connect to (LAN and VPN), as JSON (hv_net_fwd_addresses_json).
- (NSString *)portForwardAddressesJSON NS_SWIFT_NAME(portForwardAddressesJSON());
/// The network changed: look the VPN's address up again and retry forwards that failed.
- (void)refreshPortForwards;
/// Which machine's saved forwards are in use (the running one's, else the selected one's).
- (void)usePortForwardsOfMachineDirectory:(NSString *)dir;
@end

/// Posted on the main thread for each report of the WinKit focus agent; userInfo[@"report"] is the
/// decoded JSON object (see winkit/FocusAgent.cs).
extern NSNotificationName const WinIOSFocusReportNotification;

NS_ASSUME_NONNULL_END
