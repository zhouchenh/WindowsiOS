// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import SwiftUI
import UIKit

/// Shared pointer state between the upper Windows 11 Metal screen and the lower Laptop Glass Trackpad.
@MainActor
final class PointerController {
    static let shared = PointerController()

    var cursorX: Double = 0.5
    var cursorY: Double = 0.5
    private(set) var heldButtons: UInt8 = 0

    private var lastTapTime: CFTimeInterval = 0
    private var lastTapX: Double = 0.5
    private var lastTapY: Double = 0.5

    private init() {}

    func moveAbsolute(x: Double, y: Double, extraButtons: UInt8 = 0) {
        cursorX = min(1.0, max(0.0, x))
        cursorY = min(1.0, max(0.0, y))
        WinIOSBridge.shared.sendTabletNormalizedX(cursorX, y: cursorY, buttons: heldButtons | extraButtons, wheel: 0)
    }

    func moveRelative(dxPoints: CGFloat, dyPoints: CGFloat, padWidth: CGFloat, padHeight: CGFloat, extraButtons: UInt8 = 0) {
        // Natural laptop trackpad ballistics: fine pixel control at low speed, brisk traversal on flicks.
        let dist = hypot(Double(dxPoints), Double(dyPoints))
        let gain = min(2.35, 0.95 + dist * 0.055)
        let refW = Double(max(220.0, padWidth))
        let refH = Double(max(130.0, padHeight))
        let dx = (Double(dxPoints) / refW) * gain
        let dy = (Double(dyPoints) / refH) * gain
        cursorX = min(1.0, max(0.0, cursorX + dx))
        cursorY = min(1.0, max(0.0, cursorY + dy))
        WinIOSBridge.shared.sendTabletNormalizedX(cursorX, y: cursorY, buttons: heldButtons | extraButtons, wheel: 0)
    }

    /// The bridge lifted every button before Windows took a new size (releaseAllInputForReshape): none is
    /// held any more, so the next move does not press one again.
    func forgetHeldButtons() { heldButtons = 0 }

    func setHeldButton(_ mask: UInt8, down: Bool) {
        if down {
            heldButtons |= mask
        } else {
            heldButtons &= ~mask
        }
        WinIOSBridge.shared.sendTabletNormalizedX(cursorX, y: cursorY, buttons: heldButtons, wheel: 0)
    }

    func scroll(steps: Int8) {
        guard steps != 0 else { return }
        WinIOSBridge.shared.sendTabletNormalizedX(cursorX, y: cursorY, buttons: heldButtons, wheel: steps)
    }

    /// Direct-touch tap on the Windows display with automatic double-click coordinate snapping
    /// and hover-before-press sequencing for Windows 11 XAML / Desktop icons.
    func directTapAt(x: Double, y: Double, buttonMask: UInt8) {
        let now = CACurrentMediaTime()
        let dist = hypot(x - lastTapX, y - lastTapY)
        if now - lastTapTime < 0.40 && dist < 0.045 {
            // Snap rapid second tap to the exact pixel of the first tap so Win32 double-clicks register 100% reliably!
            cursorX = lastTapX
            cursorY = lastTapY
        } else {
            cursorX = min(1.0, max(0.0, x))
            cursorY = min(1.0, max(0.0, y))
            lastTapX = cursorX
            lastTapY = cursorY
        }
        lastTapTime = now

        let tx = cursorX
        let ty = cursorY
        // 1. Move cursor onto target so XAML hover states engage
        WinIOSBridge.shared.sendTabletNormalizedX(tx, y: ty, buttons: heldButtons, wheel: 0)
        // 2. Press button after 14 ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.014) { [weak self] in
            guard let self else { return }
            WinIOSBridge.shared.sendTabletNormalizedX(tx, y: ty, buttons: self.heldButtons | buttonMask, wheel: 0)
            // 3. Release button after 55 ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
                guard let self else { return }
                WinIOSBridge.shared.sendTabletNormalizedX(tx, y: ty, buttons: self.heldButtons, wheel: 0)
            }
        }
    }

    /// Trackpad tap-to-click at the current cursor position.
    func clickAtCurrent(buttonMask: UInt8) {
        let tx = cursorX
        let ty = cursorY
        WinIOSBridge.shared.sendTabletNormalizedX(tx, y: ty, buttons: heldButtons | buttonMask, wheel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.048) { [weak self] in
            guard let self else { return }
            WinIOSBridge.shared.sendTabletNormalizedX(tx, y: ty, buttons: self.heldButtons, wheel: 0)
        }
    }
}

