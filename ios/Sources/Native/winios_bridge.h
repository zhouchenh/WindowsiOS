/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WinIOSStateCallback)(void);

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
/// virtio-gpu preferred mode in native pixels (sharp, more CPU) instead of points. Persisted.
@property (nonatomic) BOOL hiDPIDisplay;
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

/// Posted on the main thread for each report of the WinKit focus agent; userInfo[@"report"] is the
/// decoded JSON object (see winkit/FocusAgent.cs).
extern NSNotificationName const WinIOSFocusReportNotification;

NS_ASSUME_NONNULL_END
