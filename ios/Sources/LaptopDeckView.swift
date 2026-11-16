// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import SwiftUI
import UIKit

// MARK: - The deck's look (ours: charcoal keys on a near-black deck, one accent for "on")

enum DeckPalette {
    static let deckTop = Color(white: 0.085)
    static let deckBottom = Color(white: 0.055)
    static let well = Color(white: 0.035)
    static let key = Color(white: 0.155)
    static let keyPressed = Color(white: 0.30)
    static let keyLatched = Color.accentColor.opacity(0.42)
    static let edge = Color.white.opacity(0.09)
    static let edgeActive = Color.accentColor.opacity(0.85)
    static let legend = Color.white.opacity(0.92)
    static let legendDim = Color.white.opacity(0.5)
    static let pad = Color(white: 0.115)
    static let roundButton = Color(white: 0.15)
}

// MARK: - Precision Haptic Matte-Glass Touchpad (UIKit 120Hz + Invisible Bottom-Corner Click Zones)

final class TrackpadGlassUIView: UIView {
    var onActivityChanged: ((Bool) -> Void)?
    var onCornerClickState: ((Int) -> Void)? // 0 = none, 1 = left held, 2 = right held
    /// F8 armed a right click: the next tap on the pad is one (the Windows screen takes it too).
    var rightClickArmed: Bool = false
    var onRightClickConsumed: (() -> Void)?

    private var panLast: CGPoint = .zero
    private var scrollAccum: CGFloat = 0
    private var lastTapEndedTime: CFTimeInterval = 0
    private var tapDragActive: Bool = false
    private weak var heldCornerTouch: UITouch?
    private var heldCornerButton: UInt8 = 0

