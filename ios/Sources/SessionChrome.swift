// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

// MARK: - Surfaces and the chrome's state

/// Where Windows is shown: the inner screen flat (Studio, also every non-foldable device), the lid
/// above the fold (Laptop) or the foldable's outer screen (Cover). Immersive is remembered for each.
enum ChromeSurface: String, CaseIterable {
    case studio, laptop, cover

    var title: String {
        switch self {
        case .studio: return L("全屏", "Studio")
        case .laptop: return L("笔记本", "Laptop")
        case .cover: return L("外屏", "Cover screen")
        }
    }

    /// The surface for a layout. On a known foldable the cover is the closed hinge, or (no reading
    /// yet) a screen smaller than the inner one, whose long side is 951 pt.
    static func of(laptop: Bool, size: CGSize, hingeStatus: Int, foldable: Bool) -> ChromeSurface {
        if laptop { return .laptop }
        guard foldable else { return .studio }
        if hingeStatus == 1 { return .cover }
        if hingeStatus == 0, size.width > 0, max(size.width, size.height) < 780 { return .cover }
        return .studio
    }
}

/// The session chrome: immersive mode for each surface, the keyboard button's corner, the hint
/// for bringing the controls back, and what the system reported (shown in Settings > Status).
@MainActor
final class ChromeModel: ObservableObject {
    static let shared = ChromeModel()

    @Published private var immersiveBySurface: [ChromeSurface: Bool]
    /// The surface on screen now (the session view keeps it current).
    @Published private(set) var surface: ChromeSurface = .studio
    /// Immersive: Windows takes the whole screen (one resolution change); off: Windows keeps the
    /// size it had with the controls, shown as large as fits (no resolution change). One setting with
    /// the display's "In immersive full screen" (DisplaySettings.immersiveSizing), which the bridge's
    /// reshape filter also follows.
    var immersiveTakesWholeScreen: Bool { DisplaySettings.shared.immersiveSizing == .fullPanel }
    /// The floating keyboard button sits in the bottom-left corner instead of the bottom-right.
    @Published var keyboardButtonOnLeft: Bool = UserDefaults.standard.bool(forKey: "winios.chrome.fabLeft") {
        didSet { UserDefaults.standard.set(keyboardButtonOnLeft, forKey: "winios.chrome.fabLeft") }
    }
    /// The floating keyboard button is shown at all. Off: the controls' Keyboard button is the way in.
    @Published var keyboardButtonShown: Bool = UserDefaults.standard.object(forKey: "winios.chrome.fabShown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keyboardButtonShown, forKey: "winios.chrome.fabShown") }
    }
    /// The system Paste button in the toolbar. Off by default: iOS cannot put a paste control in the
    /// Duo's vertical bar, so it would keep a top bar open just for itself. The Clipboard menu sends the
    /// iPhone clipboard too (iOS may ask first), and Settings › Clipboard has the button.
    @Published var pasteButtonShown: Bool = UserDefaults.standard.bool(forKey: "winios.chrome.pasteShown") {
        didSet { UserDefaults.standard.set(pasteButtonShown, forKey: "winios.chrome.pasteShown") }
    }
    @Published private(set) var hint: String? = nil

    // What the system reported, for Settings > Status and the log.
    @Published private(set) var verticalBarSide: VerticalBarSide = .none
    @Published private(set) var verticalBarPath: String = "-"
    @Published private(set) var foldSource: String = "-"
    @Published private(set) var occlusionSummary: String = "-"
    @Published private(set) var screenSummary: String = "-"
    @Published private(set) var safeAreaSummary: String = "-"

    /// The Windows screen's size with the controls shown, per surface (for immersive without a
    /// resolution change).
    private(set) var windowedCanvasSize: [ChromeSurface: CGSize] = [:]
    private weak var rootController: UIViewController?
    private weak var window: UIWindow?
    private var keyboardObservers: [NSObjectProtocol] = []
    /// Where the docked on-screen keyboard starts, in screen coordinates; nil while it is hidden,
    /// floating or split. The Windows screen ends there (P0-6 would pan instead).
    @Published private(set) var keyboardTop: CGFloat? = nil
    private let gestures = ChromeWindowGestures()
    private var hintWork: DispatchWorkItem?
    private var vbarCheck: DispatchWorkItem?
    /// The surface on which immersive needed the vertical bar turned off (its inset stayed after the
    /// visibility APIs). Kept for as long as that immersive lasts on that surface: a trait change (the bar
    /// itself going away, a rotation) does not try the visibility APIs again, which would bring the bar
    /// back and take it away every 0.6 s.
    private var vbarFallbackSurface: ChromeSurface?
    private var lastInsets = EdgeInsets()
    private var lastViewport: CGSize = .zero

    private init() {
        var map: [ChromeSurface: Bool] = [:]
        for s in ChromeSurface.allCases {
            map[s] = UserDefaults.standard.bool(forKey: "winios.chrome.immersive." + s.rawValue)
        }
        immersiveBySurface = map
        // The former chrome switch (winios.chrome.immersiveRemodes) off becomes the display's "keep size".
        if let old = UserDefaults.standard.object(forKey: "winios.chrome.immersiveRemodes") as? Bool {
            if !old { DisplaySettings.shared.immersiveSizing = .keepSize }
            UserDefaults.standard.removeObject(forKey: "winios.chrome.immersiveRemodes")
        }
        watchKeyboard()
        gestures.onFourFingerTap = { [weak self] in self?.gestureToggle("four-finger tap") }
        gestures.onEdgeSwipe = { [weak self] in
            guard let self, self.isImmersive else { return }
            self.gestureToggle("edge swipe")
        }
    }

