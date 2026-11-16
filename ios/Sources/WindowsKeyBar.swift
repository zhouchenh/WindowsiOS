// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import UIKit

/// Ctrl, Alt, Shift and Win from the key bar, and the one bar key held down in Windows.
///
/// Modifiers are latched, not held in Windows: tap = for the next key, double-tap = locked until tapped
/// again, touch and hold = while held. They go down in Windows only around the key they modify, so a Win or
/// Alt latch never opens Start or the menu bar by itself.
///
/// A held bar key is really down in Windows, which repeats it at its own typematic rate: there is no
/// repeat timer on this side (one owner of the repeat). At most one bar key is down at a time, and
/// releaseAll() lifts it (with its modifiers) whenever the layout changes or the app leaves the screen.
final class WindowsKeyState {
    enum Latch { case off, once, locked }

    static let ctrl: UInt8 = 0xe0, shift: UInt8 = 0xe1, alt: UInt8 = 0xe2, win: UInt8 = 0xe3
    static let order: [UInt8] = [ctrl, alt, shift, win]

    private(set) var latches: [UInt8: Latch] = [:]
    private var held: Set<UInt8> = []
    private var lastTap: [UInt8: CFTimeInterval] = [:]
    /// The modifier latches changed (the bar relights its keys).
    var onChange: (() -> Void)?

    private var downKey: UInt8?
    private var downMods: [UInt8] = []
    private(set) var keyEventsSent = 0

    private var bridge: WinIOSBridge { WinIOSBridge.shared }

    func latch(of m: UInt8) -> Latch { latches[m] ?? .off }
    func isHeld(_ m: UInt8) -> Bool { held.contains(m) }

    /// The modifiers the next key gets.
    var activeModifiers: [UInt8] { Self.order.filter { latch(of: $0) != .off || held.contains($0) } }
    var hasActiveModifiers: Bool { !activeModifiers.isEmpty }

    /// off -> once -> (a second tap within 0.4 s) locked -> off.
    func tapModifier(_ m: UInt8) {
        let now = CACurrentMediaTime()
        switch latch(of: m) {
        case .off: latches[m] = .once
        case .once: latches[m] = now - (lastTap[m] ?? 0) < 0.4 ? .locked : .off
        case .locked: latches[m] = .off
        }
        lastTap[m] = now
        onChange?()
    }

    func holdModifier(_ m: UInt8, down: Bool) {
        if down { held.insert(m) } else { held.remove(m) }
        onChange?()
    }

    /// One press of `usage` with the active modifiers plus `extra` (Shift for a capital letter).
    func tap(_ usage: UInt8, extra: [UInt8] = []) {
        releaseDownKey()
        var mods = activeModifiers
        for e in extra where !mods.contains(e) { mods.append(e) }
        if mods.isEmpty {
            bridge.tapKeyHid(usage)
        } else {
            bridge.sendKeyCombo(withModifiers: mods.map { NSNumber(value: $0) }, key: usage)
        }
        keyEventsSent += 1
        consumeOnce()
    }

    /// A shortcut with its own modifiers (the palette, Search, Undo...): the latches are not used.
    func combo(_ mods: [UInt8], _ usage: UInt8) {
        releaseDownKey()
        bridge.sendKeyCombo(withModifiers: mods.map { NSNumber(value: $0) }, key: usage)
        keyEventsSent += 1
    }

    /// The key goes down in Windows (and stays down, repeating, until keyUp). mods: its own modifiers,
    /// or nil for the active ones.
    func keyDown(_ usage: UInt8, mods own: [UInt8]? = nil) {
        releaseDownKey()
        let mods = own ?? activeModifiers
        for m in mods { bridge.sendKeyHid(m, down: true) }
        bridge.sendKeyHid(usage, down: true)
        downKey = usage
        downMods = mods
        keyEventsSent += 1
    }

