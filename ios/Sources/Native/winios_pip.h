/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/* Windows in Picture in Picture (Settings: "Show Windows in Picture in Picture", ServerMode.swift).

   An AVSampleBufferDisplayLayer lies over the Windows view, hidden while the app is in front and while it is only
   inactive (the Metal presenter's zoom, pan and placement are not the layer's whole-screen fit). PiP gives the app no
   GPU time: in the background iOS refuses every Metal command buffer, PiP or not. So the frames are made on the CPU:
   - willResignActive: one snapshot of the screen, taken while the GPU still works (a 3D frame is a Metal texture:
     one blit, the only GPU work PiP does), goes into the hidden layer. Windows is not touched (the Face ID and
     passkey sheets make the app inactive too). If the app goes on to the background, the layer shows and PiP starts
     by itself from that frame (canStartPictureInPictureAutomaticallyFromInline).
   - PiP willStart / didStart: a timer (10 per second) copies the 2D screen (hv_winvm_display_snapshot without the
     GPU) into IOSurface BGRA pixel buffers, only when it changed. While the screen is still a 3D texture (the switch
     to 2D not done yet) the snapshot stays. The feed runs only with PiP: failedToStart and didStop end it.
   - didBecomeActive: the feed stops (its last tick done), the layer is emptied and hidden, PiP stops, and the Metal
     presenter shows Windows again. Tapping the PiP window's restore button brings the app back.
   Armed only while leaving the app keeps Windows running (ServerModeController.applyPiP).
   The layer is flushed when it needs it (requiresFlushToResumeDecoding, a failed status). Main thread unless said. */

/// Posted on the main thread for each event (the background test logs them); userInfo[@"event"] is a short line.
extern NSNotificationName const WinIOSPiPEventNotification;

@interface WinIOSPictureInPicture : NSObject
@property (class, nonatomic, readonly) WinIOSPictureInPicture *shared;
/// The setting is on and leaving the app keeps Windows running (not Linux): PiP may start by itself when the app leaves.
@property (nonatomic) BOOL armed;
/// The layer goes into this view (the Windows canvas), above its own Metal content and below its subviews.
- (void)attachToView:(UIView *)view;
/// The view left its window: the layer comes out, unless it already lives in another view.
- (void)detachFromView:(UIView *)view;
/// The view's bounds changed (layoutSubviews).
- (void)viewDidLayout:(UIView *)view;
@property (nonatomic, readonly) BOOL supported;
@property (nonatomic, readonly) BOOL possible;
@property (nonatomic, readonly) BOOL active;
/// Frames put on the layer since launch (any thread).
@property (nonatomic, readonly) uint64_t framesSent;
@end

NS_ASSUME_NONNULL_END
