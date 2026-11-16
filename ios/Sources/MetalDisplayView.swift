// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// The Windows screen. Touch works like a laptop trackpad by default:
///   one finger moves the pointer, a tap is a left click, a two-finger tap is a right click,
///   two fingers scroll, tap-then-hold (or a long press) drags, a three-finger tap shows the toolbar.
/// In direct mode a tap clicks where the finger is, as on a touch-screen PC.
/// A pinch zooms in the Windows app (Ctrl + wheel); a three-finger double-tap zooms the picture itself
/// (then a pinch sets that zoom, three fingers drag it, and a map of the screen shows where you are).
/// Typing: see TextInputBridge.swift (text, focus) and WindowsKeyBar.swift (the keys above the keyboard).
final class MetalCanvasUIView: UIView, UITextInput {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// false: trackpad (relative pointer). true: direct touch (absolute).
    var directTouch: Bool = false
    var onThreeFingerTap: (() -> Void)?
    var onKeyboardDismissed: (() -> Void)?
    /// The laptop deck's F8: the next one-finger tap is a right click.
    var rightClickArmed: Bool = false
    var onRightClickConsumed: (() -> Void)?
    /// Windows was used: a touch gesture (not the three-finger tap) or a click with a mouse.
    var onUserInteraction: (() -> Void)?
    /// false when the view's size never follows the on-screen keyboard (the laptop lid): then it
    /// reports its size for the Windows resolution even while it has the keyboard focus.
    var keyboardResizesView: Bool = true
    /// A hardware keyboard (Magic Keyboard, Bluetooth, USB) is attached: its keys go straight to
    /// Windows, and the on-screen key row is not shown.
    var hardwareKeyboard: Bool = false {
        didSet {
            guard oldValue != hardwareKeyboard else { return }
            if isFirstResponder { reloadInputViews() }
            setNeedsLayout()
        }
    }
    private var keysDown: Set<UInt8> = []

    // MARK: touch state
    private var fingers: [UITouch] = []
    private var gestureStart: CFTimeInterval = 0
    private var maxFingers = 0
    private var travelled: CGFloat = 0
    private var lastCentroid: CGPoint = .zero
    private var firstPoint: CGPoint = .zero
    private var dragging = false
    private var consumed = false
    private var lastTapEnd: CFTimeInterval = 0
    private var scrollAccum: CGFloat = 0
    private var longPressWork: DispatchWorkItem?
    private var pointerButtons: UInt8 = 0

    private let tapSlop: CGFloat = 9
    private let tapMaxDuration: CFTimeInterval = 0.32
    private let tapAndHoldWindow: CFTimeInterval = 0.28
    private let longPressDelay: TimeInterval = 0.5
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    // MARK: keyboard, text and zoom state
    /// Ctrl/Alt/Shift/Win latches and the bar key held in Windows.
    let keys = WindowsKeyState()
    /// Pan/zoom of the picture (keyboard pan, viewport zoom).
    let viewport = ViewportController()
    /// What the iOS keyboard is composing (TextInputBridge.swift).
    let textDoc = TextInputDocument()
    lazy var keyBar = WindowsKeyBar(canvas: self, keys: keys, viewport: viewport)
    /// The screen map shown over the picture while it is zoomed and the key bar is not up.
    private(set) var floatingMap: MiniMapView?
    /// The keyboard should come up (a text box got the focus): the SwiftUI side raises it.
    var onKeyboardRequested: (() -> Void)?
    var lastFocus: FocusReport?
    var lastTouchAt: CFTimeInterval = 0
    /// Where a finger last tapped, in unzoomed picture points (stands in for the caret).
    var lastTapPicturePoint: CGPoint?
    var keyboardAutoShown = false
    var pendingHide: DispatchWorkItem?
    private var lastInputSize: CGSize = .zero
    private var lastFramebufferSize: CGSize = .zero
    // two fingers: scroll, or pinch (Ctrl + wheel to Windows; the viewport zoom while zoomed)
    private enum TwoFingerMode { case undecided, scroll, pinchApp, pinchViewport }
    private var twoMode: TwoFingerMode = .undecided
    private var pinchStartDistance: CGFloat = 0
    private var pinchLastDistance: CGFloat = 0
    private var pinchStartZoom: CGFloat = 1
    private var pinchAccum: CGFloat = 0
    private var pinchCtrlDown = false
    // three fingers: tap = toolbar, double-tap = viewport zoom, drag = pan the zoomed picture
    private var lastThreeTapAt: CFTimeInterval = 0
    private var pendingThreeTap: DispatchWorkItem?