    var isImmersive: Bool { immersiveBySurface[surface] ?? false }
    func isImmersive(_ s: ChromeSurface) -> Bool { immersiveBySurface[s] ?? false }

    func setSurface(_ s: ChromeSurface) {
        guard s != surface else { return }
        surface = s
        chromeLog("surface \(s.rawValue), immersive \(isImmersive)")
        applySystemState()
    }

    func setImmersive(_ on: Bool, reason: String) { setImmersive(on, for: surface, reason: reason) }

    /// Immersive for one surface (Settings can set the ones not on screen).
    func setImmersive(_ on: Bool, for s: ChromeSurface, reason: String) {
        guard on != isImmersive(s) else { return }
        immersiveBySurface[s] = on
        UserDefaults.standard.set(on, forKey: "winios.chrome.immersive." + s.rawValue)
        chromeLog("immersive \(on ? "on" : "off") on \(s.rawValue) (\(reason))")
        guard s == surface else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if on { showReturnHintIfNeeded() } else { clearHint() }
        applySystemState()
    }

    func toggleImmersive(reason: String) { setImmersive(!isImmersive, reason: reason) }

    private func gestureToggle(_ reason: String) {
        guard sessionActive else { return }
        withAnimation(.snappy(duration: 0.22)) { toggleImmersive(reason: reason) }
    }

    func rememberWindowedCanvas(_ size: CGSize, for s: ChromeSurface) {
        guard size.width > 1, size.height > 1 else { return }
        windowedCanvasSize[s] = size
    }

    // MARK: Keyboard

