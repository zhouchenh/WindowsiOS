// SPDX-License-Identifier: GPL-2.0-or-later
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// The Windows screen. Touch works like a laptop trackpad by default:
///   one finger moves the pointer, a tap is a left click, a two-finger tap is a right click,
///   two fingers scroll, tap-then-hold (or a long press) drags, a three-finger tap shows the toolbar.
/// In direct mode a tap clicks where the finger is, as on a touch-screen PC.
final class MetalCanvasUIView: UIView, UIKeyInput {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// false: trackpad (relative pointer). true: direct touch (absolute).
    var directTouch: Bool = false
    var onThreeFingerTap: (() -> Void)?
    var onKeyboardDismissed: (() -> Void)?
    /// A hardware keyboard (Magic Keyboard, Bluetooth, USB) is attached: its keys go straight to
    /// Windows, and the on-screen key row is not shown.
    var hardwareKeyboard: Bool = false {
        didSet {
            guard oldValue != hardwareKeyboard else { return }
            if isFirstResponder { reloadInputViews() }
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

    // MARK: keyboard state
    private var stickyModifiers: Set<UInt8> = []
    private lazy var accessoryBar = KeyAccessoryBar(owner: self)

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
    }

    private func updateDrawableScale() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        let w = max(1.0, bounds.width * scale)
        let h = max(1.0, bounds.height * scale)
        metalLayer.drawableSize = CGSize(width: w, height: h)
        if let winBounds = window?.bounds.size, winBounds.width > 0 {
            WinIOSBridge.shared.updateScreenSize(winBounds, scale: scale)
        }
        // While the on-screen keyboard is up the view is shorter: do not ask Windows to change
        // resolution for that.
        if bounds.width > 0 && bounds.height > 0 && !isFirstResponder {
            WinIOSBridge.shared.updateDisplayViewSize(bounds.size)
        }
    }