    private let clickHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let releaseHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let rightHaptic = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(onSingleTap(_:)))
        singleTap.numberOfTouchesRequired = 1
        singleTap.cancelsTouchesInView = false
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.cancelsTouchesInView = false
        addGestureRecognizer(twoFingerTap)

        let movePan = UIPanGestureRecognizer(target: self, action: #selector(onOneFingerPan(_:)))
        movePan.minimumNumberOfTouches = 1
        movePan.maximumNumberOfTouches = 1
        movePan.cancelsTouchesInView = false
        addGestureRecognizer(movePan)

        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        scrollPan.cancelsTouchesInView = false
        if #available(iOS 13.4, *) {
            scrollPan.allowedScrollTypesMask = .all
        }
        addGestureRecognizer(scrollPan)

        NotificationCenter.default.addObserver(self, selector: #selector(displayWillReshape),
                                               name: .WinIOSDisplayWillReshape, object: nil)
    }

    /// Windows is about to take a new size and the bridge lifted every button: a held corner or a
    /// tap-drag in progress ends here (the finger does nothing more until it lifts).
    @objc private func displayWillReshape() {
        if heldCornerTouch != nil || heldCornerButton != 0 {
            heldCornerTouch = nil
            heldCornerButton = 0
            onCornerClickState?(0)
        }
        tapDragActive = false
        PointerController.shared.forgetHeldButtons()
    }

    // Invisible bottom-left (hold-drag) & bottom-right (right-click) zones of the trackpad
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        WinIOSBridge.shared.noteUserInput() // the display goes back to its full frame rate now
        guard heldCornerTouch == nil, bounds.height > 20, bounds.width > 40 else { return }
        for t in touches {
            let p = t.location(in: self)
            if p.y >= bounds.height * 0.74 {
                if p.x <= bounds.width * 0.28 {
                    heldCornerTouch = t
                    heldCornerButton = 1
                    clickHaptic.impactOccurred(intensity: 0.72)
                    PointerController.shared.setHeldButton(1, down: true)
                    onCornerClickState?(1)
                    break
                } else if p.x >= bounds.width * 0.72 {
                    heldCornerTouch = t
                    heldCornerButton = 2
                    rightHaptic.impactOccurred(intensity: 0.78)
                    PointerController.shared.setHeldButton(2, down: true)
                    onCornerClickState?(2)
                    break
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        releaseCornerIfNeeded(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        releaseCornerIfNeeded(touches)
    }

    private func releaseCornerIfNeeded(_ touches: Set<UITouch>) {
        if let held = heldCornerTouch, touches.contains(held) {
            let btn = heldCornerButton
            heldCornerTouch = nil
            heldCornerButton = 0
            releaseHaptic.impactOccurred(intensity: 0.35)
            PointerController.shared.setHeldButton(btn, down: false)
            onCornerClickState?(0)
        }
    }

    @objc private func onSingleTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        let p = gr.location(in: self)
        // Bottom-right haptic corner tap acts as crisp Right-Click!
        if p.y >= bounds.height * 0.74 && p.x >= bounds.width * 0.72 {
            rightHaptic.impactOccurred(intensity: 0.75)
            PointerController.shared.clickAtCurrent(buttonMask: 2)
            return
        }
        if rightClickArmed {
            rightClickArmed = false
            onRightClickConsumed?()
            rightHaptic.impactOccurred(intensity: 0.75)
            PointerController.shared.clickAtCurrent(buttonMask: 2)
            return
        }
        lastTapEndedTime = CACurrentMediaTime()
        clickHaptic.impactOccurred(intensity: 0.55)
        PointerController.shared.clickAtCurrent(buttonMask: 1)
    }

    @objc private func onTwoFingerTap(_ gr: UITapGestureRecognizer) {
        guard gr.state == .ended else { return }
        rightHaptic.impactOccurred(intensity: 0.75)
        PointerController.shared.clickAtCurrent(buttonMask: 2)
    }

    @objc private func onOneFingerPan(_ gr: UIPanGestureRecognizer) {
        let loc = gr.location(in: self)
        switch gr.state {
        case .began:
            panLast = loc
            onActivityChanged?(true)
            if CACurrentMediaTime() - lastTapEndedTime < 0.28 {
                tapDragActive = true
                clickHaptic.impactOccurred(intensity: 0.45)
                PointerController.shared.setHeldButton(1, down: true)
            }
        case .changed:
            let dx = loc.x - panLast.x
            let dy = loc.y - panLast.y
            panLast = loc
            PointerController.shared.moveRelative(
                dxPoints: dx,
                dyPoints: dy,
                padWidth: bounds.width,
                padHeight: bounds.height
            )
        case .ended, .cancelled, .failed:
            if tapDragActive {
                tapDragActive = false
                PointerController.shared.setHeldButton(1, down: false)
            }
            onActivityChanged?(false)
        default:
            break
        }
    }

    @objc private func onTwoFingerPan(_ gr: UIPanGestureRecognizer) {
        let trans = gr.translation(in: self)
        switch gr.state {
        case .began:
            scrollAccum = 0
            onActivityChanged?(true)
        case .changed:
            let delta = trans.y - scrollAccum
            if abs(delta) >= 10 {
                let steps = Int(delta / 10)
                scrollAccum += CGFloat(steps) * 10
                let clamped = Int8(clamping: max(-8, min(8, steps)))
                PointerController.shared.scroll(steps: clamped)
            }
        case .ended, .cancelled, .failed:
            onActivityChanged?(false)
        default:
            break
        }
    }
}

struct TrackpadGlassRepresentable: UIViewRepresentable {
    @Binding var isTouching: Bool
    @Binding var cornerClickState: Int
    @Binding var rightClickArmed: Bool

    func makeUIView(context: Context) -> TrackpadGlassUIView {
        let v = TrackpadGlassUIView(frame: .zero)
        v.onActivityChanged = { active in
            DispatchQueue.main.async { self.isTouching = active }
        }
        v.onCornerClickState = { state in
            DispatchQueue.main.async { self.cornerClickState = state }
        }
        return v
    }

    func updateUIView(_ uiView: TrackpadGlassUIView, context: Context) {
        uiView.rightClickArmed = rightClickArmed
        uiView.onRightClickConsumed = {
            DispatchQueue.main.async { self.rightClickArmed = false }
        }
    }
}

// MARK: - The 6-row keyboard model

private enum FunctionAction: Equatable {
    case escape
    case startMenu
    case search
    case explorer
    case edgeBrowser
    case claudeCode
    case paintApp
    case taskManager
    case altTab
    case showDesktop
    case rightClickArm
    case dragLockToggle
    case cycleDeckLayout
    case rotateScreen
    case openStudioMode
    case acpiPower
    case forwardDelete
    // the action row (P1-5)
    case taskView
    case snapLayouts
    case undo
    case redo
    case quickSettings
    case shortcutsMenu
    case keyboardToggle

    /// Runs something inside Windows (Win+R or the WinKit helper): on Arch Linux the key is its F key.
    var isWindowsOnly: Bool { self == .edgeBrowser || self == .claudeCode || self == .paintApp }
}

private enum KeyRole: Equatable {
    case functionKey(action: FunctionAction, fnHid: UInt8?, fnTag: String?, symbol: String?, text: String?)
    case regular(hid: UInt8, primary: String, shifted: String?, fnHid: UInt8?, fnLabel: String?, homing: Bool)
    case modifier(hid: UInt8, label: String, isWindowsKey: Bool)
    case capsLock
    case fnToggle
    case upDownStack // half-height Up / Down arrow pair
}

private struct LaptopKeySpec: Identifiable {
    let id: String
    let widthWeight: CGFloat
    let role: KeyRole

    static func fnKey(
        _ id: String,
        action: FunctionAction,
        fnHid: UInt8? = nil,
        fnTag: String? = nil,
        symbol: String? = nil,
        text: String? = nil,
        w: CGFloat = 1.0
    ) -> LaptopKeySpec {
        LaptopKeySpec(id: id, widthWeight: w, role: .functionKey(action: action, fnHid: fnHid, fnTag: fnTag, symbol: symbol, text: text))
    }

    static func key(
        _ primary: String,
        shifted: String? = nil,
        hid: UInt8,
        w: CGFloat = 1.0,
        fnHid: UInt8? = nil,
        fnLabel: String? = nil,
        homing: Bool = false
    ) -> LaptopKeySpec {
        LaptopKeySpec(
            id: "\(primary)_\(hid)",
            widthWeight: w,
            role: .regular(hid: hid, primary: primary, shifted: shifted, fnHid: fnHid, fnLabel: fnLabel, homing: homing)
        )
    }

    static func mod(_ id: String, label: String, isWindowsKey: Bool = false, hid: UInt8, w: CGFloat) -> LaptopKeySpec {
        LaptopKeySpec(id: id, widthWeight: w, role: .modifier(hid: hid, label: label, isWindowsKey: isWindowsKey))
    }
}

// MARK: - The laptop deck (below the fold)

struct LaptopDeckView: View {
    @ObservedObject var vm: VMViewModel
    /// More > Power… (the session view asks first).
    var showPower: () -> Void = {}

    @State private var shiftLatched: Bool = false
    @State private var ctrlLatched: Bool = false
    @State private var altLatched: Bool = false
    @State private var winLatched: Bool = false
    @State private var capsLocked: Bool = false
    @State private var fnActive: Bool = false

    @State private var dragLocked: Bool = false
    @State private var padTouching: Bool = false
    @State private var cornerClickState: Int = 0

    private let keyDownHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let keyUpHaptic = UIImpactFeedbackGenerator(style: .soft)

    // Row 0: the action row (Windows navigation instead of F keys; Fn brings F1–F12 back). The app
    // launchers, right click, drag lock and rotate are in the More button beside the trackpad.
    private static let functionRow: [LaptopKeySpec] = [
        .fnKey("esc",   action: .escape,          text: "Esc", w: 1.08),
        .fnKey("f1",    action: .startMenu,       fnHid: 0x3a, fnTag: "F1", symbol: "square.grid.2x2"),
        .fnKey("f2",    action: .search,          fnHid: 0x3b, fnTag: "F2", symbol: "magnifyingglass"),
        .fnKey("f3",    action: .taskView,        fnHid: 0x3c, fnTag: "F3", symbol: "rectangle.on.rectangle"),
        .fnKey("f4",    action: .snapLayouts,     fnHid: 0x3d, fnTag: "F4", symbol: "rectangle.split.2x1"),
        .fnKey("f5",    action: .undo,            fnHid: 0x3e, fnTag: "F5", symbol: "arrow.uturn.backward"),
        .fnKey("f6",    action: .redo,            fnHid: 0x3f, fnTag: "F6", symbol: "arrow.uturn.forward"),
        .fnKey("f7",    action: .showDesktop,     fnHid: 0x40, fnTag: "F7", symbol: "menubar.dock.rectangle"),
        .fnKey("f8",    action: .shortcutsMenu,   fnHid: 0x41, fnTag: "F8", symbol: "keyboard.badge.ellipsis"),
        .fnKey("f9",    action: .quickSettings,   fnHid: 0x42, fnTag: "F9", symbol: "switch.2"),
        .fnKey("f10",   action: .explorer,        fnHid: 0x43, fnTag: "F10", symbol: "folder"),
        .fnKey("f11",   action: .keyboardToggle,  fnHid: 0x44, fnTag: "F11", symbol: "keyboard"),
        .fnKey("f12",   action: .openStudioMode,  fnHid: 0x45, fnTag: "F12", symbol: "arrow.up.left.and.arrow.down.right"),
        .fnKey("del",   action: .forwardDelete,   text: "Del", w: 1.15),
    ]

    // Rows 1–5: ANSI layout with inverted-T arrows (stacked Up/Down)
    private static let mainRows: [[LaptopKeySpec]] = [
        // Row 1: Number row
        [
            .key("`", shifted: "~", hid: 0x35),
            .key("1", shifted: "!", hid: 0x1e),
            .key("2", shifted: "@", hid: 0x1f),
            .key("3", shifted: "#", hid: 0x20),
            .key("4", shifted: "$", hid: 0x21),
            .key("5", shifted: "%", hid: 0x22),
            .key("6", shifted: "^", hid: 0x23),
            .key("7", shifted: "&", hid: 0x24),
            .key("8", shifted: "*", hid: 0x25),
            .key("9", shifted: "(", hid: 0x26),
            .key("0", shifted: ")", hid: 0x27),
            .key("-", shifted: "_", hid: 0x2d),
            .key("=", shifted: "+", hid: 0x2e),
            .key("Backspace", hid: 0x2a, w: 1.65),
        ],
        // Row 2: QWERTY
        [
            .key("Tab", hid: 0x2b, w: 1.48),
            .key("q", shifted: "Q", hid: 0x14),
            .key("w", shifted: "W", hid: 0x1a),
            .key("e", shifted: "E", hid: 0x08),
            .key("r", shifted: "R", hid: 0x15),
            .key("t", shifted: "T", hid: 0x17),
            .key("y", shifted: "Y", hid: 0x1c),
            .key("u", shifted: "U", hid: 0x18),
            .key("i", shifted: "I", hid: 0x0c),
            .key("o", shifted: "O", hid: 0x12),
            .key("p", shifted: "P", hid: 0x13),
            .key("[", shifted: "{", hid: 0x2f),
            .key("]", shifted: "}", hid: 0x30),
            .key("\\", shifted: "|", hid: 0x31, w: 1.17),
        ],
        // Row 3: Home row
        [
            LaptopKeySpec(id: "caps", widthWeight: 1.75, role: .capsLock),
            .key("a", shifted: "A", hid: 0x04),
            .key("s", shifted: "S", hid: 0x16),
            .key("d", shifted: "D", hid: 0x07),
            .key("f", shifted: "F", hid: 0x09, homing: true),
            .key("g", shifted: "G", hid: 0x0a),
            .key("h", shifted: "H", hid: 0x0b),
            .key("j", shifted: "J", hid: 0x0d, homing: true),
            .key("k", shifted: "K", hid: 0x0e),
            .key("l", shifted: "L", hid: 0x0f),
            .key(";", shifted: ":", hid: 0x33),
            .key("'", shifted: "\"", hid: 0x34),
            .key("Enter", hid: 0x28, w: 1.90),
        ],
        // Row 4: Shift row (both Shifts)
        [
            .mod("lshift", label: "Shift", hid: 0xe1, w: 2.22),
            .key("z", shifted: "Z", hid: 0x1d),
            .key("x", shifted: "X", hid: 0x1b),
            .key("c", shifted: "C", hid: 0x06),
            .key("v", shifted: "V", hid: 0x19),
            .key("b", shifted: "B", hid: 0x05),
            .key("n", shifted: "N", hid: 0x11),
            .key("m", shifted: "M", hid: 0x10),
            .key(",", shifted: "<", hid: 0x36),
            .key(".", shifted: ">", hid: 0x37),
            .key("/", shifted: "?", hid: 0x38),
            .mod("rshift", label: "Shift", hid: 0xe5, w: 2.42),
        ],
        // Row 5: modifiers, a wide spacebar and the inverted-T arrows
        [
            .mod("lctrl", label: "Ctrl", hid: 0xe0, w: 1.25),
            LaptopKeySpec(id: "fn", widthWeight: 1.10, role: .fnToggle),
            .mod("lwin", label: "Win", isWindowsKey: true, hid: 0xe3, w: 1.20),
            .mod("lalt", label: "Alt", hid: 0xe2, w: 1.20),
            .key("Space", hid: 0x2c, w: 5.35),
            .mod("ralt", label: "Alt", hid: 0xe6, w: 1.15),
            .key("←", hid: 0x50, w: 1.05, fnHid: 0x4a, fnLabel: "Home"),
            LaptopKeySpec(id: "updown", widthWeight: 1.05, role: .upDownStack),
            .key("→", hid: 0x4f, w: 1.05, fnHid: 0x4d, fnLabel: "End"),
        ],
    ]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bottomLip: CGFloat = max(6.0, geo.safeAreaInsets.bottom * 0.45)
            let bodyH = max(140.0, h - 6.0 - bottomLip)

            ZStack(alignment: .top) {
                deckBackground

                VStack(spacing: 0) {
                    switch vm.deckLayout {
                    case .split:
                        // Keyboard (action row on top), then the trackpad with its round buttons.
                        let kbdH = max(142.0, bodyH * 0.625)
                        let padH = max(64.0, bodyH - kbdH - 12.0)
                        VStack(spacing: 8) {
                            recessedSurfaceKeyboardWell(height: kbdH)
                                .frame(height: kbdH)
                                .padding(.horizontal, 10)

                            trackpadRow(width: w, height: padH, expanded: false)
                                .frame(height: padH)
                        }

                    case .trackpad:
                        // Keyboard off: the action row stays, the trackpad takes the rest.
                        let rowH: CGFloat = 30
                        VStack(spacing: 8) {
                            keyboardRowView(row: Self.functionRow, rowHeight: rowH - 8, isFunctionStrip: true)
                                .frame(height: rowH - 8)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 4)
                                .background(DeckPalette.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(.horizontal, 10)

                            trackpadRow(width: w, height: bodyH - rowH - 14.0, expanded: true)
                                .frame(height: bodyH - rowH - 14.0)
                        }

                    case .keyboard:
                        recessedSurfaceKeyboardWell(height: bodyH - 10.0)
                            .frame(height: bodyH - 10.0)
                            .padding(.horizontal, 10)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, 6)
            }
            .frame(width: w, height: h)
        }
        .onDisappear {
            // Leaving Laptop (or the deck going away): a modifier the deck pressed must not stay down
            // in Windows. Each held keycap sends its own key-up in its onDisappear.
            releaseLatchedModifiers()
            // F9's drag lock holds the left button in the shared PointerController; this view's
            // state goes away with the deck, so let the button up or Studio would drag on every touch.
            if dragLocked {
                dragLocked = false
                PointerController.shared.setHeldButton(1, down: false)
            }
        }
        // Windows takes a new size: the bridge lifted every button, so F9's drag lock is off too.
        .onReceive(NotificationCenter.default.publisher(for: .WinIOSDisplayWillReshape)) { _ in
            dragLocked = false
        }
    }

    // MARK: - Deck background

    private var deckBackground: some View {
        LinearGradient(colors: [DeckPalette.deckTop, DeckPalette.deckBottom], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                // where the fold is: a hairline, nothing more
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
            }
    }

    /// The trackpad between its round buttons: Sound and drag lock on the left, Clipboard and More
    /// on the right (P1-5), so none of them sits on the pad.
    private func trackpadRow(width: CGFloat, height: CGFloat, expanded: Bool) -> some View {
        let button = min(44.0, max(32.0, (height - 10) / 2))
        let side = button + 22
        return HStack(spacing: 0) {
            VStack(spacing: 10) {
                SoundMenu(style: .round(button))
                Button {
                    performFunctionAction(.dragLockToggle)
                } label: {
                    Image(systemName: dragLocked ? "hand.draw.fill" : "hand.draw")
                        .font(.system(size: button * 0.38, weight: .medium))
                        .foregroundStyle(dragLocked ? Color.white : DeckPalette.legend)
                        .frame(width: button, height: button)
                        .background(dragLocked ? DeckPalette.keyLatched : DeckPalette.roundButton, in: Circle())
                        .overlay(Circle().strokeBorder(dragLocked ? DeckPalette.edgeActive : DeckPalette.edge))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("拖动锁定", "Drag lock"))
                .accessibilityAddTraits(dragLocked ? .isSelected : [])
            }
            .frame(width: side)

            flushSurfaceHapticTouchpad(width: width - side * 2, height: height, expanded: expanded)

            VStack(spacing: 10) {
                ClipboardMenu(style: .round(button))
                SessionMoreMenu(vm: vm, chrome: ChromeModel.shared, deckExtras: true, showPower: showPower,
                                rightClickArmed: $vm.rightClickArmed,
                                dragLocked: Binding(get: { dragLocked },
                                                    set: { if $0 != dragLocked { performFunctionAction(.dragLockToggle) } }),
                                style: .round(button))
            }
            .frame(width: side)
        }
    }

    // MARK: - Keyboard well

    private func recessedSurfaceKeyboardWell(height: CGFloat) -> some View {
        let spacingV: CGFloat = 3.2
        let padV: CGFloat = 5.0
        let availRowsH = max(110.0, height - padV * 2 - spacingV * 5)
        // Row 0 (the action row) is 0.68x height; rows 1..5 are 1.0x
        let unitH = availRowsH / 5.68
        let fnRowH = max(16.5, unitH * 0.68)
        let stdRowH = max(21.0, unitH)

        return VStack(spacing: spacingV) {
            // Row 0: the action row
            keyboardRowView(row: Self.functionRow, rowHeight: fnRowH, isFunctionStrip: true)
                .frame(height: fnRowH)

            // Rows 1..5: Main Chiclet Matrix
            ForEach(0..<Self.mainRows.count, id: \.self) { idx in
                keyboardRowView(row: Self.mainRows[idx], rowHeight: stdRowH, isFunctionStrip: false)
                    .frame(height: stdRowH)
            }
        }
        .padding(.horizontal, 5.5)
        .padding(.vertical, padV)
        .background(DeckPalette.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func keyboardRowView(row: [LaptopKeySpec], rowHeight: CGFloat, isFunctionStrip: Bool) -> some View {
        GeometryReader { rowGeo in
            let totalWeight = row.reduce(CGFloat(0)) { $0 + $1.widthWeight }
            let spacingH: CGFloat = 3.2
            let availW = max(10.0, rowGeo.size.width - spacingH * CGFloat(max(0, row.count - 1)))

            HStack(spacing: spacingH) {
                ForEach(row) { spec in
                    let kw = availW * (spec.widthWeight / totalWeight)
                    if spec.role == .upDownStack {
                        SurfaceStackedArrowView(
                            isFnActive: fnActive,
                            onTapArrow: { up in
                                keyDownHaptic.impactOccurred(intensity: 0.68)
                                let code: UInt8 = up ? (fnActive ? 0x4b : 0x52) : (fnActive ? 0x4e : 0x51)
                                sendModifiedTap(code)
                            }
                        )
                        .frame(width: kw, height: rowHeight)
                    } else if isShortcutsKey(spec) && !fnActive {
                        // a menu, not a key: the Shortcuts palette (with Fn it is F8 again)
                        ShortcutsMenu(vm: vm, style: .key)
                            .frame(width: kw, height: rowHeight)
                    } else {
                        SurfaceKeycapView(
                            spec: spec,
                            isFunctionStrip: isFunctionStrip,
                            isShiftActive: shiftLatched || capsLocked,
                            isLatchedOrLED: isKeyLEDLit(spec),
                            isFnActive: fnActive || showsPlainFunctionKey(spec),
                            onKeyDown: { handleKeyDown(spec, viewportWidth: rowGeo.size.width) },
                            onKeyUp: { handleKeyUp(spec) }
                        )
                        .frame(width: kw, height: rowHeight)
                    }
                }
            }
        }
    }

    private func isKeyLEDLit(_ spec: LaptopKeySpec) -> Bool {
        switch spec.role {
        case .capsLock:
            return capsLocked
        case .fnToggle:
            return fnActive
        case .modifier(let hid, _, _):
            switch hid {
            case 0xe1, 0xe5: return shiftLatched
            case 0xe0: return ctrlLatched
            case 0xe2, 0xe6: return altLatched
            case 0xe3: return winLatched
            default: return false
            }
        case .functionKey(let action, _, _, _, _):
            switch action {
            case .rightClickArm: return vm.rightClickArmed
            case .dragLockToggle: return dragLocked
            case .cycleDeckLayout: return vm.deckLayout != .split
            case .keyboardToggle: return vm.deckLayout == .trackpad
            default: return false
            }
        case .regular, .upDownStack:
            return false
        }
    }

    private func isShortcutsKey(_ spec: LaptopKeySpec) -> Bool {
        if case .functionKey(.shortcutsMenu, _, _, _, _) = spec.role { return true }
        return false
    }

    /// On Arch Linux the keys that run something inside Windows are plain F keys, and say so.
    private func showsPlainFunctionKey(_ spec: LaptopKeySpec) -> Bool {
        if case .functionKey(let action, _, _, _, _) = spec.role { return vm.isLinux && action.isWindowsOnly }
        return false
    }

    private func sendModifiedTap(_ hid: UInt8) {
        if ctrlLatched { WinIOSBridge.shared.sendKeyHid(0xe0, down: true) }
        if altLatched  { WinIOSBridge.shared.sendKeyHid(0xe2, down: true) }
        if winLatched  { WinIOSBridge.shared.sendKeyHid(0xe3, down: true) }
        if shiftLatched { WinIOSBridge.shared.sendKeyHid(0xe1, down: true) }
        WinIOSBridge.shared.tapKeyHid(hid)
        releaseLatchedModifiers()
    }

    private func releaseLatchedModifiers() {
        if shiftLatched { WinIOSBridge.shared.sendKeyHid(0xe1, down: false); shiftLatched = false }
        if ctrlLatched  { WinIOSBridge.shared.sendKeyHid(0xe0, down: false); ctrlLatched = false }
        if altLatched   { WinIOSBridge.shared.sendKeyHid(0xe2, down: false); altLatched = false }
        if winLatched   { WinIOSBridge.shared.sendKeyHid(0xe3, down: false); winLatched = false }
    }

    private func handleKeyDown(_ spec: LaptopKeySpec, viewportWidth: CGFloat) {
        keyDownHaptic.impactOccurred(intensity: 0.7)
        switch spec.role {
        case .capsLock:
            capsLocked.toggle()
            WinIOSBridge.shared.tapKeyHid(0x39)

        case .fnToggle:
            fnActive.toggle()

        case .modifier(let hid, _, _):
            toggleModifierLatch(hid: hid)

        case .functionKey(let action, let fnHid, _, _, _):
            if fnActive || (vm.isLinux && action.isWindowsOnly), let fnHid {
                sendModifiedTap(fnHid)
                return
            }
            performFunctionAction(action)

        case .regular(let hid, _, _, let fnHid, _, _):
            let actualHid = (fnActive && fnHid != nil) ? fnHid! : hid
            if ctrlLatched { WinIOSBridge.shared.sendKeyHid(0xe0, down: true) }
            if altLatched  { WinIOSBridge.shared.sendKeyHid(0xe2, down: true) }
            if winLatched  { WinIOSBridge.shared.sendKeyHid(0xe3, down: true) }
            if shiftLatched { WinIOSBridge.shared.sendKeyHid(0xe1, down: true) }
            WinIOSBridge.shared.sendKeyHid(actualHid, down: true)

        case .upDownStack:
            break
        }
    }

    private func handleKeyUp(_ spec: LaptopKeySpec) {
        switch spec.role {
        case .regular(let hid, _, _, let fnHid, _, _):
            keyUpHaptic.impactOccurred(intensity: 0.22)
            let actualHid = (fnActive && fnHid != nil) ? fnHid! : hid
            WinIOSBridge.shared.sendKeyHid(actualHid, down: false)
            releaseLatchedModifiers()
        case .functionKey(let action, _, _, _, _) where action == .forwardDelete:
            keyUpHaptic.impactOccurred(intensity: 0.22)
        default:
            break
        }
    }

    private func performFunctionAction(_ action: FunctionAction) {
        switch action {
        case .escape:
            WinIOSBridge.shared.sendEscape()
        case .startMenu:
            WinIOSBridge.shared.sendWindowsKey()
        case .search:
            WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x16) // Win+S
        case .explorer:
            WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x08) // Win+E
        case .edgeBrowser:
            vm.launchGuestEdgeBrowser()
        case .claudeCode:
            vm.installClaudeCode()
        case .paintApp:
            vm.launchGuestPaint()
        case .taskManager:
            WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe0), NSNumber(value: 0xe1)], key: 0x29)
        case .altTab:
            WinIOSBridge.shared.sendAltTab()
        case .showDesktop:
            WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x07) // Win+D
        case .rightClickArm:
            vm.rightClickArmed.toggle()
        case .dragLockToggle:
            dragLocked.toggle()
            PointerController.shared.setHeldButton(1, down: dragLocked)
        case .cycleDeckLayout:
            withAnimation(.snappy(duration: 0.2)) {
                vm.deckLayout = vm.deckLayout.next
            }
        case .rotateScreen:
            SceneOrientationController.rotateDeckOrientation()
        case .openStudioMode:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                vm.postureMode = .fullScreen
            }
        case .acpiPower:
            WinIOSBridge.shared.pressPowerButton()
        case .forwardDelete:
            WinIOSBridge.shared.tapKeyHid(0x4c)
        case .taskView:
            WinKeys.taskView()
        case .snapLayouts:
            WinKeys.snap()
        case .undo:
            WinKeys.undo()
        case .redo:
            WinKeys.redo()
        case .quickSettings:
            WinKeys.quickSettings()
        case .shortcutsMenu:
            break // drawn as a menu (keyboardRowView)
        case .keyboardToggle:
            withAnimation(.snappy(duration: 0.2)) {
                vm.deckLayout = vm.deckLayout == .trackpad ? .split : .trackpad
            }
        }
    }

    private func toggleModifierLatch(hid: UInt8) {
        switch hid {
        case 0xe1, 0xe5: shiftLatched.toggle()
        case 0xe0: ctrlLatched.toggle()
        case 0xe2, 0xe6: altLatched.toggle()
        case 0xe3:
            if winLatched {
                winLatched = false
                WinIOSBridge.shared.sendWindowsKey()
            } else {
                winLatched = true
            }
        default: break
        }
    }

    // MARK: - Trackpad

    /// `width` is the room between the round buttons.
    private func flushSurfaceHapticTouchpad(width: CGFloat, height: CGFloat, expanded: Bool) -> some View {
        let padW = expanded
            ? max(160.0, width - 8.0)
            : min(max(160.0, width - 8.0), max(240.0, width * 0.78))
        let activeGlow = padTouching || cornerClickState != 0 || dragLocked

        return HStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DeckPalette.pad)

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(activeGlow ? DeckPalette.edgeActive : DeckPalette.edge,
                                  lineWidth: activeGlow ? 1.0 : 0.6)

                // which corner is held (left or right click), or the drag lock
                if cornerClickState != 0 || dragLocked {
                    HStack {
                        if cornerClickState == 1 || dragLocked {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 34, height: 2)
                        }
                        Spacer()
                        if cornerClickState == 2 {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: 34, height: 2)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 5)
                    .allowsHitTesting(false)
                }

                TrackpadGlassRepresentable(
                    isTouching: $padTouching,
                    cornerClickState: $cornerClickState,
                    rightClickArmed: $vm.rightClickArmed
                )
            }
            .frame(width: padW, height: height)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Stacked Up / Down half-height arrow pair