    private func watchKeyboard() {
        let nc = NotificationCenter.default
        keyboardObservers.append(nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
                                                object: nil, queue: .main) { [weak self] note in
            let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.keyboardFrameChanged(end) }
        })
        keyboardObservers.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardFrameChanged(nil) }
        })
    }

    private func keyboardFrameChanged(_ end: CGRect?) {
        var top: CGFloat? = nil
        if let end, let bounds = window?.bounds, end.minY < bounds.height - 1, end.width >= bounds.width * 0.6 {
            top = max(0, end.minY)
        }
        guard top != keyboardTop else { return }
        withAnimation(.easeOut(duration: 0.25)) { keyboardTop = top }
    }

    // MARK: Hint

    /// The first three times the controls go away, say how to bring them back.
    private func showReturnHintIfNeeded() {
        let key = "winios.chrome.returnHints"
        let shown = UserDefaults.standard.integer(forKey: key)
        guard shown < 3 else { return }
        UserDefaults.standard.set(shown + 1, forKey: key)
        showHint(L("四指轻点，或从左右边缘向内轻扫，可以找回控制按钮",
                   "Tap with four fingers, or swipe in from the left or right edge, to bring the controls back"))
    }

    func showHint(_ text: String, seconds: Double = 3.5) {
        hintWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { hint = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.3)) { self?.hint = nil }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func clearHint() {
        hintWork?.cancel()
        hint = nil
    }

    // MARK: System state (root controller, window gestures)

    /// The hinge sensor's controller reports the window and the root controller once it is on screen.
    func attach(window: UIWindow) {
        self.window = window
        gestures.attach(to: window)
        if let root = window.rootViewController, root !== rootController {
            rootController = root
            RootControllerHooks.install(on: root)
        }
        if lastViewport.width > 0 { reportScreen(viewport: lastViewport) }
        applySystemState()
    }

    func traitsChanged(_ traits: UITraitCollection) {
        let side = VerticalBarSide.of(traits)
        guard side != verticalBarSide else { return }
        verticalBarSide = side
        chromeLog("vertical bar edge: \(side.rawValue)")
        applySystemState()
    }

    /// Windows is on screen with no sheet over it (set by the session view).
    @Published private(set) var sessionActive = false
    /// Status bar, home indicator and bars hidden: immersive while Windows is on screen.
    var hidesSystemUI: Bool { sessionActive && isImmersive }

    /// Editing gestures off while Windows has the screen; edge swipes only while immersive.
    func updateSessionActive(_ active: Bool) {
        guard active != sessionActive else { return }
        sessionActive = active
        RootControllerHooks.editingGesturesBlocked = active
        applySystemState() // e.g. the vertical bar comes back over the launch page, Settings or Safari
    }

    private func applySystemState() {
        gestures.setEdgeSwipeEnabled(sessionActive && isImmersive)
        vbarCheck?.cancel()
        let forced = ChromeEnv.flag("HV_VBAR_DISABLE")
        if !sessionActive || !isImmersive || forced == false {
            vbarFallbackSurface = nil
            setVerticalBarDisabled(false, why: !isImmersive ? "controls shown" : !sessionActive ? "Windows not on screen" : "HV_VBAR_DISABLE=0")
            return
        }
        if forced == true {
            setVerticalBarDisabled(true, why: "HV_VBAR_DISABLE=1")
            return
        }
        if vbarFallbackSurface == surface {
            setVerticalBarDisabled(true, why: "kept for this immersive")
            return
        }
        vbarFallbackSurface = nil
        // Visibility APIs first (bars, status bar, home indicator hidden). If the vertical bar still
        // keeps its inset once things settle, turn it off for as long as immersive lasts.
        setVerticalBarDisabled(false, why: "immersive: visibility APIs")
        let work = DispatchWorkItem { [weak self] in self?.checkVerticalBarAfterHiding() }
        vbarCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The session view reports the safe area it lays Windows out in.
    func reportInsets(_ insets: EdgeInsets) {
        lastInsets = insets
        safeAreaSummary = String(format: "%.0f / %.0f / %.0f / %.0f", insets.top, insets.leading, insets.bottom, insets.trailing)
    }

    private func checkVerticalBarAfterHiding() {
        guard sessionActive else { return } // left the screen meanwhile: applySystemState has run
        guard isImmersive, verticalBarSide != .none else {
            verticalBarPath = isImmersive ? L("沉浸：隐藏栏（没有竖栏）", "Immersive: bars hidden (no vertical bar)")
                                          : verticalBarPath
            chromeLog("immersive via visibility APIs (no vertical bar on this screen)")
            return
        }
        let inset = verticalBarSide == .leading ? lastInsets.leading : lastInsets.trailing
        if inset > 1 {
            chromeLog(String(format: "immersive: vertical-bar inset %.0f pt remains after hiding the bars -> preferredVerticalBarBehavior = .disabled", inset))
            vbarFallbackSurface = surface
            setVerticalBarDisabled(true, why: String(format: "inset %.0f pt stayed", inset))
        } else {
            verticalBarPath = L("沉浸：隐藏栏（可见性 API）", "Immersive: bars hidden (visibility APIs)")
            chromeLog("immersive via visibility APIs: the vertical bar left no inset")
        }
    }

    private func setVerticalBarDisabled(_ off: Bool, why: String) {
        let changed = RootControllerHooks.verticalBarDisabled != off
        RootControllerHooks.verticalBarDisabled = off
        if off {
            verticalBarPath = L("沉浸：竖栏已关闭（", "Immersive: vertical bar disabled (") + why + ")"
        } else if !isImmersive {
            verticalBarPath = verticalBarSide == .none ? L("自动（没有竖栏）", "Automatic (no vertical bar)")
                                                       : L("自动（竖栏在", "Automatic (vertical bar on the ") + verticalBarSide.rawValue + L("）", " edge)")
        }
        guard changed else { return }
        chromeLog("preferredVerticalBarBehavior -> \(off ? "disabled" : "automatic") (\(why))")
        if #available(iOS 27.1, *), let root = rootController {
            root.setNeedsUpdateOfVerticalBarConfiguration()
        }
    }

    // MARK: Diagnostics from the layout

    func reportFold(source: String, rect: CGRect?) {
        let text = rect.map { String(format: "%@ · y %.0f–%.0f", source, $0.minY, $0.maxY) } ?? source
        guard text != foldSource else { return }
        foldSource = text
        chromeLog("fold: \(text)")
    }

    func reportOcclusions(_ rects: [CGRect]) {
        let text = rects.isEmpty ? L("无", "None")
            : rects.map { String(format: "%.0f,%.0f %.0f×%.0f", $0.minX, $0.minY, $0.width, $0.height) }.joined(separator: "; ")
        guard text != occlusionSummary else { return }
        occlusionSummary = text
        chromeLog("occlusion regions: \(text)")
    }

    func reportScreen(viewport: CGSize) {
        lastViewport = viewport
        guard let screen = window?.screen else { return }
        let nb = screen.nativeBounds.size
        let text = String(format: "%.0f×%.0f pt · %.0f×%.0f px · scale %.0f · native %.3f",
                          viewport.width, viewport.height, nb.width, nb.height, screen.scale, screen.nativeScale)
        guard text != screenSummary else { return }
        screenSummary = text
        chromeLog("screen: \(text) on \(surface.rawValue)")
    }
}

// MARK: - Fold

/// Where Laptop splits the screen: at the fold iOS reports (reservedRegions(kind: .division)), or
/// at half the height when there is none (older iOS, no reading, or HV_FOLD_REGION=0).
struct FoldLayout: Equatable {
    let lidBottom: CGFloat
    let deckTop: CGFloat
    let fromRegion: Bool
    let region: CGRect?

    init(full: CGSize, division: CGRect?) {
        if let d = division, ChromeEnv.flag("HV_FOLD_REGION") != false,
           d.width >= full.width * 0.5, d.height < full.height * 0.2,
           d.midY > full.height * 0.25, d.midY < full.height * 0.75 {
            lidBottom = max(1, d.minY.rounded(.down))
            deckTop = min(full.height - 1, max(lidBottom, d.maxY.rounded(.up)))
            fromRegion = true
            region = d
        } else {
            let half = (full.height * 0.5).rounded(.down)
            lidBottom = half
            deckTop = half
            fromRegion = false
            region = division
        }
    }

    var sourceText: String {
        if fromRegion { return L("iOS 折痕区域", "iOS fold region") }
        if region != nil { return L("一半高度（折痕区域不在横向中部）", "Half height (fold region not across the middle)") }
        return L("一半高度（没有折痕区域）", "Half height (no fold region)")
    }
}

// MARK: - Windows keys

/// Keys and shortcuts the chrome sends to Windows (HID usages, US layout).
enum WinKeys {
    static let ctrl: UInt8 = 0xe0, shift: UInt8 = 0xe1, alt: UInt8 = 0xe2, win: UInt8 = 0xe3

