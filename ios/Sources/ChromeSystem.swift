// SPDX-License-Identifier: GPL-2.0-or-later
import ObjectiveC
import SwiftUI
import UIKit

/// One line in the app's log: stderr, which the bridge keeps in Documents/winvm.log.
func chromeLog(_ message: String) {
    fputs("chrome: \(message)\n", stderr)
}

/// Switches for the session chrome, read from the environment (Documents/env.txt sets them once
/// Windows starts). Each one restores the earlier behaviour or forces a path for testing on a device.
///   HV_CHROME_HOOKS=0  never change the root view controller's vertical bar or editing gestures
///   HV_VBAR_DISABLE=1  immersive always turns the iOS 27.1 vertical bar off; =0 never does
///   HV_FOLD_REGION=0   ignore iOS's fold region: Laptop splits the screen in half
///   HV_EDGE_SWIPE=0    no edge swipe out of immersive (four- and three-finger taps still work)
enum ChromeEnv {
    /// nil when unset; false for "0", "off", "no" or "false"; true otherwise.
    static func flag(_ name: String) -> Bool? {
        guard let raw = getenv(name) else { return nil }
        let v = String(cString: raw).trimmingCharacters(in: .whitespaces).lowercased()
        return !["0", "off", "no", "false"].contains(v)
    }
}

/// The system parts of the chrome that only the window's root view controller can change: the
/// iOS 27.1 vertical bar (`preferredVerticalBarBehavior`) and the three-finger text editing gestures
/// (`editingInteractionConfiguration`). SwiftUI owns the root controller, so both getters are
/// overridden on its class at run time; with the switches off they answer exactly as before.
enum RootControllerHooks {
    /// While true the root controller prefers `.disabled` for the vertical bar (immersive fallback).
    nonisolated(unsafe) static var verticalBarDisabled = false
    /// While true the system's editing gestures (three-finger undo swipe, edit menu tap, copy and
    /// paste pinches) are off, so they cannot fire on the Windows screen, which is a text input.
    nonisolated(unsafe) static var editingGesturesBlocked = false

    nonisolated(unsafe) private static var hookedClasses = Set<ObjectIdentifier>()
    nonisolated(unsafe) private(set) static var installedOn: String = "-"
    private static var hooksAllowed: Bool { ChromeEnv.flag("HV_CHROME_HOOKS") != false }

    /// Overrides the getters on the class of `controller` (once per class). Returns false when the
    /// class could not be hooked.
    @MainActor @discardableResult
    static func install(on controller: UIViewController) -> Bool {
        guard let cls = object_getClass(controller) else { return false }
        let key = ObjectIdentifier(cls)
        if hookedClasses.contains(key) { return true }
        hookedClasses.insert(key)
        installedOn = NSStringFromClass(cls)

        var ok = hookIntGetter(cls, "editingInteractionConfiguration") {
            editingGesturesBlocked ? UIEditingInteractionConfiguration.none.rawValue : nil
        }
        if #available(iOS 27.1, *) {
            ok = hookIntGetter(cls, "preferredVerticalBarBehavior") {
                verticalBarDisabled ? UIVerticalBarBehavior.disabled.rawValue : nil
            } && ok
            // A host that hands the choice to a child would never ask the root: answer nil then.
            ok = hookPointerGetter(cls, "childViewControllerForPreferredVerticalBarBehavior") {
                verticalBarDisabled
            } && ok
        }
        chromeLog("root controller hooks on \(installedOn): \(ok ? "installed" : "partly failed")")
        return ok
    }

    /// Replaces an NSInteger getter: `override` returns the value to answer, or nil to call the original.
    private static func hookIntGetter(_ cls: AnyClass, _ name: String, override: @escaping () -> Int?) -> Bool {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> Int = { obj in
            if hooksAllowed, let v = override() { return v }
            return original(obj, sel)
        }
        return addOrReplace(cls, sel, method, imp_implementationWithBlock(block))
    }

    /// Replaces an object getter. The pointer is passed through untouched (no retain or release),
    /// and `answerNil` makes it return nil.
    private static func hookPointerGetter(_ cls: AnyClass, _ name: String, answerNil: @escaping () -> Bool) -> Bool {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (AnyObject) -> UnsafeMutableRawPointer? = { obj in
            if hooksAllowed && answerNil() { return nil }
            return original(obj, sel)
        }
        return addOrReplace(cls, sel, method, imp_implementationWithBlock(block))
    }

    private static func addOrReplace(_ cls: AnyClass, _ sel: Selector, _ method: Method, _ imp: IMP) -> Bool {
        if class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) { return true }
        method_setImplementation(method, imp) // the class implements it itself: the original is captured
        return true
    }
}