private struct SurfaceStackedArrowView: View {
    let isFnActive: Bool
    let onTapArrow: (Bool) -> Void

    @State private var upPressed = false
    @State private var downPressed = false

    var body: some View {
        GeometryReader { geo in
            let halfH = max(8.0, (geo.size.height - 1.8) * 0.5)
            VStack(spacing: 1.8) {
                halfArrowButton(isUp: true, pressed: $upPressed)
                    .frame(height: halfH)
                halfArrowButton(isUp: false, pressed: $downPressed)
                    .frame(height: halfH)
            }
        }
    }

    private func halfArrowButton(isUp: Bool, pressed: Binding<Bool>) -> some View {
        let cornerTop: CGFloat = isUp ? 4.5 : 1.5
        let cornerBot: CGFloat = isUp ? 1.5 : 4.5
        return ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: cornerTop,
                bottomLeadingRadius: cornerBot,
                bottomTrailingRadius: cornerBot,
                topTrailingRadius: cornerTop,
                style: .continuous
            )
            .fill(pressed.wrappedValue ? DeckPalette.keyPressed : DeckPalette.key)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: cornerTop,
                    bottomLeadingRadius: cornerBot,
                    bottomTrailingRadius: cornerBot,
                    topTrailingRadius: cornerTop,
                    style: .continuous
                )
                .strokeBorder(DeckPalette.edge, lineWidth: 0.5)
            )

            Image(systemName: isUp ? "chevron.up" : "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.90))
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed.wrappedValue {
                        pressed.wrappedValue = true
                        onTapArrow(isUp)
                    }
                }
                .onEnded { _ in
                    pressed.wrappedValue = false
                }
        )
    }
}