    static func combo(_ mods: [UInt8], _ key: UInt8) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        WinIOSBridge.shared.sendKeyCombo(withModifiers: mods.map { NSNumber(value: $0) }, key: key)
    }

    static func tap(_ key: UInt8) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        WinIOSBridge.shared.tapKeyHid(key)
    }

    static func start() { UIImpactFeedbackGenerator(style: .light).impactOccurred(); WinIOSBridge.shared.sendWindowsKey() }
    static func search() { combo([win], 0x16) }          // Win+S
    static func taskView() { combo([win], 0x2b) }        // Win+Tab
    static func snap() { combo([win], 0x1d) }            // Win+Z
    static func desktop() { combo([win], 0x07) }         // Win+D
    static func explorer() { combo([win], 0x08) }        // Win+E
    static func quickSettings() { combo([win], 0x04) }   // Win+A
    static func notifications() { combo([win], 0x11) }   // Win+N
    static func clipboardHistory() { combo([win], 0x19) } // Win+V
    static func emoji() { combo([win], 0x37) }           // Win+.
    static func snip() { combo([win, shift], 0x16) }     // Win+Shift+S
    static func lock() { combo([win], 0x0f) }            // Win+L
    static func undo() { combo([ctrl], 0x1d) }           // Ctrl+Z
    static func redo() { combo([ctrl], 0x1c) }           // Ctrl+Y
    static func taskManager() { combo([ctrl, shift], 0x29) } // Ctrl+Shift+Esc
    static func volumeUp() { tap(0x80) }
    static func volumeDown() { tap(0x81) }
    static func mute() { tap(0x7f) }
}

/// Types text into Windows key by key (printable ASCII, Tab and Enter, US layout), for handing the
/// iPhone's clipboard over on an explicit tap. Other characters are skipped.
enum ClipboardTyper {
    static let maxCharacters = 500

    /// Returns how many characters will be typed and how many were skipped.
    @MainActor @discardableResult
    static func type(_ text: String) -> (typed: Int, skipped: Int) {
        var keys: [(UInt8, Bool)] = []
        var skipped = 0
        for ch in text.prefix(maxCharacters) {
            if let k = hid(for: ch) { keys.append(k) } else { skipped += 1 }
        }
        skipped += max(0, text.count - maxCharacters)
        // One key at a time: each tap is up again (35 ms; a Shift combination 71 ms) before the next goes
        // down. Overlapping taps share one USB report, which cannot press a key that is already down, so a
        // doubled letter ("hello", "https://") would be typed once.
        var at = 0.0
        for (code, shifted) in keys {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                if shifted {
                    WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: WinKeys.shift)], key: code)
                } else {
                    WinIOSBridge.shared.tapKeyHid(code)
                }
            }
            at += shifted ? 0.09 : 0.05
        }
        return (keys.count, skipped)
    }

    private static let unshifted: [Character: UInt8] = [
        " ": 0x2c, "-": 0x2d, "=": 0x2e, "[": 0x2f, "]": 0x30, "\\": 0x31, ";": 0x33, "'": 0x34,
        "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38, "\n": 0x28, "\r": 0x28, "\t": 0x2b, "0": 0x27,
    ]
    private static let shifted: [Character: UInt8] = [
        "!": 0x1e, "@": 0x1f, "#": 0x20, "$": 0x21, "%": 0x22, "^": 0x23, "&": 0x24, "*": 0x25,
        "(": 0x26, ")": 0x27, "_": 0x2d, "+": 0x2e, "{": 0x2f, "}": 0x30, "|": 0x31, ":": 0x33,
        "\"": 0x34, "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38,
    ]

    private static func hid(for ch: Character) -> (UInt8, Bool)? {
        if ch == "\r\n" { return (0x28, false) }
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case 0x61...0x7a: return (0x04 + a - 0x61, false)
        case 0x41...0x5a: return (0x04 + a - 0x41, true)
        case 0x31...0x39: return (0x1e + a - 0x31, false)
        default: break
        }
        if let k = unshifted[ch] { return (k, false) }
        if let k = shifted[ch] { return (k, true) }
        return nil
    }
}

// MARK: - Toolbar (standard items: the Duo's vertical bar, a top bar elsewhere)

/// The session controls as standard toolbar items, so iOS places them: in the iOS 27 vertical bar
/// next to the status items on the Duo (either edge), in the navigation bar elsewhere. Groups:
/// [Start, Search, Task View] [Undo, Redo] [Shortcuts] [Sound, Touch, Keyboard, Clipboard]
/// [Immersive, More]. Narrow screens without a vertical bar fold the first groups into menus.
@MainActor
struct SessionToolbarItems {
    let vm: VMViewModel
    let chrome: ChromeModel
    /// Off: no items (Laptop, immersive, the launch page). The toolbar modifier itself always stays,
    /// so the Windows screen under it keeps its identity.
    let shown: Bool
    /// Few items fit: a compact width with no vertical bar.
    let compact: Bool
    let showPower: () -> Void

    @ToolbarContentBuilder
    var plain: some ToolbarContent {
        if shown {
            ToolbarItemGroup(placement: .topBarLeading) { windowsGroup }
            if !compact {
                ToolbarItemGroup(placement: .topBarLeading) { editGroup }
            }
            ToolbarItemGroup(placement: .topBarTrailing) { utilityGroup }
            ToolbarItemGroup(placement: .topBarTrailing) { sessionGroup }
        }
    }

