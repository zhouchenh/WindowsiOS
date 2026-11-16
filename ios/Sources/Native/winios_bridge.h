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

NS_ASSUME_NONNULL_END