    private func normalizedPoint(for pt: CGPoint) -> (Double, Double) {
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
        // An attached mouse or trackpad clicking: absolute position, the button it pressed.
        let pointerTouches = touches.filter { $0.type == .indirectPointer }
        if let t = pointerTouches.first {
            let (nx, ny) = normalizedPoint(for: t.location(in: self))
            pointerButtons = (event?.buttonMask.contains(.secondary) ?? false) ? 2 : 1
            PointerController.shared.moveAbsolute(x: nx, y: ny, extraButtons: pointerButtons)
        }
        let newFingers = touches.filter { $0.type != .indirectPointer }
        guard !newFingers.isEmpty else { return }

        let now = CACurrentMediaTime()
        if fingers.isEmpty {
            gestureStart = now
            maxFingers = 0
            travelled = 0
            scrollAccum = 0
            consumed = false
            dragging = false
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
        lastCentroid = centroid()
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
                PointerController.shared.moveRelative(dxPoints: dx, dyPoints: dy,
                                                      padWidth: bounds.width, padHeight: bounds.height)
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
        guard before > 0, fingers.isEmpty else {
            if !fingers.isEmpty { lastCentroid = centroid() }
            return
        }
        cancelLongPress()
        let now = CACurrentMediaTime()
        let wasTap = !cancelled && travelled <= tapSlop && (now - gestureStart) <= tapMaxDuration

        if dragging {
            dragging = false
            PointerController.shared.setHeldButton(1, down: false)
            lastTapEnd = 0
            return
        }
        guard wasTap, !consumed else { return }
        switch maxFingers {
        case 1:
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
            onThreeFingerTap?()
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
    override var inputAccessoryView: UIView? { hardwareKeyboard ? nil : accessoryBar }
    var hasText: Bool { true }

    // UITextInputTraits: Windows gets exactly what is typed.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r {
            releaseStickyModifiers()
            releaseAllKeys()
            setNeedsLayout()
        }
        return r
    }

    func insertText(_ text: String) {
        for ch in text {
            guard let (usage, shift) = Self.asciiToHID(ch) else { continue }
            sendKey(usage, withShift: shift)
        }
    }

    func deleteBackward() {
        sendKey(0x2a, withShift: false) // Backspace
    }

    /// One key press with the sticky modifiers (Ctrl/Alt/Win/Shift from the bar above the keyboard).
    func sendKey(_ usage: UInt8, withShift shift: Bool) {
        var mods = Array(stickyModifiers)
        if shift && !mods.contains(0xe1) { mods.append(0xe1) }
        if mods.isEmpty {
            WinIOSBridge.shared.tapKeyHid(usage)
        } else {
            WinIOSBridge.shared.sendKeyCombo(withModifiers: mods.map { NSNumber(value: $0) }, key: usage)
        }
        releaseStickyModifiers()
    }

    func toggleStickyModifier(_ usage: UInt8) -> Bool {
        if stickyModifiers.contains(usage) {
            stickyModifiers.remove(usage)
            return false
        }
        stickyModifiers.insert(usage)
        return true
    }

    private func releaseStickyModifiers() {
        guard !stickyModifiers.isEmpty else { return }
        stickyModifiers.removeAll()
        accessoryBar.clearModifierHighlights()
    }

    func dismissKeyboard() {
        resignFirstResponder()
        onKeyboardDismissed?()
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

/// The row above the system keyboard: the keys an iOS keyboard lacks. Ctrl, Alt, Win and Shift are
/// sticky: tap one (it lights up), then the key it should combine with.
final class KeyAccessoryBar: UIInputView {
    private weak var owner: MetalCanvasUIView?
    private var modifierButtons: [UIButton] = []

    private struct Key {
        let title: String
        let usage: UInt8
        let modifier: Bool
    }

    private static let keys: [Key] = [
        Key(title: "Esc", usage: 0x29, modifier: false), Key(title: "Tab", usage: 0x2b, modifier: false),
        Key(title: "Ctrl", usage: 0xe0, modifier: true), Key(title: "Alt", usage: 0xe2, modifier: true),
        Key(title: "Win", usage: 0xe3, modifier: true), Key(title: "Shift", usage: 0xe1, modifier: true),
        Key(title: "←", usage: 0x50, modifier: false), Key(title: "↓", usage: 0x51, modifier: false),
        Key(title: "↑", usage: 0x52, modifier: false), Key(title: "→", usage: 0x4f, modifier: false),
        Key(title: "Del", usage: 0x4c, modifier: false), Key(title: "Home", usage: 0x4a, modifier: false),
        Key(title: "End", usage: 0x4d, modifier: false), Key(title: "PgUp", usage: 0x4b, modifier: false),
        Key(title: "PgDn", usage: 0x4e, modifier: false),
        Key(title: "F1", usage: 0x3a, modifier: false), Key(title: "F2", usage: 0x3b, modifier: false),
        Key(title: "F3", usage: 0x3c, modifier: false), Key(title: "F4", usage: 0x3d, modifier: false),
        Key(title: "F5", usage: 0x3e, modifier: false), Key(title: "F6", usage: 0x3f, modifier: false),
        Key(title: "F7", usage: 0x40, modifier: false), Key(title: "F8", usage: 0x41, modifier: false),
        Key(title: "F9", usage: 0x42, modifier: false), Key(title: "F10", usage: 0x43, modifier: false),
        Key(title: "F11", usage: 0x44, modifier: false), Key(title: "F12", usage: 0x45, modifier: false),
    ]

    init(owner: MetalCanvasUIView) {
        self.owner = owner
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let hide = makeButton(title: nil, symbol: "keyboard.chevron.compact.down")
        hide.addTarget(self, action: #selector(hideTapped), for: .touchUpInside)
        hide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hide)
        addSubview(scroll)

        for (i, k) in Self.keys.enumerated() {
            let b = makeButton(title: k.title, symbol: nil)
            b.tag = i
            b.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(b)
            if k.modifier { modifierButtons.append(b) }
        }

        NSLayoutConstraint.activate([
            hide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            hide.widthAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeButton(title: String?, symbol: String?) -> UIButton {
        var cfg = UIButton.Configuration.gray()
        cfg.title = title
        if let symbol { cfg.image = UIImage(systemName: symbol) }
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11)
        cfg.cornerStyle = .medium
        cfg.baseForegroundColor = .label
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 15, weight: .medium)
            return a
        }
        return UIButton(configuration: cfg)
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let owner else { return }
        let k = Self.keys[sender.tag]
        UIDevice.current.playInputClick()
        if k.modifier {
            let on = owner.toggleStickyModifier(k.usage)
            setHighlighted(sender, on)
        } else {
            owner.sendKey(k.usage, withShift: false)
        }
    }

    private func setHighlighted(_ b: UIButton, _ on: Bool) {
        var cfg = on ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        cfg.title = b.configuration?.title
        cfg.contentInsets = b.configuration?.contentInsets ?? .zero
        cfg.cornerStyle = .medium
        cfg.baseForegroundColor = on ? .white : .label
        cfg.titleTextAttributesTransformer = b.configuration?.titleTextAttributesTransformer
        b.configuration = cfg
    }

    func clearModifierHighlights() {
        for b in modifierButtons { setHighlighted(b, false) }
    }

    @objc private func hideTapped() {
        owner?.dismissKeyboard()
    }
}

extension KeyAccessoryBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

struct MetalDisplayView: UIViewRepresentable {
    @Binding var directTouch: Bool
    @Binding var keyboardVisible: Bool
    /// A hardware keyboard is attached: keep the keyboard focus on Windows by itself.
    var hardwareKeyboard: Bool
    /// False while a sheet (settings, Safari) needs the keyboard.
    var focusAllowed: Bool
    var onThreeFingerTap: () -> Void

    func makeUIView(context: Context) -> MetalCanvasUIView {
        let view = MetalCanvasUIView(frame: .zero)
        view.onThreeFingerTap = onThreeFingerTap
        view.onKeyboardDismissed = {
            DispatchQueue.main.async { self.keyboardVisible = false }
        }
        return view
    }

    func updateUIView(_ uiView: MetalCanvasUIView, context: Context) {
        uiView.directTouch = directTouch
        uiView.hardwareKeyboard = hardwareKeyboard
        uiView.onThreeFingerTap = onThreeFingerTap
        let wantsFocus = focusAllowed && (keyboardVisible || hardwareKeyboard)
        if wantsFocus && !uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.becomeFirstResponder() }
        } else if !wantsFocus && uiView.isFirstResponder {
            DispatchQueue.main.async { _ = uiView.resignFirstResponder() }
        }
    }
}