    /// iOS 26 and later: each group its own glass capsule.
    @available(iOS 26.0, *)
    @ToolbarContentBuilder
    var spaced: some ToolbarContent {
        if shown {
            ToolbarItemGroup(placement: .topBarLeading) { windowsGroup }
            if !compact {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                ToolbarItemGroup(placement: .topBarLeading) { editGroup }
            }
            ToolbarItemGroup(placement: .topBarTrailing) { utilityGroup }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItemGroup(placement: .topBarTrailing) { sessionGroup }
        }
    }

    // [Start, Search, Task View] — one Start button with the others in its menu when narrow.
    @ViewBuilder
    private var windowsGroup: some View {
        if compact {
            Menu {
                Button(L("搜索", "Search"), systemImage: "magnifyingglass") { WinKeys.search() }
                Button(L("任务视图", "Task View"), systemImage: "rectangle.on.rectangle") { WinKeys.taskView() }
                Button(L("贴靠布局", "Snap layouts"), systemImage: "rectangle.split.2x1") { WinKeys.snap() }
                Button(L("撤销", "Undo"), systemImage: "arrow.uturn.backward") { WinKeys.undo() }
                Button(L("重做", "Redo"), systemImage: "arrow.uturn.forward") { WinKeys.redo() }
            } label: {
                Label(L("开始", "Start"), systemImage: "square.grid.2x2")
            } primaryAction: {
                WinKeys.start()
            }
            .accessibilityHint(L("按住可选搜索、任务视图、撤销", "Hold for Search, Task View, Undo"))
        } else {
            Button(L("开始", "Start"), systemImage: "square.grid.2x2") { WinKeys.start() }
            Button(L("搜索", "Search"), systemImage: "magnifyingglass") { WinKeys.search() }
            Button(L("任务视图", "Task View"), systemImage: "rectangle.on.rectangle") { WinKeys.taskView() }
        }
    }

    // [Undo, Redo]
    @ViewBuilder
    private var editGroup: some View {
        Button(L("撤销", "Undo"), systemImage: "arrow.uturn.backward") { WinKeys.undo() }
        Button(L("重做", "Redo"), systemImage: "arrow.uturn.forward") { WinKeys.redo() }
    }

    // [Shortcuts] [Sound, Touch, Keyboard, Clipboard] (Sound and Clipboard live in More when narrow)
    @ViewBuilder
    private var utilityGroup: some View {
        ShortcutsMenu(vm: vm)
        if !compact {
            SoundMenu()
        }
        Button(vm.directTouch ? L("直接触摸", "Direct touch") : L("触控板", "Trackpad"),
               systemImage: vm.directTouch ? "hand.point.up.left.fill" : "rectangle.and.hand.point.up.left") {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            vm.directTouch.toggle()
        }
        if !vm.hardwareKeyboard {
            Button(L("键盘", "Keyboard"),
                   systemImage: vm.systemKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                vm.systemKeyboardVisible.toggle()
            }
        }
        if !compact {
            ClipboardMenu()
        }
        if !vm.isLinux && chrome.pasteButtonShown {
            // Paste to Windows: the system paste button, so iOS never asks (ClipboardViews.swift). A paste
            // control cannot sit inside a menu, so it stays in the bar on narrow screens too.
            ClipboardButton() // clipboard hook
        }
    }

    // [Immersive, More]
    @ViewBuilder
    private var sessionGroup: some View {
        Button(L("沉浸全屏", "Immersive"), systemImage: "arrow.up.left.and.arrow.down.right") {
            withAnimation(.snappy(duration: 0.22)) { chrome.setImmersive(true, reason: "toolbar") }
        }
        SessionMoreMenu(vm: vm, chrome: chrome, includeCompactExtras: compact, showPower: showPower)
    }
}

extension View {
    /// The session toolbar, with each group in its own capsule on iOS 26 and later (the branch is
    /// fixed for the life of the process, so the view's identity never changes).
    @ViewBuilder
    func sessionToolbar(_ items: SessionToolbarItems) -> some View {
        if #available(iOS 26.0, *) {
            self.toolbar { items.spaced }
        } else {
            self.toolbar { items.plain }
        }
    }
}

/// How a chrome menu's button looks: a toolbar item (iOS draws it), a round button beside the
/// deck's trackpad, or a key in the deck's action row.
enum ChromeLabelStyle {
    case bar
    case round(CGFloat)
    case key

    var isBar: Bool { if case .bar = self { return true } else { return false } }
}

struct ChromeMenuLabel: View {
    let title: String
    let symbol: String
    var style: ChromeLabelStyle = .bar

    var body: some View {
        switch style {
        case .bar:
            Label(title, systemImage: symbol)
        case .round(let size):
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size)
                .background(DeckPalette.roundButton, in: Circle())
                .overlay(Circle().strokeBorder(DeckPalette.edge))
                .contentShape(Circle())
                .accessibilityLabel(title)
        case .key:
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(DeckPalette.legend)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DeckPalette.key, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DeckPalette.edge, lineWidth: 0.5))
                .contentShape(Rectangle())
                .accessibilityLabel(title)
        }
    }
}

/// The Shortcuts palette: Windows shortcuts by name (the one place with text labels).
struct ShortcutsMenu: View {
    let vm: VMViewModel
    var style: ChromeLabelStyle = .bar