    func keyUp() {
        guard let k = downKey else { return }
        bridge.sendKeyHid(k, down: false)
        for m in downMods.reversed() { bridge.sendKeyHid(m, down: false) }
        let usedLatches = downMods.contains { latch(of: $0) == .once }
        downKey = nil
        downMods = []
        if usedLatches { consumeOnce() }
    }

    var hasKeyDown: Bool { downKey != nil }

    private func releaseDownKey() {
        if downKey != nil { keyUp() }
    }

    /// Lifts the held key and its modifiers in Windows. keepLatches: false also turns every latch off
    /// (the app leaves the screen).
    func releaseAll(keepLatches: Bool) {
        releaseDownKey()
        held.removeAll()
        if !keepLatches { latches.removeAll() }
        onChange?()
    }

    func consumeOnce() {
        var changed = false
        for (m, l) in latches where l == .once {
            latches[m] = .off
            changed = true
        }
        if changed { onChange?() }
    }
}

/// One key of the bar.
private struct BarKey {
    enum Kind {
        case key(UInt8)                 // with the latched modifiers; held = repeats
        case combo([UInt8], UInt8)      // its own modifiers; held = repeats
        case modifier(UInt8)
        case action(Selector)
    }

    let symbol: String?
    let title: String?
    let name: String
    let hint: String?
    let kind: Kind
}

/// A key: a down/up control with a light haptic on touch-down.
private final class BarKeyButton: UIControl {
    let key: BarKey
    let glyph = UIImageView()
    let label = UILabel()
    var lit: WindowsKeyState.Latch = .off { didSet { updateLook() } }

    init(_ key: BarKey) {
        self.key = key
        super.init(frame: .zero)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        if let s = key.symbol { glyph.image = UIImage(systemName: s) }
        label.text = key.title
        addSubview(glyph)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = key.name
        accessibilityHint = key.hint
        accessibilityTraits = .keyboardKey
        showsLargeContentViewer = true
        largeContentTitle = key.title ?? key.name
        largeContentImage = key.symbol.flatMap { UIImage(systemName: $0) }
        addInteraction(UILargeContentViewerInteraction())
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
        label.frame = bounds.insetBy(dx: 2, dy: 0)
        glyph.isHidden = key.symbol == nil
        label.isHidden = key.title == nil
    }

    override var isHighlighted: Bool { didSet { updateLook() } }

    private func updateLook() {
        let accent = UIColor.tintColor
        switch lit {
        case .locked:
            backgroundColor = accent
        case .once:
            backgroundColor = accent.withAlphaComponent(0.45)
        case .off:
            backgroundColor = isHighlighted ? UIColor(white: 1, alpha: 0.22) : .clear
        }
        if case .modifier = key.kind {
            switch lit {
            case .off: accessibilityValue = L("关", "Off")
            case .once: accessibilityValue = L("用于下一个键", "On for the next key")
            case .locked: accessibilityValue = L("已锁定", "Locked")
            }
        }
    }
}

/// Scrolling may start on a key (a UIScrollView normally leaves controls their touches).
private final class KeyRowScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// A row that scrolls sideways, faded at an edge with more to see.
private final class FadingScroller: UIView, UIScrollViewDelegate {
    let scroll: UIScrollView = KeyRowScrollView()
    private let fade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.delaysContentTouches = false // keys answer at once; a scroll cancels them (see BarKeyButton use)
        scroll.canCancelContentTouches = true
        scroll.delegate = self
        addSubview(scroll)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        updateFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateFade() }

    private func updateFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let w = max(1, bounds.width)
        let edge = min(0.25, 22 / w)
        let more = scroll.contentSize.width - scroll.contentOffset.x - bounds.width > 1
        let less = scroll.contentOffset.x > 1
        let on = UIColor.black.cgColor, off = UIColor.clear.cgColor
        fade.colors = [less ? off : on, on, on, more ? off : on]
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
    }
}