    // UITextInput
    weak var inputDelegate: UITextInputDelegate?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect
        updateDrawableScale()

        // A mouse or trackpad attached to the device: the iPad's own pointer is hidden over the Windows
        // screen (Windows draws its cursor), and comes back when it leaves, e.g. onto the toolbar.
        addInteraction(UIPointerInteraction(delegate: self))
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        NotificationCenter.default.addObserver(self, selector: #selector(releaseAllKeys),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayWillReshape),
                                               name: .WinIOSDisplayWillReshape, object: nil)
        configureInput()
        // Pointer movement and its scroll wheel.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = [] // scroll events only: fingers are handled in touchesBegan and friends
        addGestureRecognizer(wheel)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableScale()
        if window != nil {
            WinIOSBridge.shared.bindMetalLayer(metalLayer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableScale()
        inputLayoutChanged()
    }

    // MARK: drawable size, scale and sampling (display engine; see DisplaySettings.swift)

    private var displayStateObserver: NSObjectProtocol?

    /// The drawable is the view in native panel pixels (UIScreen.nativeScale, not .scale), so a 1:1 Windows
    /// mode lands exactly on the panel's pixels; the presenter (fb_metal.m) samples with nearest at 1:1 and
    /// 2x. HV_DISPLAY_LEGACY=1 keeps the former drawable at UIScreen.scale.
    private func updateDrawableScale() {
        let bridge = WinIOSBridge.shared
        let screen = window?.windowScene?.screen ?? window?.screen ?? UIScreen.main
        let legacy = bridge.displayLegacy
        let scale = legacy ? screen.scale : screen.nativeScale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let px = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let drawable = legacy ? CGSize(width: max(1.0, px.width), height: max(1.0, px.height))
                              : CGSize(width: max(1.0, (px.width + 0.01).rounded(.down)), height: max(1.0, (px.height + 0.01).rounded(.down)))
        if metalLayer.drawableSize != drawable { metalLayer.drawableSize = drawable }
        updateContentsGravity(exact: abs(px.width - drawable.width) < 0.02 && abs(px.height - drawable.height) < 0.02)
        if let winBounds = window?.bounds.size, winBounds.width > 0 {
            bridge.updateScreenSize(winBounds, scale: screen.scale)
        }
        // While the on-screen keyboard is up the view is shorter: do not ask Windows to change
        // resolution for that. With a hardware keyboard (focus without the on-screen keyboard) or in
        // the laptop lid (never resized by the keyboard) the size is the real one.
        if bounds.width > 0 && bounds.height > 0 && (!isFirstResponder || hardwareKeyboard || !keyboardResizesView) {
            bridge.updateDisplayViewSize(bounds.size, nativeScale: screen.nativeScale)
        }
        if window != nil && bounds.width > 0 { DisplaySettings.shared.record(view: self, drawable: drawable) }
        if displayStateObserver == nil {
            displayStateObserver = NotificationCenter.default.addObserver(
                forName: .WinIOSDisplayStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDrawableScale() }
            }
        }
    }

    /// A drawable that is exactly the view's pixels is shown as is. When the view is a fraction of a pixel
    /// off, it is shown unscaled at the top left (a sub-pixel margin, no resampling); while Windows takes a
    /// new size the last frame is scaled to the view instead (the old picture, not a cropped one).
    private func updateContentsGravity(exact: Bool) {
        let b = WinIOSBridge.shared
        let reshaping = b.displayReshapeState != .idle || b.presenterStats().holding != 0
        let gravity: CALayerContentsGravity = (b.displayLegacy || exact || reshaping) ? .resizeAspect : .topLeft
        if metalLayer.contentsGravity != gravity { metalLayer.contentsGravity = gravity }
    }