    var body: some View {
        Menu {
            Section(L("编辑", "Edit")) {
                Button(L("复制", "Copy"), systemImage: "doc.on.doc") { WinKeys.combo([WinKeys.ctrl], 0x06) }
                Button(L("剪切", "Cut"), systemImage: "scissors") { WinKeys.combo([WinKeys.ctrl], 0x1b) }
                Button(L("粘贴", "Paste"), systemImage: "doc.on.clipboard") { WinKeys.combo([WinKeys.ctrl], 0x19) }
                Button(L("全选", "Select all"), systemImage: "selection.pin.in.out") { WinKeys.combo([WinKeys.ctrl], 0x04) }
                Button(L("保存", "Save"), systemImage: "square.and.arrow.down") { WinKeys.combo([WinKeys.ctrl], 0x16) }
                Button(L("查找", "Find"), systemImage: "text.magnifyingglass") { WinKeys.combo([WinKeys.ctrl], 0x09) }
            }
            Section(L("窗口", "Windows")) {
                Button(L("关闭标签页", "Close tab"), systemImage: "xmark.square") { WinKeys.combo([WinKeys.ctrl], 0x1a) }
                Button(L("关闭窗口（Alt+F4）", "Close window (Alt+F4)"), systemImage: "xmark.rectangle") { WinKeys.combo([WinKeys.alt], 0x3d) }
                Button(L("切换窗口（Alt+Tab）", "Switch windows (Alt+Tab)"), systemImage: "rectangle.2.swap") { WinIOSBridge.shared.sendAltTab() }
                Button(L("显示桌面", "Show desktop"), systemImage: "menubar.dock.rectangle") { WinKeys.desktop() }
                Button(L("贴靠布局", "Snap layouts"), systemImage: "rectangle.split.2x1") { WinKeys.snap() }
            }
            if !vm.isLinux {
                Section("Windows") {
                    Button(L("剪贴板历史", "Clipboard history"), systemImage: "list.clipboard") { WinKeys.clipboardHistory() }
                    Button(L("表情符号", "Emoji"), systemImage: "face.smiling") { WinKeys.emoji() }
                    Button(L("截图", "Snip"), systemImage: "camera.viewfinder") { WinKeys.snip() }
                    Button(L("文件资源管理器", "File Explorer"), systemImage: "folder") { WinKeys.explorer() }
                    Button(L("快速设置", "Quick Settings"), systemImage: "switch.2") { WinKeys.quickSettings() }
                    Button(L("通知", "Notifications"), systemImage: "bell") { WinKeys.notifications() }
                    Button(L("锁定", "Lock"), systemImage: "lock") { WinKeys.lock() }
                    Button(L("任务管理器", "Task Manager"), systemImage: "waveform.path.ecg") { WinKeys.taskManager() }
                    Button("Ctrl + Alt + Del", systemImage: "lock.shield") { WinIOSBridge.shared.sendCtrlAltDel() }
                }
            }
            Menu(L("功能键", "Function keys")) {
                ForEach(1...12, id: \.self) { n in
                    Button("F\(n)") { WinKeys.tap(UInt8(0x3a + n - 1)) }
                }
            }
            Button("Esc", systemImage: "escape") { WinIOSBridge.shared.sendEscape() }
        } label: {
            ChromeMenuLabel(title: L("快捷键", "Shortcuts"), symbol: "keyboard.badge.ellipsis", style: style)
        }
    }
}

/// Windows' own volume, from the keyboard's volume keys.
struct SoundMenu: View {
    var style: ChromeLabelStyle = .bar

    var body: some View {
        Menu {
            Button(L("音量加", "Volume up"), systemImage: "speaker.plus") { WinKeys.volumeUp() }
            Button(L("音量减", "Volume down"), systemImage: "speaker.minus") { WinKeys.volumeDown() }
            Button(L("静音 / 取消静音", "Mute / unmute"), systemImage: "speaker.slash") { WinKeys.mute() }
        } label: {
            ChromeMenuLabel(title: L("声音", "Sound"), symbol: "speaker.wave.2", style: style)
        }
    }
}

/// Clipboard: Windows' clipboard history, and typing the iPhone's clipboard into Windows (iOS asks
/// before the app reads it, and only on this tap).
struct ClipboardMenu: View {
    var style: ChromeLabelStyle = .bar

    var body: some View {
        Menu {
            if ClipboardSync.shared.forWindows {
                Button(L("把 iPhone 剪贴板发到 Windows", "Send the iPhone clipboard to Windows"),
                       systemImage: "arrow.right.doc.on.clipboard") {
                    Self.sendClipboard()
                }
            }
            Button(L("把 iPhone 剪贴板输入到 Windows", "Type the iPhone clipboard into Windows"),
                   systemImage: "doc.on.clipboard") {
                typeClipboard()
            }
            Button(L("Windows 剪贴板历史（Win+V）", "Windows clipboard history (Win+V)"),
                   systemImage: "list.clipboard") {
                WinKeys.clipboardHistory()
            }
        } label: {
            ChromeMenuLabel(title: L("剪贴板", "Clipboard"), symbol: "clipboard", style: style)
        }
    }