/// The keys above the iOS keyboard, in dark capsules that float over the picture:
///   (Esc) (Start, Search, Task View) (Undo, Redo) (Tab, Ctrl, Alt, Shift, Win) (arrows, Home, End,
///   PgUp, PgDn, Del: scrolls) (Shortcuts) (hide keyboard) [map of the screen]
/// Glyphs, with text only where Windows' own keys have it. Every key says its Windows name to VoiceOver.
final class WindowsKeyBar: UIView {
    private weak var canvas: MetalCanvasUIView?
    private let keys: WindowsKeyState
    let miniMap = MiniMapView()

    private let escCapsule = UIView()
    private let modsCapsule = UIView()
    private let paletteCapsule = UIView()
    private let hideCapsule = UIView()
    private let lead = FadingScroller()
    private let arrows = FadingScroller()
    private let systemCapsule = UIView()
    private let editCapsule = UIView()
    private let arrowCapsule = UIView()
    private var buttons: [BarKeyButton] = []
    private let paletteButton = UIButton(type: .system)
    private let noticeCapsule = UIView()
    private let noticeLabel = UILabel()
    private var noticeTimer: Timer?
    private var persistentNotice: String?
    private var lastSize: CGSize = .zero
    private var holdTimers: [ObjectIdentifier: Timer] = [:]
    private var holding: Set<ObjectIdentifier> = []
    /// Touches whose key was released for them (reshape, app inactive): their touch-up does nothing.
    private var voided: Set<ObjectIdentifier> = []
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    static let barHeight: CGFloat = 52

    private static func key(_ symbol: String?, _ title: String?, _ name: String, _ hint: String?, _ kind: BarKey.Kind) -> BarKey {
        BarKey(symbol: symbol, title: title, name: name, hint: hint, kind: kind)
    }