    private func normalizedPoint(for screenPt: CGPoint) -> (Double, Double) {
        let pt = viewport.unproject(screenPt) // the picture may be panned or zoomed
        let bw = max(1.0, bounds.width)
        let bh = max(1.0, bounds.height)
        let fbW = Double(WinIOSBridge.shared.framebufferWidth)
        let fbH = Double(WinIOSBridge.shared.framebufferHeight)

        var rect = bounds
        if fbW > 0 && fbH > 0 {
            let viewAspect = Double(bw / bh)
            let fbAspect = fbW / fbH
            if viewAspect > fbAspect {
                let fittedW = CGFloat(Double(bh) * fbAspect)
                rect = CGRect(x: (bw - fittedW) * 0.5, y: 0, width: fittedW, height: bh)
            } else {
                let fittedH = CGFloat(Double(bw) / fbAspect)
                rect = CGRect(x: 0, y: (bh - fittedH) * 0.5, width: bw, height: fittedH)
            }
        }
        let nx = min(1.0, max(0.0, Double((pt.x - rect.minX) / max(1.0, rect.width))))
        let ny = min(1.0, max(0.0, Double((pt.y - rect.minY) / max(1.0, rect.height))))
        return (nx, ny)
    }

    // MARK: - Touches

    private func centroid() -> CGPoint {
        guard !fingers.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for t in fingers {
            let p = t.location(in: self)
            x += p.x
            y += p.y
        }
        return CGPoint(x: x / CGFloat(fingers.count), y: y / CGFloat(fingers.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        WinIOSBridge.shared.noteUserInput() // the display goes back to its full frame rate now
        // An attached mouse or trackpad clicking: absolute position, the button it pressed.
        let pointerTouches = touches.filter { $0.type == .indirectPointer }
        if let t = pointerTouches.first {
            let (nx, ny) = normalizedPoint(for: t.location(in: self))
            pointerButtons = (event?.buttonMask.contains(.secondary) ?? false) ? 2 : 1
            PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: pointerButtons)
            onUserInteraction?()
        }
        let newFingers = touches.filter { $0.type != .indirectPointer }
        guard !newFingers.isEmpty else { return }

        let now = CACurrentMediaTime()
        lastTouchAt = now
        checkFramebufferSize()
        if fingers.isEmpty {
            gestureStart = now
            maxFingers = 0
            travelled = 0
            scrollAccum = 0
            consumed = false
            dragging = false
            twoMode = .undecided
            firstPoint = newFingers.first!.location(in: self)
            if directTouch {
                let (nx, ny) = normalizedPoint(for: firstPoint)
                PointerController.shared.moveAbsolute(x: nx, y: ny) // hover first, so buttons highlight
            } else if now - lastTapEnd < tapAndHoldWindow {
                // Tap, then touch again: the button goes down now. Lifting without moving makes it the
                // second click of a double-click; moving makes it a drag.
                dragging = true
                PointerController.shared.setHeldButton(1, down: true)
            }
            scheduleLongPress()
        }
        fingers.append(contentsOf: newFingers)
        maxFingers = max(maxFingers, fingers.count)
        if fingers.count > 1 { cancelLongPress() }
        if fingers.count == 2 && twoMode == .undecided {
            pinchStartDistance = fingerDistance()
            pinchLastDistance = pinchStartDistance
        } else if fingers.count > 2 {
            endPinch() // a third finger: not a pinch any more
        }
        lastCentroid = centroid()
    }

    private func fingerDistance() -> CGFloat {
        guard fingers.count >= 2 else { return 0 }
        let a = fingers[0].location(in: self), b = fingers[1].location(in: self)
        return hypot(a.x - b.x, a.y - b.y)
    }

    /// Two fingers changing their distance: Ctrl + wheel steps to the Windows app (its own zoom), at the
    /// fingers in direct mode, at the pointer in trackpad mode; while the picture is zoomed, its zoom.
    private func pinchMoved(centroid c: CGPoint, delta: CGPoint) {
        let d = fingerDistance()
        guard d > 1, pinchStartDistance > 1 else { return }
        if twoMode == .undecided {
            let ratio = abs(d - pinchStartDistance) / pinchStartDistance
            if ratio > 0.1 && travelled < abs(d - pinchStartDistance) {
                consumed = true
                if viewport.isZoomed {
                    twoMode = .pinchViewport
                    pinchStartZoom = viewport.zoom
                    pinchStartDistance = d
                } else if KeyboardOptions.pinchToWindows {
                    twoMode = .pinchApp
                    pinchAccum = 0
                    pinchLastDistance = d
                    if directTouch {
                        let (nx, ny) = normalizedPoint(for: c)
                        PointerController.shared.moveAbsolute(x: nx, y: ny)
                    }
                    WinIOSBridge.shared.sendKeyHid(WindowsKeyState.ctrl, down: true)
                    pinchCtrlDown = true
                } else {
                    twoMode = .scroll
                }
            } else if travelled > tapSlop * 1.5 {
                twoMode = .scroll
            }
            return
        }
        switch twoMode {
        case .pinchViewport:
            viewport.setZoom(pinchStartZoom * d / pinchStartDistance, anchor: c)
            viewport.pan(by: delta)
        case .pinchApp:
            pinchAccum += log(d / pinchLastDistance)
            pinchLastDistance = d
            let notch: CGFloat = 0.12 // about 13% of finger spread per wheel notch
            if abs(pinchAccum) >= notch {
                let steps = Int(pinchAccum / notch)
                pinchAccum -= CGFloat(steps) * notch
                PointerController.shared.scroll(steps: Int8(clamping: max(-4, min(4, steps))))
            }
        default:
            break
        }
    }

    private func endPinch() {
        if pinchCtrlDown {
            pinchCtrlDown = false
            WinIOSBridge.shared.sendKeyHid(WindowsKeyState.ctrl, down: false)
        }
        if twoMode == .pinchApp || twoMode == .pinchViewport { twoMode = .scroll }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first(where: { $0.type == .indirectPointer }) {
            let (nx, ny) = normalizedPoint(for: t.location(in: self))
            PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: pointerButtons)
        }
        guard touches.contains(where: { fingers.contains($0) }) else { return }
        let c = centroid()
        let dx = c.x - lastCentroid.x
        let dy = c.y - lastCentroid.y
        lastCentroid = c
        travelled += hypot(dx, dy)
        if travelled > tapSlop { cancelLongPress() }
        if fingers.count == 2 && twoMode != .scroll {
            pinchMoved(centroid: c, delta: CGPoint(x: dx, y: dy))
            if twoMode != .scroll { return }
        }
        if fingers.count == 3 && viewport.isZoomed && travelled > tapSlop {
            consumed = true // three fingers drag the zoomed picture
            viewport.pan(by: CGPoint(x: dx, y: dy))
            return
        }
        if consumed { return }

        if fingers.count == 1 {
            if directTouch {
                guard travelled > tapSlop else { return }
                if !dragging {
                    dragging = true
                    let (sx, sy) = normalizedPoint(for: firstPoint)
                    PointerController.shared.moveAbsolute(x: sx, y: sy)
                    PointerController.shared.setHeldButton(1, down: true)
                }
                let (nx, ny) = normalizedPoint(for: c)
                PointerController.shared.moveAbsolute(x: nx, y: ny)
            } else {
                // zoomed in: finer pointer steps, and the picture follows the pointer near its edges
                PointerController.shared.moveRelative(dxPoints: dx, dyPoints: dy,
                                                      padWidth: bounds.width * viewport.zoom,
                                                      padHeight: bounds.height * viewport.zoom)
                if viewport.isZoomed { followPointer() }
            }
        } else if fingers.count == 2 {
            scrollAccum += dy
            let step: CGFloat = 14
            if abs(scrollAccum) >= step {
                let steps = Int(scrollAccum / step)
                scrollAccum -= CGFloat(steps) * step
                PointerController.shared.scroll(steps: Int8(clamping: max(-8, min(8, steps))))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(touches, cancelled: true)
    }

    private func finishTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        if touches.contains(where: { $0.type == .indirectPointer }) && pointerButtons != 0 {
            pointerButtons = 0
            PointerController.shared.moveAbsolute(x: PointerController.shared.cursorX, y: PointerController.shared.cursorY)
        }
        let before = fingers.count
        fingers.removeAll { touches.contains($0) }
        if fingers.count < 2 { endPinch() } // Ctrl never stays down
        guard before > 0, fingers.isEmpty else {
            if !fingers.isEmpty { lastCentroid = centroid() }
            return
        }
        cancelLongPress()
        let now = CACurrentMediaTime()
        lastTouchAt = now
        let wasTap = !cancelled && travelled <= tapSlop && (now - gestureStart) <= tapMaxDuration
        if maxFingers < 3 && !cancelled { onUserInteraction?() }

        if dragging {
            dragging = false
            PointerController.shared.setHeldButton(1, down: false)
            lastTapEnd = 0
            return
        }
        guard wasTap, !consumed else { return }
        if maxFingers == 1 {
            lastTapPicturePoint = viewport.unproject(directTouch ? firstPoint : pointerOnScreen())
            tappedForKeyboard(at: now)
        }
        switch maxFingers {
        case 1:
            if rightClickArmed {
                // armed from the deck (F8): this tap is a right click, once
                rightClickArmed = false
                onRightClickConsumed?()
                mediumHaptic.impactOccurred(intensity: 0.7)
                if directTouch {
                    let (nx, ny) = normalizedPoint(for: firstPoint)
                    PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
                } else {
                    PointerController.shared.clickAtCurrent(buttonMask: 2)
                }
                break
            }
            lightHaptic.impactOccurred(intensity: 0.5)
            if directTouch {
                let (nx, ny) = normalizedPoint(for: firstPoint)
                PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 1)
            } else {
                PointerController.shared.clickAtCurrent(buttonMask: 1)
                lastTapEnd = now
            }
        case 2:
            mediumHaptic.impactOccurred(intensity: 0.7)
            if directTouch {
                let (nx, ny) = normalizedPoint(for: firstPoint)
                PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
            } else {
                PointerController.shared.clickAtCurrent(buttonMask: 2)
            }
        case 3:
            lightHaptic.impactOccurred()
            if now - lastThreeTapAt < 0.4 {
                // three-finger double-tap: zoom the picture around the fingers (or back out)
                lastThreeTapAt = 0
                pendingThreeTap?.cancel()
                pendingThreeTap = nil
                toggleViewportZoom(anchor: lastCentroid)
            } else {
                lastThreeTapAt = now
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingThreeTap = nil
                    self?.onThreeFingerTap?()
                }
                pendingThreeTap = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        default:
            break
        }
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.fingers.count == 1, self.travelled <= self.tapSlop, !self.dragging else { return }
            self.mediumHaptic.impactOccurred()
            if self.directTouch {
                // touch-screen convention: press and hold is a right click
                let (nx, ny) = self.normalizedPoint(for: self.firstPoint)
                PointerController.shared.directTapAt(x: nx, y: ny, buttonMask: 2)
                self.consumed = true
            } else {
                // trackpad: press and hold picks up (left button held until the finger lifts)
                self.dragging = true
                PointerController.shared.setHeldButton(1, down: true)
            }
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }

    /// Windows is about to take a new size (posted once per reshape, after the bridge lifted what it had
    /// sent down): the gesture in progress ends here as if cancelled, so a drag, a held button, a long
    /// press or a pinch's Ctrl does not carry over onto the new layout. Fingers still down do nothing
    /// more until they lift; the next touch starts afresh.
    @objc private func displayWillReshape() {
        cancelLongPress()
        endPinch()
        if dragging {
            dragging = false
            PointerController.shared.setHeldButton(1, down: false)
        }
        if !fingers.isEmpty { consumed = true }
        keysDown.removeAll() // lifted by the bridge; a key still pressed sends its own key-up later
        PointerController.shared.forgetHeldButtons()
        WinIOSBridge.shared.releaseAllInputForReshape()
    }

    @objc private func handleHover(_ gr: UIHoverGestureRecognizer) {
        // Only while the pointer is over the view: when the hover ends (the finger leaves the trackpad
        // and iPadOS hides the pointer) its location is no longer the pointer's, often (0, 0), and the
        // guest's cursor jumped to the top-left corner.
        guard gr.state == .began || gr.state == .changed else { return }
        let (nx, ny) = normalizedPoint(for: gr.location(in: self))
        PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: pointerButtons)
    }

    @objc private func handleWheel(_ gr: UIPanGestureRecognizer) {
        let trans = gr.translation(in: self)
        if gr.state == .began {
            scrollAccum = 0
        } else if gr.state == .changed {
            let delta = trans.y - scrollAccum
            if abs(delta) >= 12 {
                let steps = Int(delta / 12)
                scrollAccum += CGFloat(steps) * 12
                PointerController.shared.scroll(steps: Int8(clamping: max(-8, min(8, steps))))
            }
        }
    }

    // MARK: - Keyboard (USB HID usage page 0x07)

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { hardwareKeyboard ? nil : keyBar }
    /// No iOS text-editing gestures (three-finger undo swipe, edit menu, copy/paste pinch) on the canvas:
    /// those fingers are Windows' (and the viewport zoom's).
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    // UITextInputTraits: Windows gets exactly what is typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var isSecureTextEntry: Bool = false
    /// Every keyboard (Pinyin, emoji...) once the WinKit focus agent can type what they produce; until
    /// then the ASCII keyboard, whose keys all exist on a USB keyboard. Read when the keyboard comes up.
    var keyboardType: UIKeyboardType {
        get {
            let seen = WinIOSBridge.shared.focusAgentSeenSeconds
            return KeyboardOptions.unicodeText && seen >= 0 && seen <= 60 ? .default : .asciiCapable
        }
        set {}
    }
    var keyboardAppearance: UIKeyboardAppearance = .dark

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r {
            keys.releaseAll(keepLatches: false)
            releaseAllKeys()
            pendingHide?.cancel()
            pendingHide = nil
            keyboardAutoShown = false
            setNeedsLayout()
            updateFloatingMap()
        }
        return r
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { updateFloatingMap() } // the key bar has its own map
        return r
    }

    /// One key press with the latched modifiers (Ctrl/Alt/Win/Shift from the bar above the keyboard).
    func sendKey(_ usage: UInt8, withShift shift: Bool) {
        keys.tap(usage, extra: shift ? [WindowsKeyState.shift] : [])
    }

    func dismissKeyboard() {
        resignFirstResponder()
        onKeyboardDismissed?()
    }

    // MARK: - Panning for the keyboard, viewport zoom

    private func configureInput() {
        viewport.view = self
        viewport.onChange = { [weak self] in self?.viewportChanged() }
        keyBar.miniMap.onReturnToCaret = { [weak self] in self?.returnToCaret() }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(releaseAllKeys), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardFrameWillChange(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(focusReportArrived(_:)), name: .WinIOSFocusReport, object: nil)
    }

    /// The view changed size (rotation, fold): nothing stays held down in Windows, the pan stays valid.
    private func inputLayoutChanged() {
        guard bounds.size != lastInputSize else { return }
        let first = lastInputSize == .zero
        lastInputSize = bounds.size
        if !first {
            endPinch()
            keys.releaseAll(keepLatches: true)
        }
        viewport.layoutChanged()
        KeyboardDiagnostics.shared.viewHeight = bounds.height
    }

    /// Windows changed resolution: the fitted picture moved.
    private func checkFramebufferSize() {
        let fb = viewport.framebufferSize
        if fb != lastFramebufferSize {
            lastFramebufferSize = fb
            viewport.layoutChanged()
        }
    }

    /// The keyboard (with the key bar) moves: the picture slides so the caret or the tap point stays above it.
    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard KeyboardOptions.panInsteadOfShrink, let window, let info = note.userInfo,
              let end = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let kb = convert(end, from: window.screen.coordinateSpace)
        var overlap: CGFloat = 0
        if isFirstResponder && note.name != UIResponder.keyboardWillHideNotification && kb.height > 1 && kb.intersects(bounds) {
            overlap = max(0, bounds.maxY - kb.minY)
        }
        guard abs(overlap - viewport.keyboardOverlap) > 0.5 else { return }
        let diag = KeyboardDiagnostics.shared
        diag.keyboardOverlap = overlap
        diag.log(String(format: "keyboard covers %.0f of %.0f pt", overlap, bounds.height))
        viewport.setKeyboardOverlap(overlap, keep: overlap > 0 && KeyboardOptions.followCaret ? panTarget() : nil,
                                    duration: duration)
    }

    private func viewportChanged() {
        KeyboardDiagnostics.shared.zoom = viewport.zoom
        keyBar.miniMap.setNeedsLayout()
        updateFloatingMap()
    }

    /// The screen map over the picture: while it is zoomed and the key bar (with its own map) is not up.
    private func updateFloatingMap() {
        let show = viewport.isZoomed && !(isFirstResponder && !hardwareKeyboard)
        if show && floatingMap == nil {
            let m = MiniMapView()
            m.viewport = viewport
            m.onReturnToCaret = { [weak self] in self?.returnToCaret() }
            m.caretFramebufferRect = keyBar.miniMap.caretFramebufferRect
            m.alpha = 0
            addSubview(m)
            floatingMap = m
        }
        guard let m = floatingMap else { return }
        let h: CGFloat = 70
        let w = m.preferredWidth(forHeight: h)
        m.frame = CGRect(x: bounds.maxX - safeAreaInsets.right - 12 - w, y: safeAreaInsets.top + 12, width: w, height: h)
        m.setNeedsLayout()
        let alpha: CGFloat = show ? 1 : 0
        if m.alpha != alpha {
            UIView.animate(withDuration: 0.2) { m.alpha = alpha }
            if show { m.refreshPicture() }
        }
    }

    /// Three-finger double-tap (or the Shortcuts menu): 2x around the point, or back to the whole screen.
    func toggleViewportZoom(anchor: CGPoint?) {
        mediumHaptic.impactOccurred()
        if viewport.isZoomed {
            viewport.resetZoom()
        } else {
            viewport.setZoom(2, anchor: anchor ?? CGPoint(x: bounds.midX, y: viewport.visibleRect.midY), duration: 0.22)
        }
        KeyboardDiagnostics.shared.log(String(format: "viewport zoom %.1f", viewport.isZoomed ? 2.0 : 1.0))
    }

    /// The map's double-tap: the caret (or the tap point) back in view.
    private func returnToCaret() {
        guard let t = panTarget() else { return }
        viewport.centre(on: CGPoint(x: t.midX, y: t.midY))
    }

    /// Trackpad mode while zoomed: the picture follows the pointer once it nears an edge.
    private func followPointer() {
        let f = viewport.fittedRect
        let p = CGPoint(x: f.minX + CGFloat(PointerController.shared.cursorX) * f.width,
                        y: f.minY + CGFloat(PointerController.shared.cursorY) * f.height)
        viewport.reveal(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8), band: ViewportController.followBand, duration: 0)
    }

    /// Where Windows' pointer is drawn now, on screen.
    private func pointerOnScreen() -> CGPoint {
        let f = viewport.fittedRect
        return viewport.project(CGPoint(x: f.minX + CGFloat(PointerController.shared.cursorX) * f.width,
                                        y: f.minY + CGFloat(PointerController.shared.cursorY) * f.height))
    }

    /// A tap into the text box that already has the focus raises no focus event: if none comes, and the
    /// tap was inside that box, the keyboard comes up anyway.
    private func tappedForKeyboard(at time: CFTimeInterval) {
        guard KeyboardOptions.autoShow, keyboardResizesView, !hardwareKeyboard, !isFirstResponder,
              let r = lastFocus, r.isText, r.elem != nil, let tap = lastTapPicturePoint else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            // still a text box (a caret report from the click is fine; a focus change has had its say)
            guard let self, !self.isFirstResponder, let now = self.lastFocus, now.isText, let e = now.elem,
                  now.receivedAt < time || now.event == "caret" else { return }
            let box = self.viewport.pictureRect(fromFramebuffer: self.scaleToFramebuffer(e, from: now.framebuffer))
            guard box.insetBy(dx: -6, dy: -6).contains(tap) else { return }
            self.keyboardAutoShown = true
            KeyboardDiagnostics.shared.autoShows += 1
            KeyboardDiagnostics.shared.log("tap in the focused text box: keyboard up")
            self.onKeyboardRequested?()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    keysDown.insert(UInt8(code))
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: true)
                    handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key {
                let code = key.keyCode.rawValue
                if code >= 0x04 && code <= 0xe7 {
                    keysDown.remove(UInt8(code))
                    WinIOSBridge.shared.sendKeyHid(UInt8(code), down: false)
                    handled = true
                }
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    /// Keys still held when the app loses focus (Cmd-Tab away, a sheet opens) would stay down in Windows.
    @objc func releaseAllKeys() {
        for k in keysDown { WinIOSBridge.shared.sendKeyHid(k, down: false) }
        keysDown.removeAll()
        endPinch()
        keys.releaseAll(keepLatches: UIApplication.shared.applicationState == .active)
    }

    static func asciiToHID(_ ch: Character) -> (UInt8, Bool)? {
        if let ascii = ch.asciiValue {
            switch ascii {
            case 97...122: return (UInt8(0x04 + Int(ascii - 97)), false) // a-z
            case 65...90:  return (UInt8(0x04 + Int(ascii - 65)), true)  // A-Z
            case 49...57:  return (UInt8(0x1e + Int(ascii - 49)), false) // 1-9
            case 48:       return (0x27, false) // 0
            case 10, 13:   return (0x28, false) // Enter
            case 9:        return (0x2b, false) // Tab
            case 32:       return (0x2c, false) // Space
            default: break
            }
        }
        let symbols: [Character: (UInt8, Bool)] = [
            "!": (0x1e, true), "@": (0x1f, true), "#": (0x20, true), "$": (0x21, true),
            "%": (0x22, true), "^": (0x23, true), "&": (0x24, true), "*": (0x25, true),
            "(": (0x26, true), ")": (0x27, true), "-": (0x2d, false), "_": (0x2d, true),
            "=": (0x2e, false), "+": (0x2e, true), "[": (0x2f, false), "{": (0x2f, true),
            "]": (0x30, false), "}": (0x30, true), "\\": (0x31, false), "|": (0x31, true),
            ";": (0x33, false), ":": (0x33, true), "'": (0x34, false), "\"": (0x34, true),
            "`": (0x35, false), "~": (0x35, true), ",": (0x36, false), "<": (0x36, true),
            ".": (0x37, false), ">": (0x37, true), "/": (0x38, false), "?": (0x38, true),
        ]
        return symbols[ch]
    }
}

