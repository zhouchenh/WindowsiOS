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

/// One finger on the Windows touch screen (the xHCI's port 3): x, y in 0..1 across the Windows screen.
/// contactId stays the same while the finger is down (0..15). A finger lifting is sent once more with tip 0;
/// confidence 0 with it cancels the touch (Windows does not take it as a tap or the end of a gesture).
typedef struct WinIOSTouchContact {
    uint8_t contactId;
    uint8_t tip;
    uint8_t confidence;
    double x, y;
} WinIOSTouchContact;

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
/// Windows reads the touch screen (its HID touch driver runs): multi-touch can go to it. Cheap to read.
@property (nonatomic, readonly) BOOL usbTouchReady;
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
/// The app moved to another screen (inner, laptop lid, cover). Immersive keeping the resolution keeps the
/// mode it has on one screen; on the next screen the canvas is a new size, which Windows then takes once.
- (void)displaySurfaceDidChange;
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
/// One touch screen frame: every finger on the screen, plus those lifting (tip 0), at most 10. Main thread.
/// A lift for a finger Windows does not have down (already lifted) is left out.
- (void)sendTouchContacts:(const WinIOSTouchContact *)contacts count:(NSInteger)count;
/// Every finger still down in Windows is cancelled (tip 0, confidence 0). Also done by the bridge itself on
/// a reshape (releaseAllInputForReshape) and when the app goes to the background. Main thread.
- (void)cancelAllTouchContacts;
- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down;
/* Key-ups sent only after every key tap already queued is up again (see winios_bridge.m). */
- (void)releaseKeysAfterQueuedTaps:(NSArray<NSNumber *> *)usages;
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
/// ipv6Global: a local network or VPN forward also listens on the interface's global IPv6 addresses (which the
/// internet may reach unless the router or the VPN server filters it); unique local ones are always taken. Ignored
/// for this device only.
- (nullable NSString *)savePortForwardWithID:(NSString *)forwardID
                                        name:(NSString *)name
                                   protocols:(NSInteger)protocols
                                    hostPort:(NSInteger)hostPort
                                   guestPort:(NSInteger)guestPort
                                       scope:(NSInteger)scope
                                     enabled:(BOOL)enabled
                                  ipv6Global:(BOOL)ipv6Global
    NS_SWIFT_NAME(savePortForward(id:name:protocols:hostPort:guestPort:scope:enabled:ipv6Global:));
- (BOOL)removePortForwardWithID:(NSString *)forwardID NS_SWIFT_NAME(removePortForward(id:));
/// The device's addresses others can connect to (LAN and VPN), as JSON (hv_net_fwd_addresses_json).
- (NSString *)portForwardAddressesJSON NS_SWIFT_NAME(portForwardAddressesJSON());
/// The network changed: look the VPN's address up again and retry forwards that failed.
- (void)refreshPortForwards;
/// Which machine's saved forwards are in use (the running one's, else the selected one's).
- (void)usePortForwardsOfMachineDirectory:(NSString *)dir;
@end

/* ---- Server mode (ios/Sources/ServerMode.swift, docs/networking.md "Server mode") ----
   Windows keeps running while the app is in the background: an audio output unit kept running (silence) keeps
   iOS from suspending the app, which only works with no host 3D in use (iOS refuses GPU work from the background)
   and no debugger attached. Main thread. */

/// Why Windows cannot run in the background now.
typedef NS_ENUM(NSInteger, WinIOSBackgroundBlocker) {
    WinIOSBackgroundBlockerNothing = 0,
    WinIOSBackgroundBlockerNotRunning = 1,
    WinIOSBackgroundBlockerHost3D = 2,           /* the display driver runs 3D, or 3D is offered for its next start */
    WinIOSBackgroundBlockerSwitchPending = 3, /* 2D is offered, the 3D driver still runs (the switch is not done) */
    WinIOSBackgroundBlockerDebugger = 4,     /* a debugger is attached: every trap would stop the app */
};

/// The graphics mode (virtio-gpu, devices/virtio_gpu.h): whether 3D can be offered at all (the renderer was loaded
/// when Windows started), what the next driver start is offered, and what the running driver took.
typedef struct WinIOSGraphicsMode {
    bool capable, offered3D, negotiated3D, driverOK; /* bool, not BOOL: Swift sees Bool */
    uint32_t resets; /* driver resets since start: a restarted display adapter moves it on */
} WinIOSGraphicsMode;

@interface WinIOSBridge (ServerMode)
/// Keep Windows running in the background (only while backgroundBlocker is None). Saved by the Swift side.
@property (nonatomic) BOOL runInBackground;
/// The output unit keeps running with silence (hv_audio_set_keepalive), from now and at every start, except
/// while the guest is paused (the app may then be suspended as before).
@property (nonatomic) BOOL audioKeepAlive;
@property (nonatomic, readonly) BOOL backgroundCapable;
@property (nonatomic, readonly) WinIOSBackgroundBlocker backgroundBlocker;
/// No picture: the Metal layer is unbound (the presenter stops) and Windows' size is frozen as it is.
@property (nonatomic) BOOL headless;
/// The screen stays on while Windows runs (iOS auto-lock off). YES by default. Whatever this says, it also stays on
/// while Windows runs and could not keep running in the background (no server mode, host 3D, a switch pending, a
/// debugger, Linux).
@property (nonatomic) BOOL keepScreenOn;
/// Evaluates the screen's auto-lock again (after the background blocker changed).
- (void)updateIdleTimer;
/// The guest's CPUs are stopped now (the background pause or the guard).
@property (nonatomic, readonly) BOOL machinePaused;
/// Paused by the app's guard (critical temperature or battery), apart from the background pause.
@property (nonatomic, readonly) BOOL guardPaused;
- (void)setGuardPaused:(BOOL)paused reason:(NSString *)reason;
/// The app is in the background with Windows running (server mode doing its job).
@property (nonatomic, readonly) BOOL runningInBackground;
/// Whether the output unit runs now (diagnostics).
@property (nonatomic, readonly) BOOL audioOutputRunning;