    /// To Windows' clipboard through the clipboard helper (iOS may ask "Allow Paste?" here, unlike the
    /// system Paste button), then pasted in Windows if that is on.
    @MainActor
    static func sendClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            ChromeModel.shared.showHint(L("iPhone 剪贴板里没有文字", "There is no text on the iPhone clipboard"), seconds: 2.5)
            return
        }
        ClipboardSync.shared.sendToWindows(text)
    }

    @MainActor
    static func typeClipboardText() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            ChromeModel.shared.showHint(L("iPhone 剪贴板里没有文字", "There is no text on the iPhone clipboard"), seconds: 2.5)
            return
        }
        let r = ClipboardTyper.type(text)
        let note = r.skipped > 0
            ? L("正在输入 \(r.typed) 个字符，跳过 \(r.skipped) 个（只能输入英文字符）",
                "Typing \(r.typed) characters; \(r.skipped) skipped (plain English characters only)")
            : L("正在输入 \(r.typed) 个字符", "Typing \(r.typed) characters")
        ChromeModel.shared.showHint(note, seconds: 2.5)
    }

    private func typeClipboard() { Self.typeClipboardText() }
}

/// More: posture, immersive, sign-in browser, apps, system keys, settings and power.
struct SessionMoreMenu: View {
    @ObservedObject var vm: VMViewModel
    @ObservedObject var chrome: ChromeModel
    /// Narrow screens: Sound and Clipboard are here instead of in the bar.
    var includeCompactExtras: Bool = false
    var deckExtras: Bool = false
    let showPower: () -> Void
    var rightClickArmed: Binding<Bool>? = nil
    var dragLocked: Binding<Bool>? = nil
    var style: ChromeLabelStyle = .bar

    var body: some View {
        Menu {
            if includeCompactExtras {
                Section {
                    SoundMenu()
                    ClipboardMenu()
                }
            }
            if deckExtras {
                Section(L("键盘和触控板", "Keyboard and trackpad")) {
                    Picker(selection: Binding(
                        get: { vm.deckLayout },
                        set: { layout in withAnimation(.snappy(duration: 0.2)) { vm.deckLayout = layout } }
                    )) {
                        Label(L("键盘和触控板", "Keyboard and trackpad"), systemImage: DeckLayout.split.iconName).tag(DeckLayout.split)
                        Label(L("只有触控板", "Trackpad only"), systemImage: DeckLayout.trackpad.iconName).tag(DeckLayout.trackpad)
                        Label(L("只有键盘", "Keyboard only"), systemImage: DeckLayout.keyboard.iconName).tag(DeckLayout.keyboard)
                    } label: {
                        Label(L("下半屏", "Lower half"), systemImage: "rectangle.split.1x2")
                    }
                    .pickerStyle(.menu)
                    if let rightClickArmed {
                        Toggle(L("下一次轻点为右键", "Next tap is a right click"), systemImage: "computermouse", isOn: rightClickArmed)
                    }
                    if let dragLocked {
                        Toggle(L("拖动锁定", "Drag lock"), systemImage: "hand.draw", isOn: dragLocked)
                    }
                    Button(L("旋转画面", "Rotate"), systemImage: "rotate.right") {
                        SceneOrientationController.rotateDeckOrientation()
                    }
                }
            }
            Section {
                if vm.supportsLaptopPosture {
                    Picker(selection: Binding(
                        get: { vm.postureMode },
                        set: { mode in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                vm.setPostureMode(mode, viewportSize: vm.viewportSize)
                            }
                        }
                    )) {
                        ForEach(PostureMode.allCases, id: \.self) { mode in
                            Label(mode.title, systemImage: mode.iconName).tag(mode)
                        }
                    } label: {
                        Label(L("姿态", "Posture"), systemImage: "laptopcomputer")
                    }
                    .pickerStyle(.menu)
                }
                Toggle(L("沉浸全屏", "Immersive"), systemImage: "arrow.up.left.and.arrow.down.right", isOn: Binding(
                    get: { chrome.isImmersive },
                    set: { on in withAnimation(.snappy(duration: 0.22)) { chrome.setImmersive(on, reason: "More menu") } }
                ))
                if !vm.isLinux {
                    Toggle(L("登录链接用 Safari 打开", "Sign-in links open in Safari"), systemImage: "safari", isOn: Binding(
                        get: { vm.useSafariForOAuth },
                        set: { _ in vm.toggleOAuthBrowserMode() }
                    ))
                }
            }
            if !vm.isLinux { // these run inside Windows
                Section(L("应用", "Apps")) {
                    Button("Claude Code", systemImage: "terminal") { vm.installClaudeCode() }
                    Button("Edge", systemImage: "globe") { vm.launchGuestEdgeBrowser() }
                    Button("Paint", systemImage: "paintbrush.pointed") { vm.launchGuestPaint() }
                }
            }
            Section {
                Button("Ctrl + Alt + Del", systemImage: "lock.shield") { WinIOSBridge.shared.sendCtrlAltDel() }
                Button(L("任务管理器", "Task Manager"), systemImage: "waveform.path.ecg") { vm.sendTaskManager() }
            }
            Section {
                Button(L("设置", "Settings"), systemImage: "gearshape") { vm.showSettings = true }
                Button(L("电源…", "Power…"), systemImage: "power") { showPower() }
            }
        } label: {
            ChromeMenuLabel(title: L("更多", "More"), symbol: style.isBar ? "ellipsis.circle" : "ellipsis", style: style)
        }
    }
}

// MARK: - Floating keyboard button and the hint