extension MetalCanvasUIView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }
}

/// The Windows screen in SwiftUI. In Studio the canvas reaches under the on-screen keyboard: the picture
/// keeps its size and slides up so the caret stays in view, instead of shrinking (HV_KBD_PAN=0: shrinks,
/// as before). One view in both postures (no if/else), so the canvas keeps its identity and focus.
struct MetalDisplayView: View {
    @Binding var directTouch: Bool
    @Binding var keyboardVisible: Bool
    var hardwareKeyboard: Bool
    var focusAllowed: Bool
    var onThreeFingerTap: () -> Void
    var rightClickArmed: Binding<Bool> = .constant(false)
    var keyboardResizesView: Bool = true
    var onUserInteraction: (() -> Void)? = nil

    var body: some View {
        MetalCanvasRepresentable(directTouch: $directTouch, keyboardVisible: $keyboardVisible,
                                 hardwareKeyboard: hardwareKeyboard, focusAllowed: focusAllowed,
                                 onThreeFingerTap: onThreeFingerTap, rightClickArmed: rightClickArmed,
                                 keyboardResizesView: keyboardResizesView, onUserInteraction: onUserInteraction)
            .ignoresSafeArea(keyboardResizesView && KeyboardOptions.panInsteadOfShrink ? .keyboard : [], edges: .bottom)
    }
}