    private let escKeys = [key(nil, "Esc", "Esc", nil, .key(0x29))]
    private let systemKeys = [
        key("square.grid.2x2", nil, L("开始", "Start"), L("Windows 键", "Windows key"), .key(0xe3)),
        key("magnifyingglass", nil, L("搜索", "Search"), L("Windows 键加 S", "Windows key plus S"), .combo([0xe3], 0x16)),
        key("rectangle.on.rectangle", nil, L("任务视图", "Task View"), L("Windows 键加 Tab", "Windows key plus Tab"), .combo([0xe3], 0x2b)),
    ]
    private let editKeys = [
        key("arrow.uturn.backward", nil, L("撤销", "Undo"), "Ctrl+Z", .combo([0xe0], 0x1d)),
        key("arrow.uturn.forward", nil, L("重做", "Redo"), "Ctrl+Y", .combo([0xe0], 0x1c)),
    ]
    private let modifierKeys = [
        key("arrow.right.to.line", nil, "Tab", nil, .key(0x2b)),
        key(nil, "Ctrl", "Ctrl", L("点一下用于下一个键，点两下锁定", "Tap for the next key, double-tap to lock"), .modifier(0xe0)),
        key(nil, "Alt", "Alt", L("点一下用于下一个键，点两下锁定", "Tap for the next key, double-tap to lock"), .modifier(0xe2)),
        key("shift", nil, "Shift", L("点一下用于下一个键，点两下锁定", "Tap for the next key, double-tap to lock"), .modifier(0xe1)),
        key(nil, "Win", L("Windows 键", "Windows key"), L("点一下用于下一个键，点两下锁定", "Tap for the next key, double-tap to lock"), .modifier(0xe3)),
    ]
    private let arrowKeys = [
        key("arrow.left", nil, L("左箭头", "Left arrow"), nil, .key(0x50)),
        key("arrow.up", nil, L("上箭头", "Up arrow"), nil, .key(0x52)),
        key("arrow.down", nil, L("下箭头", "Down arrow"), nil, .key(0x51)),
        key("arrow.right", nil, L("右箭头", "Right arrow"), nil, .key(0x4f)),
        key(nil, "Home", "Home", nil, .key(0x4a)),
        key(nil, "End", "End", nil, .key(0x4d)),
        key(nil, "PgUp", "Page Up", nil, .key(0x4b)),
        key(nil, "PgDn", "Page Down", nil, .key(0x4e)),
        key("delete.right", nil, L("删除", "Delete"), nil, .key(0x4c)),
    ]
    private lazy var hideKey = Self.key("keyboard.chevron.compact.down", nil, L("收起键盘", "Hide keyboard"), nil,
                                        .action(#selector(hideTapped)))

    init(canvas: MetalCanvasUIView, keys: WindowsKeyState, viewport: ViewportController) {
        self.canvas = canvas
        self.keys = keys
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: Self.barHeight))
        autoresizingMask = .flexibleWidth
        backgroundColor = .clear // the picture shows between the capsules

        for c in [escCapsule, modsCapsule, paletteCapsule, hideCapsule, systemCapsule, editCapsule, arrowCapsule, noticeCapsule] {
            c.backgroundColor = UIColor(white: 0.17, alpha: 0.9)
            c.layer.cornerCurve = .continuous
            c.layer.borderWidth = 0.5
            c.layer.borderColor = UIColor(white: 1, alpha: 0.1).cgColor
        }
        addSubview(escCapsule)
        addSubview(lead)
        lead.scroll.addSubview(systemCapsule)
        lead.scroll.addSubview(editCapsule)
        addSubview(modsCapsule)
        addSubview(arrows)
        arrows.scroll.addSubview(arrowCapsule)
        addSubview(paletteCapsule)
        addSubview(hideCapsule)
        miniMap.viewport = viewport
        addSubview(miniMap)

        fill(escCapsule, escKeys)
        fill(systemCapsule, systemKeys)
        fill(editCapsule, editKeys)
        fill(modsCapsule, modifierKeys)
        fill(arrowCapsule, arrowKeys)
        fill(hideCapsule, [hideKey])

        paletteButton.setImage(UIImage(systemName: "keyboard.badge.ellipsis",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        paletteButton.tintColor = .white
        paletteButton.showsMenuAsPrimaryAction = true
        paletteButton.menu = paletteMenu()
        paletteButton.accessibilityLabel = L("快捷键", "Shortcuts")
        paletteButton.accessibilityHint = L("剪贴板历史、表情、截图、Ctrl+Alt+Del 等", "Clipboard history, emoji, snip, Ctrl+Alt+Del and more")
        paletteCapsule.addSubview(paletteButton)

        noticeCapsule.isHidden = true
        noticeCapsule.isUserInteractionEnabled = false
        noticeLabel.textColor = .white
        noticeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        noticeLabel.adjustsFontSizeToFitWidth = true
        noticeLabel.minimumScaleFactor = 0.75
        noticeCapsule.addSubview(noticeLabel)
        addSubview(noticeCapsule)

        keys.onChange = { [weak self] in self?.relightModifiers() }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appInactive), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(appLeaving), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight) }