/// The keyboard button in thumb reach: bottom-right, or bottom-left after dragging it there, resting just
/// above the Windows taskbar (so the clock, the tray and the widgets button stay visible; it now sits where
/// Windows shows its notification toasts instead). It keeps clear of the camera island
/// (reservedRegions(kind: .occlusion)).
struct KeyboardFloatingButton: View {
    @ObservedObject var chrome: ChromeModel
    @ObservedObject var display = DisplaySettings.shared
    /// The area it sits in (the Windows screen), in the same coordinates as `occlusions`.
    let area: CGRect
    let occlusions: [CGRect]
    /// The guest's framebuffer in pixels (vm.fbWidth x vm.fbHeight; zero before the first frame).
    let framebuffer: CGSize
    /// The guest has a Windows taskbar at the bottom (not the Linux guest).
    let reservesTaskbar: Bool
    let action: () -> Void

    @State private var drag: CGFloat = 0
    private let size: CGFloat = 52
    private let margin: CGFloat = 16
    /// Room left between the button and the top of the Windows taskbar.
    private let taskbarGap: CGFloat = 8
    /// Windows 11's taskbar height in DIPs (it is always at the bottom edge).
    static let taskbarDIPs: CGFloat = 48

    var body: some View {
        let origin = restingOrigin()
        Button(action: action) {
            Image(systemName: "keyboard")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("键盘", "Keyboard"))
        .accessibilityHint(L("拖到另一侧可以换到左下角或右下角", "Drag to the other side to move it to the other corner"))
        .contextMenu {
            Button(L("隐藏键盘按钮", "Hide Keyboard Button"), systemImage: "eye.slash") {
                withAnimation(.snappy(duration: 0.2)) { chrome.keyboardButtonShown = false }
                chrome.showHint(L("键盘按钮已隐藏：用控制栏里的“键盘”，或在设置 › 键盘里打开。",
                                  "Keyboard button hidden: use Keyboard in the controls, or turn it back on in Settings › Keyboard."))
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation.width }
                .onEnded { value in
                    let endX = origin.x + size / 2 + value.translation.width
                    let left = endX < area.midX
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        drag = 0
                        if left != chrome.keyboardButtonOnLeft {
                            chrome.keyboardButtonOnLeft = left
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        }
                    }
                }
        )
        .offset(x: origin.x + drag, y: origin.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Its corner, above the Windows taskbar, then moved up past any occluded region it would sit under.
    private func restingOrigin() -> CGPoint {
        let x = chrome.keyboardButtonOnLeft ? area.minX + margin : area.maxX - margin - size
        var bottom = area.maxY - margin
        if reservesTaskbar {
            let pct = Self.taskbarScale(framebuffer: framebuffer, plan: display.plan, applied: display.applied)
            bottom = min(bottom, Self.taskbarTop(area: area, framebuffer: framebuffer, scalePercent: pct) - taskbarGap)
        }
        var y = bottom - size
        for r in occlusions where r.intersects(CGRect(x: x, y: y, width: size, height: size).insetBy(dx: -6, dy: -6)) {
            y = min(y, r.minY - size - margin)
        }
        return CGPoint(x: x, y: max(area.minY + margin, y))
    }

    /// Windows' scale for the framebuffer on screen: what the WinKit helper reported Windows took for that
    /// mode, else the scale planned for it, else Windows' recommended one (0: unknown). The plan's scale
    /// belongs to the plan's mode only, which differs while Windows has not taken a new size yet.
    static func taskbarScale(framebuffer fb: CGSize, plan: WinIOSDisplayPlan, applied: WinIOSDisplayApplied) -> UInt32 {
        let w = UInt32(max(0, fb.width)), h = UInt32(max(0, fb.height))
        if applied.scalePercent > 0 && applied.modeWidth == w && applied.modeHeight == h { return applied.scalePercent }
        if plan.legacy == 0 && plan.scalePercent > 0 && plan.modeWidth == w && plan.modeHeight == h { return plan.scalePercent }
        return applied.recommendedPercent
    }

    /// The top of the Windows taskbar in `area`'s coordinates: 48 DIPs at Windows' scale (150% when
    /// unknown), through the picture's aspect fit in `area` (as MetalCanvasUIView maps touches), kept to
    /// 20 points ... a quarter of the area. Before the first frame: a 64-point band.
    static func taskbarTop(area: CGRect, framebuffer fb: CGSize, scalePercent: UInt32) -> CGFloat {
        guard fb.width > 0, fb.height > 0, area.width > 0, area.height > 0 else { return area.maxY - 64 }
        let ppp = min(area.width / fb.width, area.height / fb.height) // points per framebuffer pixel
        let pictureBottom = area.midY + fb.height * ppp / 2
        let pct = CGFloat(scalePercent > 0 ? scalePercent : 150)
        let band = taskbarDIPs * pct / 100 * ppp
        return pictureBottom - min(max(band, 20), area.height * 0.25)
    }
}

/// A short note at the top of the Windows screen (how to get the controls back, clipboard typing).
struct ChromeHintView: View {
    let text: String
    let area: CGRect
    let occlusions: [CGRect]

    var body: some View {
        let top = hintTop()
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .frame(maxWidth: max(0, min(area.width - 32, 520)))
            .frame(width: area.width)
            .offset(x: area.minX, y: top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// Below the camera island when it reaches into the top of the area.
    private func hintTop() -> CGFloat {
        var y = area.minY + 14
        let band = CGRect(x: area.minX, y: y, width: area.width, height: 44)
        for r in occlusions where r.intersects(band) { y = max(y, r.maxY + 8) }
        return y
    }
}