struct MetalCanvasRepresentable: UIViewRepresentable {
    @Binding var directTouch: Bool
    @Binding var keyboardVisible: Bool
    /// A hardware keyboard is attached: keep the keyboard focus on Windows by itself.
    var hardwareKeyboard: Bool
    /// False while a sheet (settings, Safari) needs the keyboard.
    var focusAllowed: Bool
    var onThreeFingerTap: () -> Void
    /// Set by the laptop deck's F8: the next one-finger tap is a right click (cleared once used).
    var rightClickArmed: Binding<Bool> = .constant(false)
    /// false for the laptop lid, whose size does not change with the on-screen keyboard.
    var keyboardResizesView: Bool = true
    var onUserInteraction: (() -> Void)? = nil

    func makeUIView(context: Context) -> MetalCanvasUIView {
        let view = MetalCanvasUIView(frame: .zero)
        view.onThreeFingerTap = onThreeFingerTap
        view.onKeyboardDismissed = {
            DispatchQueue.main.async { self.keyboardVisible = false }
        }
        return view
    }

    static func dismantleUIView(_ uiView: MetalCanvasUIView, coordinator: ()) {
        uiView.releaseAllKeys()
    }

    func updateUIView(_ uiView: MetalCanvasUIView, context: Context) {
        uiView.directTouch = directTouch
        uiView.hardwareKeyboard = hardwareKeyboard
        uiView.onThreeFingerTap = onThreeFingerTap
        uiView.onUserInteraction = onUserInteraction
        let visible = $keyboardVisible
        uiView.onKeyboardRequested = { // a text box in Windows got the focus
            DispatchQueue.main.async { visible.wrappedValue = true }
        }
        uiView.rightClickArmed = rightClickArmed.wrappedValue
        let armed = rightClickArmed
        uiView.onRightClickConsumed = {
            DispatchQueue.main.async { armed.wrappedValue = false }
        }
        if uiView.keyboardResizesView != keyboardResizesView {
            uiView.keyboardResizesView = keyboardResizesView
            uiView.setNeedsLayout()
        }
        let wantsFocus = focusAllowed && (keyboardVisible || hardwareKeyboard)
        if wantsFocus && !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !wantsFocus && uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }
}