/// Which side the iOS 27.1 vertical bar is on (the Duo's side column of status and bar items).
enum VerticalBarSide: String {
    case none, leading, trailing

    var title: String {
        switch self {
        case .none: return L("无", "None")
        case .leading: return L("前缘", "Leading edge")
        case .trailing: return L("后缘", "Trailing edge")
        }
    }

    @MainActor static func of(_ traits: UITraitCollection) -> VerticalBarSide {
        guard #available(iOS 27.1, *) else { return .none }
        switch traits.verticalBarEdge {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .none
        }
    }
}

/// The reserved regions iOS 27.1 reports for the screen: the fold (division) and the camera
/// island (occlusion), in the reader's coordinates (not mirrored for right-to-left layouts).
enum ReservedRegions {
    static func division(_ geo: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return geo.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)
            .first(where: { $0.isActive && !$0.frame.isNull })?.frame
    }

    static func occlusions(_ geo: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return geo.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
            .filter { $0.isActive && !$0.frame.isNull && !$0.frame.isEmpty }
            .map(\.frame)
    }
}

/// Window-wide gestures for the chrome: a four-finger tap (a three-finger tap on the Windows screen
/// is the alias, reported by the screen itself) and, while immersive, a swipe in from the left or
/// right edge. They see touches alongside the Windows screen and the deck and never hold them back.
@MainActor
final class ChromeWindowGestures: NSObject, UIGestureRecognizerDelegate {
    var onFourFingerTap: (() -> Void)?
    var onEdgeSwipe: (() -> Void)?

    private weak var window: UIWindow?
    private var recognizers: [UIGestureRecognizer] = []
    private var edgePans: [UIScreenEdgePanGestureRecognizer] = []

    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        let tap = UITapGestureRecognizer(target: self, action: #selector(fourFingerTap(_:)))
        tap.numberOfTouchesRequired = 4
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        recognizers.append(tap)
        for edge in [UIRectEdge.left, .right] {
            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePan(_:)))
            pan.edges = edge
            pan.delegate = self
            pan.isEnabled = false
            edgePans.append(pan)
            recognizers.append(pan)
        }
        recognizers.forEach(window.addGestureRecognizer)
    }

    func detach() {
        recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
        recognizers = []
        edgePans = []
    }

    /// The edge swipes are on now. Multi-touch holds a finger that lands at the left or right edge back from
    /// Windows while they are (TouchscreenInput.swift): the swipe cancels it before Windows sees it.
    static private(set) var edgeSwipeActive = false

    /// Edge swipes only while immersive: otherwise an edge drag belongs to Windows.
    func setEdgeSwipeEnabled(_ on: Bool) {
        let allowed = on && ChromeEnv.flag("HV_EDGE_SWIPE") != false
        edgePans.forEach { $0.isEnabled = allowed }
        Self.edgeSwipeActive = allowed
    }

    @objc private func fourFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        onFourFingerTap?()
    }

    @objc private func edgePan(_ gr: UIScreenEdgePanGestureRecognizer) {
        guard gr.state == .began else { return }
        onEdgeSwipe?()
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