// MARK: - Keycap

private struct SurfaceKeycapView: View {
    let spec: LaptopKeySpec
    let isFunctionStrip: Bool
    let isShiftActive: Bool
    let isLatchedOrLED: Bool
    let isFnActive: Bool
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void

    @State private var isPressed: Bool = false
    @State private var repeater = KeyAutoRepeater()

    var body: some View {
        let radius: CGFloat = isFunctionStrip ? 3.8 : 4.6

        ZStack {
            // A charcoal key; latched keys (modifiers, Caps, Fn) take the accent colour.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isPressed ? DeckPalette.keyPressed : (isLatchedOrLED ? DeckPalette.keyLatched : DeckPalette.key))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(isLatchedOrLED ? DeckPalette.edgeActive : DeckPalette.edge, lineWidth: 0.55)
                )

            keycapLegend
        }
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        onKeyDown()
                        startAutoRepeatIfApplicable()
                    }
                }
                .onEnded { _ in
                    releaseIfPressed()
                }
        )
        // The deck can go away mid-press (unfolding flat, F12, a three-finger tap, or another deck
        // layout); the gesture then never ends, so stop the repeat and let the key up here.
        .onDisappear { releaseIfPressed() }
    }

    private func releaseIfPressed() {
        stopAutoRepeat()
        if isPressed {
            isPressed = false
            onKeyUp()
        }
    }

    @ViewBuilder
    private var keycapLegend: some View {
        let fg = DeckPalette.legend
        let subFg = DeckPalette.legendDim

        switch spec.role {
        case .functionKey(_, _, let fnTag, let symbol, let text):
            if isFnActive, let fnTag {
                Text(fnTag)
                    .font(.system(size: 9.0, weight: .semibold))
                    .foregroundStyle(fg)
            } else if let text {
                Text(text)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(fg.opacity(0.88))
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(fg.opacity(0.88))
            }

        case .capsLock:
            Text("Caps")
                .font(.system(size: 9.8, weight: .medium))
                .foregroundStyle(fg.opacity(0.90))

        case .fnToggle:
            Text("Fn")
                .font(.system(size: 9.8, weight: .medium))
                .foregroundStyle(fg.opacity(0.90))

        case .modifier(_, let label, _):
            // the Windows key says "Win": no logo marks in our chrome
            Text(label)
                .font(.system(size: 9.8, weight: .medium))
                .foregroundStyle(fg.opacity(0.90))

        case .regular(_, let primary, let shifted, _, let fnLabel, let homing):
            if isFnActive, let fnLabel {
                Text(fnLabel)
                    .font(.system(size: 9.2, weight: .semibold))
                    .foregroundStyle(fg)
            } else if primary == "Space" {
                EmptyView() // a plain spacebar
            } else if primary == "Backspace" {
                Image(systemName: "delete.left")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(fg.opacity(0.88))
            } else if primary == "←" || primary == "→" {
                Image(systemName: primary == "←" ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9.0, weight: .bold))
                    .foregroundStyle(fg.opacity(0.90))
            } else if let shifted, shifted.uppercased() != primary.uppercased() {
                VStack(spacing: 0) {
                    Text(shifted)
                        .font(.system(size: 7.8, weight: .regular))
                        .foregroundStyle(isShiftActive ? fg : subFg)
                    Text(primary)
                        .font(.system(size: 10.8, weight: .medium))
                        .foregroundStyle(isShiftActive ? subFg : fg)
                }
            } else {
                let text = (isShiftActive && shifted != nil) ? shifted! : (primary.count == 1 ? primary.uppercased() : primary)
                VStack(spacing: 1.5) {
                    Text(text)
                        .font(.system(size: primary.count > 1 ? 9.8 : 11.5, weight: .medium))
                        .foregroundStyle(fg.opacity(0.94))
                    if homing {
                        Capsule()
                            .fill(fg.opacity(0.45))
                            .frame(width: 8, height: 1.1)
                    }
                }
            }

        case .upDownStack:
            EmptyView()
        }
    }

    private func startAutoRepeatIfApplicable() {
        var repeatCode: UInt8? = nil
        switch spec.role {
        case .regular(let hid, _, _, let fnHid, _, _):
            let actual = (isFnActive && fnHid != nil) ? fnHid! : hid
            if [0x2a, 0x2c, 0x4c, 0x4f, 0x50].contains(actual) {
                repeatCode = actual
            }
        case .functionKey(let action, _, _, _, _) where action == .forwardDelete:
            repeatCode = 0x4c
        default:
            break
        }
        guard let code = repeatCode else { return }
        repeater.start(code)
    }

    private func stopAutoRepeat() {
        repeater.stop()
    }
}

/// Repeats a held deck key. A reference type, so stopping it reaches the timers it scheduled even
/// after the keycap view is gone; each start/stop bumps the generation, so a timer callback already
/// queued from an earlier press does nothing.
@MainActor
private final class KeyAutoRepeater {
    private var timer: Timer?
    private var generation = 0

    func start(_ code: UInt8) {
        stop()
        let gen = generation
        timer = Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == gen else { return }
                        WinIOSBridge.shared.tapKeyHid(code)
                    }
                }
            }
        }
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
    }
}