/// Manages scene geometry orientation so Clamshell Laptop Mode aligns horizontally across the iPhone Duo fold.
@MainActor
enum SceneOrientationController {
    private static var currentPreferred: UIInterfaceOrientationMask = .portrait

    static func activeWindowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// When entering Laptop Mode on the unfolded iPhone Duo inner canvas (951x669 -> 669x951),
    /// rotate to Portrait so the physical hinge runs horizontally between the top screen and bottom keyboard deck.
    static func alignForLaptopPostureIfLandscape(size: CGSize) {
        guard size.width > size.height, max(size.width, size.height) > 780 else { return }
        guard let scene = activeWindowScene() else { return }
        currentPreferred = .portrait
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
    }

    /// Cycles scene orientation 90°/180° even when system Orientation Lock is active.
    static func rotateDeckOrientation() {
        guard let scene = activeWindowScene() else { return }
        let next: UIInterfaceOrientationMask
        switch scene.interfaceOrientation {
        case .portrait:
            next = .portraitUpsideDown
        case .portraitUpsideDown:
            next = .landscapeRight
        case .landscapeRight:
            next = .landscapeLeft
        default:
            next = .portrait
        }
        currentPreferred = next
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: next)) { _ in }
    }
}

/// An invisible controller in the session view: it reports the hinge, and hands the window, its root
/// controller and the iOS 27.1 vertical bar's edge to the session chrome (ChromeModel).
final class HingeObserverViewController: UIViewController {
    var onHingeUpdate: ((Int, Double?) -> Void)?
    private var didInstallHinge = false
    private var didRegisterTraits = false

    // The status bar, home indicator and edge gestures follow immersive mode (SwiftUI sets them on
    // the root controller; these answer the same in case a container asks its children).
    override var prefersStatusBarHidden: Bool { ChromeModel.shared.hidesSystemUI }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { ChromeModel.shared.hidesSystemUI ? .all : [] }
    override var prefersHomeIndicatorAutoHidden: Bool { ChromeModel.shared.hidesSystemUI }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        installHingeObserverIfAvailable()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        parent?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        parent?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        installHingeObserverIfAvailable()
        attachChrome()
    }

    /// The window-wide gestures, the root controller's hooks and the vertical bar's edge.
    private func attachChrome() {
        guard let window = view.window else { return }
        ChromeModel.shared.attach(window: window)
        ChromeModel.shared.traitsChanged(window.traitCollection)
        guard !didRegisterTraits else { return }
        didRegisterTraits = true
        var traits: [UITrait] = [UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]
        if #available(iOS 27.1, *) { traits += UITraitCollection.systemTraitsAffectingVerticalBarEdge }
        registerForTraitChanges(traits) { (vc: HingeObserverViewController, _: UITraitCollection) in
            ChromeModel.shared.traitsChanged(vc.view.window?.traitCollection ?? vc.traitCollection)
        }
    }

    /// UIHingeInteraction (iOS 27.1+) reports the fold of a foldable device. Elsewhere (older iOS, or a
    /// device without a hinge, where the update's `hinge` is nil) nothing is reported, and the app
    /// falls back to the screen's shape and the posture the user picks.
    private func installHingeObserverIfAvailable() {
        guard !didInstallHinge else { return }
        didInstallHinge = true
        guard #available(iOS 27.1, *) else { return }
        let interaction = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            guard let hinge = update.hinge else {
                WinIOSBridge.shared.updateHingeStatus(0, angleDegrees: -1.0)
                self.onHingeUpdate?(0, nil)
                return
            }
            let rawStatus = hinge.status.rawValue
            // UIHinge.angle is in radians: the SDK's UIHinge.h ("The current angle of the hinge, in
            // radians.") and Apple's documentation for UIHinge.angle say so.
            let deg = Double(hinge.angle) * 180.0 / .pi
            WinIOSBridge.shared.updateHingeStatus(rawStatus, angleDegrees: deg)
            self.onHingeUpdate?(rawStatus, deg)
        }
        view.addInteraction(interaction)
    }
}

struct HingeSensorView: UIViewControllerRepresentable {
    var onHingeUpdate: (Int, Double?) -> Void

    func makeUIViewController(context: Context) -> HingeObserverViewController {
        let vc = HingeObserverViewController()
        vc.onHingeUpdate = onHingeUpdate
        return vc
    }

    func updateUIViewController(_ uiViewController: HingeObserverViewController, context: Context) {
        uiViewController.onHingeUpdate = onHingeUpdate
    }
}