- (WinIOSGraphicsMode)graphicsMode;
/// Offers 3D or 2D from the display driver's next start and, with restartAdapter, asks WinKit's graphics task in
/// Windows to restart its display adapter now (Shared/gpu_mode.txt). Returns the request's number (> 0), 0 when
/// only the offer changed, -1 when refused (why in *why, in the user's language). Refused in the background
/// (leaving 3D needs the GPU) and for Linux.
- (int64_t)requestGraphics3D:(BOOL)on restartAdapter:(BOOL)restart why:(NSString *_Nullable *_Nullable)why;
/// Asks Windows to restart (the WinKit helper's job): with 2D offered, it comes back without 3D. NO when no helper.
- (BOOL)requestWindowsRestart;
/// What WinKit's graphics task last reported (Shared/gpu_mode_applied.txt: key=value lines), nil if nothing.
- (nullable NSString *)graphicsSwitchReport;

/* ---- Auto-2D when leaving the app (ServerMode.swift: "Switch to 2D when leaving the app") ----
   When the app goes to the background (didEnterBackground, never on merely becoming inactive: the Face ID and passkey
   sheets do that) and Windows was started with host 3D: Windows is not paused; the presenter stops; the 3D device
   answers fences itself after a grace period (background drain, virtio_gpu3d.h), since iOS refuses the GPU work that
   would signal them; 2D is offered and WinKit's graphics task asked to restart the display adapter; the silent audio
   output keeps the app running. A switch that has not finished after 60 s of Windows running pauses Windows until
   the app is back (the 3D driver cannot draw in the background). Back in front (didBecomeActive): drain off, the
   presenter on. Not for Linux, nor with a debugger attached. */

/// Saved by the Swift side. Also keeps a Windows already on 2D running in the background without server mode.
@property (nonatomic) BOOL autoSwitch2D;
/// The request number of the switch auto-2D started on the last trip to the background (0: none yet).
@property (nonatomic, readonly) int64_t autoSwitchSeq;
/// The app is in the background with an auto-2D switch under way or done (drain on).
@property (nonatomic, readonly) BOOL autoSwitchAway;
/// Auto-2D would switch if the app left now (Windows started with 3D, 3D in use, not Linux, no debugger, and WinKit's
/// graphics task seen: graphicsTaskPresent). Otherwise Windows on 3D is paused in the background as before.
@property (nonatomic, readonly) BOOL autoSwitchPossible;
/// Evidence of WinKit's graphics task: Shared/gpu_mode_applied.txt exists, or the WinKit helper reported within 40 s.
@property (nonatomic, readonly) BOOL graphicsTaskPresent;
/// The last return to the app found that Windows never answered auto-2D's request: the 3D offer was put back.
@property (nonatomic, readonly) BOOL autoSwitchRestored3D;
/// The virtio-gpu status line (hv_winvm_gpu_status: the 3D renderer's counters and drain), nil when not running.
- (nullable NSString *)gpuStatusLine;

/* ---- Picture in Picture (winios_pip.m) and the audio session ---- */
/// PiP is armed (the layer is in the window and may start by itself when the app leaves).
@property (nonatomic) BOOL pipArmed;
/// A test of what automatic PiP needs (Settings > Display > Background test): the audio session while PiP is armed.
/// 0 the app's own (PlayAndRecord, mixes with other apps, the default), 1 Playback that mixes, 2 Playback alone
/// (stops other apps' audio). Both Playback modes have no input: Windows' microphone is off (capture stopped) while
/// one is in use, and starts again with PlayAndRecord. Never saved: back to 0 at every launch.
@property (nonatomic) NSInteger pipAudioCategory;
/// The audio session's category now, for the logs ("PlayAndRecord+mix" and so on).
@property (nonatomic, readonly) NSString *audioCategoryName;
@end

/// Posted on the main thread for each report of the WinKit focus agent; userInfo[@"report"] is the
/// decoded JSON object (see winkit/FocusAgent.cs).
extern NSNotificationName const WinIOSFocusReportNotification;

/* The clipboard shared with Windows (host/share.c, docs/clipboard.md). */
extern NSNotificationName const WinIOSGuestClipboardDidChangeNotification; /* posted on the main queue */

@interface WinIOSBridge (Clipboard)
/// Starts posting WinIOSGuestClipboardDidChangeNotification when Windows copies text. Safe to call again.
- (void)startClipboardObserver;
/// What Windows last copied, once; nil when nothing is new.
- (nullable NSString *)takeGuestClipboard;
/// Text for Windows' clipboard: its sequence number, or 0 when it is not taken: empty or over 1 MB, or
/// (unless force) the text the shared clipboard holds already, which is how text from Windows stops going round.
- (NSUInteger)sendClipboardToGuest:(NSString *)text force:(BOOL)force;
/// Seconds since the clipboard helper in Windows was last heard from: 0 while it waits for news, -1 never.
- (NSInteger)clipboardAgentSeenSeconds;
/// The newest sequence number the helper has put on Windows' clipboard (see hv_share_clipboard_agent_has).
- (NSUInteger)clipboardAgentHasSeq;
/// Ctrl+V through the virtual keyboard.
- (void)sendPasteShortcut;
@end

NS_ASSUME_NONNULL_END