    private func fill(_ capsule: UIView, _ list: [BarKey]) {
        for k in list {
            let b = BarKeyButton(k)
            b.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
            b.addTarget(self, action: #selector(keyUp(_:)), for: .touchUpInside)
            b.addTarget(self, action: #selector(keyCancel(_:)), for: [.touchUpOutside, .touchCancel])
            capsule.addSubview(b)
            buttons.append(b)
        }
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            if lastSize != .zero { // a new shape: nothing stays down
                cancelHolds()
                keys.releaseAll(keepLatches: true)
            }
            lastSize = bounds.size
        }
        let compact = bounds.width < 560
        let kw: CGFloat = compact ? 34 : 42
        let gap: CGFloat = compact ? 5 : 9
        let ch: CGFloat = min(40, bounds.height - 10)
        let y = (bounds.height - ch) / 2
        let pad: CGFloat = 3
        let left = safeAreaInsets.left + (compact ? 4 : 8)
        let right = bounds.width - safeAreaInsets.right - (compact ? 4 : 8)

        func capW(_ n: Int) -> CGFloat { CGFloat(n) * kw + 2 * pad }
        func lay(_ capsule: UIView, _ x: CGFloat, _ n: Int) {
            capsule.frame = CGRect(x: x, y: 0, width: capW(n), height: ch)
            capsule.layer.cornerRadius = ch / 2
            var bx = pad
            for case let b as BarKeyButton in capsule.subviews {
                b.frame = CGRect(x: bx, y: 3, width: kw, height: ch - 6)
                bx += kw
            }
        }

        let mapW = compact ? 0 : miniMap.preferredWidth(forHeight: ch)
        miniMap.isHidden = compact
        let fixed = capW(1) /* esc */ + capW(5) /* mods */ + capW(1) /* palette */ + capW(1) /* hide */ + mapW
        let gaps = gap * (compact ? 5 : 6)
        let leadContent = capW(3) + gap + capW(2)
        let arrowContent = capW(arrowKeys.count)
        let avail = max(0, right - left - fixed - gaps)
        var leadW: CGFloat, arrowW: CGFloat
        if avail >= leadContent + arrowContent {
            leadW = leadContent
            arrowW = arrowContent
        } else {
            arrowW = min(arrowContent, max(capW(2) + kw / 2, avail - leadContent))
            leadW = max(0, avail - arrowW)
            if leadW < capW(1) {
                leadW = 0
                arrowW = avail
            }
        }

        var x = left
        escCapsule.frame.origin = CGPoint(x: x, y: y)
        lay(escCapsule, x, 1)
        escCapsule.frame.origin.y = y
        x += capW(1) + gap
        // no room for the app keys of their own (a phone): they follow the arrows in that row
        let merged = leadW <= 0
        let host = merged ? arrows.scroll : lead.scroll
        if systemCapsule.superview !== host {
            host.addSubview(systemCapsule)
            host.addSubview(editCapsule)
        }
        lead.isHidden = merged
        lead.frame = CGRect(x: x, y: y, width: leadW, height: ch)
        let appKeysAt = merged ? arrowContent + gap : 0
        lay(systemCapsule, appKeysAt, 3)
        lay(editCapsule, appKeysAt + capW(3) + gap, 2)
        lead.scroll.contentSize = CGSize(width: leadContent, height: ch)
        if !merged { x += leadW + gap }
        lay(modsCapsule, x, 5)
        modsCapsule.frame.origin.y = y
        x += capW(5) + gap
        arrows.frame = CGRect(x: x, y: y, width: max(0, arrowW), height: ch)
        lay(arrowCapsule, 0, arrowKeys.count)
        arrows.scroll.contentSize = CGSize(width: merged ? appKeysAt + leadContent : arrowContent, height: ch)

        // the rest from the right edge
        var rx = right
        if !compact {
            rx -= mapW
            miniMap.frame = CGRect(x: rx, y: y, width: mapW, height: ch)
            rx -= gap
        }
        rx -= capW(1)
        lay(hideCapsule, rx, 1)
        hideCapsule.frame.origin.y = y
        rx -= gap + capW(1)
        paletteCapsule.frame = CGRect(x: rx, y: y, width: capW(1), height: ch)
        paletteCapsule.layer.cornerRadius = ch / 2
        paletteButton.frame = CGRect(x: pad, y: 3, width: kw, height: ch - 6)

        // a notice covers the app keys while it shows
        if lead.isHidden { // over the arrows (scrolling), never over the modifiers
            noticeCapsule.frame = arrows.frame
        } else {
            noticeCapsule.frame = lead.frame
        }
        noticeCapsule.layer.cornerRadius = ch / 2
        noticeLabel.frame = noticeCapsule.bounds.insetBy(dx: 12, dy: 0)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { // the keyboard went away with a key held
            cancelHolds()
            keys.releaseAll(keepLatches: true)
        }
        relightModifiers()
    }

    /// Control Center, a banner, a call: nothing stays down in Windows; a lock survives.
    @objc private func appInactive() {
        cancelHolds()
        keys.releaseAll(keepLatches: true)
    }

    /// The app leaves the screen: everything off.
    @objc private func appLeaving() {
        cancelHolds()
        keys.releaseAll(keepLatches: false)
    }

    // MARK: keys

    private func relightModifiers() {
        for b in buttons {
            if case .modifier(let m) = b.key.kind {
                b.lit = keys.isHeld(m) ? .locked : keys.latch(of: m)
            }
        }
    }

    private func cancelHolds() {
        for t in holdTimers.values { t.invalidate() }
        voided.formUnion(holdTimers.keys)
        voided.formUnion(holding)
        holdTimers.removeAll()
        holding.removeAll()
    }

    /// Touch-down: a modifier waits to see whether it is a tap or a hold; any other key waits 0.12 s
    /// before it goes down in Windows, so scrolling the row past it presses nothing and a quick tap is a
    /// plain press.
    @objc private func keyDown(_ b: BarKeyButton) {
        haptic.impactOccurred(intensity: 0.6)
        UIDevice.current.playInputClick()
        let id = ObjectIdentifier(b)
        holdTimers[id]?.invalidate()
        voided.remove(id)
        switch b.key.kind {
        case .action:
            return
        case .modifier(let m):
            holdTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.holdTimers[id] = nil
                self.holding.insert(id)
                self.keys.holdModifier(m, down: true)
            }
        case .key, .combo:
            holdTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.holdTimers[id] = nil
                self.holding.insert(id)
                self.press(b.key.kind, down: true)
            }
        }
    }

    @objc private func keyUp(_ b: BarKeyButton) {
        let id = ObjectIdentifier(b)
        if voided.remove(id) != nil { return }
        let wasHeld = holding.remove(id) != nil
        holdTimers.removeValue(forKey: id)?.invalidate()
        switch b.key.kind {
        case .action(let sel):
            perform(sel)
        case .modifier(let m):
            if wasHeld { keys.holdModifier(m, down: false) } else { keys.tapModifier(m) }
        case .key(let u):
            if wasHeld { press(b.key.kind, down: false) } else { keys.tap(u) }
        case .combo(let mods, let u):
            if wasHeld { press(b.key.kind, down: false) } else { keys.combo(mods, u) }
        }
    }

    /// The touch left the key or the row scrolled: a held key comes up, an unsent one is never sent.
    @objc private func keyCancel(_ b: BarKeyButton) {
        let id = ObjectIdentifier(b)
        if voided.remove(id) != nil { return }
        let wasHeld = holding.remove(id) != nil
        holdTimers.removeValue(forKey: id)?.invalidate()
        guard wasHeld else { return }
        switch b.key.kind {
        case .modifier(let m): keys.holdModifier(m, down: false)
        case .key, .combo: press(b.key.kind, down: false)
        case .action: break
        }
    }

    private func press(_ kind: BarKey.Kind, down: Bool) {
        switch kind {
        case .key(let u): down ? keys.keyDown(u) : keys.keyUp()
        case .combo(let mods, let u): down ? keys.keyDown(u, mods: mods) : keys.keyUp()
        default: break
        }
    }

    @objc private func hideTapped() {
        canvas?.dismissKeyboard()
    }

    // MARK: notices

    /// A short line over the app keys: transient (a few seconds) or persistent (until cleared).
    func showNotice(_ text: String?, persistent: Bool = false) {
        noticeTimer?.invalidate()
        noticeTimer = nil
        if persistent { persistentNotice = text }
        let shown = text ?? persistentNotice
        noticeLabel.text = shown
        noticeCapsule.isHidden = shown == nil
        if let shown { UIAccessibility.post(notification: .announcement, argument: shown) }
        if !persistent && text != nil {
            noticeTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.noticeLabel.text = self.persistentNotice
                self.noticeCapsule.isHidden = self.persistentNotice == nil
            }
        }
    }

    // MARK: Shortcuts palette

    private func paletteMenu() -> UIMenu {
        func combo(_ title: String, _ shortcut: String, _ symbol: String?, _ mods: [UInt8], _ key: UInt8) -> UIAction {
            let a = UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }) { [weak self] _ in
                self?.keys.combo(mods, key)
            }
            a.subtitle = shortcut
            a.accessibilityLabel = title + ", " + shortcut
            return a
        }
        let win: UInt8 = 0xe3, ctrl: UInt8 = 0xe0, alt: UInt8 = 0xe2, shift: UInt8 = 0xe1
        let windows: [UIMenuElement] = [
            combo(L("剪贴板历史", "Clipboard history"), "Win+V", "doc.on.clipboard", [win], 0x19),
            combo(L("表情符号", "Emoji"), "Win+.", "face.smiling", [win], 0x37),
            combo(L("截图", "Snip"), "Win+Shift+S", "scissors", [win, shift], 0x16),
            combo(L("切换应用", "Switch apps"), "Alt+Tab", "square.stack", [alt], 0x2b),
            combo(L("显示桌面", "Show desktop"), "Win+D", "menubar.dock.rectangle", [win], 0x07),
            combo(L("贴靠布局", "Snap layouts"), "Win+Z", "rectangle.split.2x1", [win], 0x1d),
            combo(L("文件资源管理器", "File Explorer"), "Win+E", "folder", [win], 0x08),
            combo(L("快速设置", "Quick Settings"), "Win+A", "switch.2", [win], 0x04),
            combo(L("通知", "Notifications"), "Win+N", "bell", [win], 0x11),
            combo(L("切换输入法", "Input language"), "Win+Space", "globe", [win], 0x2c),
        ]
        let edit: [UIMenuElement] = [
            combo(L("复制", "Copy"), "Ctrl+C", "doc.on.doc", [ctrl], 0x06),
            combo(L("剪切", "Cut"), "Ctrl+X", "scissors", [ctrl], 0x1b),
            combo(L("粘贴", "Paste"), "Ctrl+V", "doc.on.clipboard", [ctrl], 0x19),
            combo(L("全选", "Select all"), "Ctrl+A", "selection.pin.in.out", [ctrl], 0x04),
            combo(L("保存", "Save"), "Ctrl+S", "square.and.arrow.down", [ctrl], 0x16),
            combo(L("查找", "Find"), "Ctrl+F", "magnifyingglass", [ctrl], 0x09),
            combo(L("关闭标签页", "Close tab"), "Ctrl+W", "xmark.square", [ctrl], 0x1a),
            combo(L("关闭窗口", "Close window"), "Alt+F4", "xmark.rectangle", [alt], 0x3d),
        ]
        let fkeys: [UIMenuElement] = (0..<12).map { i in
            let a = UIAction(title: "F\(i + 1)") { [weak self] _ in self?.keys.tap(UInt8(0x3a + i)) }
            return a
        }
        let cad = UIAction(title: "Ctrl+Alt+Del", image: UIImage(systemName: "lock.shield")) { _ in
            WinIOSBridge.shared.sendCtrlAltDel()
        }
        let system: [UIMenuElement] = [
            combo(L("任务管理器", "Task Manager"), "Ctrl+Shift+Esc", "gauge.with.dots.needle.33percent", [ctrl, shift], 0x29),
            cad,
            combo(L("锁定", "Lock"), "Win+L", "lock", [win], 0x0f),
            UIMenu(title: L("功能键 F1–F12", "Function keys F1–F12"), image: UIImage(systemName: "f.cursive"), children: fkeys),
        ]
        let zoom = UIAction(title: L("放大画面 / 还原", "Zoom the picture / back"), image: UIImage(systemName: "plus.magnifyingglass")) { [weak self] _ in
            self?.canvas?.toggleViewportZoom(anchor: nil)
        }
        let top = UIMenu(title: "", options: .displayInline, children: windows)
        if #available(iOS 16.0, *) { top.preferredElementSize = .medium }
        return UIMenu(title: L("快捷键", "Shortcuts"), children: [
            top,
            UIMenu(title: L("编辑", "Edit"), options: .displayInline, children: edit),
            UIMenu(title: L("系统", "System"), options: .displayInline, children: system),
            UIMenu(title: "", options: .displayInline, children: [zoom]),
        ])
    }
}

extension WindowsKeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
