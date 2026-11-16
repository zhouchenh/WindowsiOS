// SPDX-License-Identifier: GPL-2.0-or-later
import QuartzCore
import UIKit

// Typing into Windows from the iOS keyboard, and the keyboard following Windows' focus.
//
// Text: plain ASCII goes to Windows as USB keyboard keys (works everywhere, also on the sign-in screen and
// in administrator windows). Everything else (Chinese, accents, emoji) is typed by the WinKit focus agent
// (winkit/FocusAgent.cs) with Unicode key events. Composing keyboards (Pinyin, Japanese...) need marked
// text, so the canvas is a minimal UITextInput whose document is only the text being composed: Windows
// gets the committed text, never the composition.
//
// Focus: the agent reports the focused element (text box, password box, neither), the caret and the
// foreground program. A tap into a text box raises the keyboard, a tap elsewhere lowers it, and the
// picture slides so the caret stays above the keys. Without the agent: the tap point stands in for the caret.

/// Switches, from Documents/env.txt (HV_*) and the app's settings (UserDefaults).
enum KeyboardOptions {
    private static func env(_ name: String) -> String? {
        guard let v = getenv(name) else { return nil }
        return String(cString: v)
    }

    private static func setting(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    /// HV_KBD_PAN=0: the canvas shrinks above the keyboard as before, no panning.
    static var panInsteadOfShrink: Bool { env("HV_KBD_PAN") != "0" }
    /// HV_FOCUS=0: reports of the focus agent are ignored.
    static var focusReports: Bool { env("HV_FOCUS") != "0" }
    /// Keyboard comes up in text boxes (winios.keyboard.autoShow, default on; HV_KBD_AUTOSHOW=0: off).
    static var autoShow: Bool { env("HV_KBD_AUTOSHOW") != "0" && setting("winios.keyboard.autoShow", default: true) }
    /// The picture follows the caret (winios.keyboard.follow, default on).
    static var followCaret: Bool { setting("winios.keyboard.follow", default: true) }
    /// HV_UNICODE_TEXT=0: ASCII only, as before (the ASCII-capable keyboard).
    static var unicodeText: Bool { env("HV_UNICODE_TEXT") != "0" }
    /// HV_PINCH_CTRL_WHEEL=0: a pinch is not sent to Windows as Ctrl + wheel.
    static var pinchToWindows: Bool { env("HV_PINCH_CTRL_WHEEL") != "0" }
}

/// What the focus agent says (see winkit/FocusAgent.cs).
struct FocusReport {
    var seq: Int
    var event: String
    var kind: String          // text | secure | none
    var elem: CGRect?         // Windows pixels
    var caret: CGRect?        // Windows pixels
    var framebuffer: CGSize   // what the agent sees as the screen size
    var exe: String
    var lang: String
    var secureDesktop: Bool
    var source: String
    var receivedAt: CFTimeInterval

    var isText: Bool { kind == "text" || kind == "secure" }

    init?(_ d: [AnyHashable: Any]) {
        guard let kind = d["kind"] as? String else { return nil }
        func rect(_ k: String) -> CGRect? {
            guard let a = d[k] as? [NSNumber], a.count == 4, a[3].doubleValue > 0 else { return nil }
            return CGRect(x: a[0].doubleValue, y: a[1].doubleValue, width: max(1, a[2].doubleValue), height: a[3].doubleValue)
        }
        self.kind = kind
        seq = (d["seq"] as? NSNumber)?.intValue ?? 0
        event = d["event"] as? String ?? "focus"
        elem = rect("elem")
        caret = rect("caret")
        if let fb = d["fb"] as? [NSNumber], fb.count == 2 {
            framebuffer = CGSize(width: fb[0].doubleValue, height: fb[1].doubleValue)
        } else {
            framebuffer = .zero
        }
        exe = d["exe"] as? String ?? ""
        lang = d["lang"] as? String ?? ""
        secureDesktop = (d["secureDesktop"] as? NSNumber)?.boolValue ?? false
        source = d["source"] as? String ?? ""
        receivedAt = CACurrentMediaTime()
    }
}

/// What can be checked on the device: Documents/keyboard_status.txt (rewritten at most once a second)
/// and "keyboard:" lines in winvm.log. statusLine is meant for Settings > Status.
final class KeyboardDiagnostics {
    static let shared = KeyboardDiagnostics()

    var lastReport: FocusReport?
    var reports = 0
    var autoShows = 0
    var autoHides = 0
    var unicodeSent = 0
    var unicodeUndeliverable = 0
    var pans = 0
    var keyboardOverlap: CGFloat = 0
    var viewHeight: CGFloat = 0
    var zoom: CGFloat = 1
    private var lastWrite: CFTimeInterval = 0
    private var pendingWrite = false

    var statusLine: String {
        let seen = WinIOSBridge.shared.focusAgentSeenSeconds
        let agent = seen < 0 ? L("未连接", "not connected") : seen <= 45 ? L("已连接", "connected") : L("无响应", "silent") + " \(seen)s"
        var s = L("焦点助手", "Focus agent") + ": " + agent
        if let r = lastReport {
            s += " · \(r.kind) (\(r.source))"
            if !r.exe.isEmpty { s += " · \(r.exe)" }
            if !r.lang.isEmpty { s += " · \(r.lang)" }
        }
        s += String(format: " · zoom %.1f", zoom)
        return s
    }

    func log(_ line: String) {
        fputs("keyboard: \(line)\n", stderr)
        changed()
    }

    func changed() {
        let now = CACurrentMediaTime()
        if now - lastWrite >= 1 {
            write()
        } else if !pendingWrite {
            pendingWrite = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.pendingWrite = false
                self?.write()
            }
        }
    }

    private func write() {
        lastWrite = CACurrentMediaTime()
        let r = lastReport
        func rs(_ c: CGRect?) -> String {
            guard let c else { return "-" }
            return String(format: "%.0f,%.0f %.0fx%.0f", c.minX, c.minY, c.width, c.height)
        }
        let text = """
        agent_seen_sec: \(WinIOSBridge.shared.focusAgentSeenSeconds)
        reports: \(reports)
        last_event: \(r?.event ?? "-")
        last_kind: \(r?.kind ?? "-")
        last_source: \(r?.source ?? "-")
        last_exe: \(r?.exe ?? "-")
        last_lang: \(r?.lang ?? "-")
        last_caret: \(rs(r?.caret))
        last_elem: \(rs(r?.elem))
        agent_fb: \(r.map { String(format: "%.0fx%.0f", $0.framebuffer.width, $0.framebuffer.height) } ?? "-")
        secure_desktop: \(r?.secureDesktop ?? false)
        auto_shows: \(autoShows)
        auto_hides: \(autoHides)
        unicode_sent: \(unicodeSent)
        unicode_undeliverable: \(unicodeUndeliverable)
        pans: \(pans)
        keyboard_overlap_pt: \(Int(keyboardOverlap))
        canvas_height_pt: \(Int(viewHeight))
        zoom: \(String(format: "%.2f", zoom))
        options: pan=\(KeyboardOptions.panInsteadOfShrink) focus=\(KeyboardOptions.focusReports) autoshow=\(KeyboardOptions.autoShow) follow=\(KeyboardOptions.followCaret) unicode=\(KeyboardOptions.unicodeText) pinch=\(KeyboardOptions.pinchToWindows)

        """
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = docs?.appendingPathComponent("keyboard_status.txt") else { return }
        DispatchQueue.global(qos: .utility).async { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - The composing document

final class CanvasTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class CanvasTextRange: UITextRange {
    let lo: Int, hi: Int
    init(_ a: Int, _ b: Int) {
        lo = min(a, b)
        hi = max(a, b)
    }

    override var start: UITextPosition { CanvasTextPosition(lo) }
    override var end: UITextPosition { CanvasTextPosition(hi) }
    override var isEmpty: Bool { lo == hi }
}

/// The text being composed (marked), and the selection inside it. Committed text is not kept.
final class TextInputDocument {
    var marked: NSString = ""
    var selection = NSRange(location: 0, length: 0)
    var length: Int { marked.length }
}

// MARK: - UIKeyInput / UITextInput

extension MetalCanvasUIView {
    var hasText: Bool { true } // Backspace always reaches Windows

    func insertText(_ text: String) {
        if textDoc.length > 0 {
            // a candidate chosen: it replaces the composition
            textDoc.marked = ""
            textDoc.selection = NSRange(location: 0, length: 0)
        }
        deliverText(text)
    }

    func deleteBackward() {
        if textDoc.length > 0 {
            // inside the composition: it stays here
            var sel = textDoc.selection
            if sel.length == 0 && sel.location > 0 { sel = NSRange(location: sel.location - 1, length: 1) }
            if sel.length > 0 && NSMaxRange(sel) <= textDoc.length {
                textDoc.marked = textDoc.marked.replacingCharacters(in: sel, with: "") as NSString
                textDoc.selection = NSRange(location: sel.location, length: 0)
            }
            return
        }
        // after text the agent is still typing: Backspace goes the same way, or it would overtake it
        if !keys.hasActiveModifiers, KeyboardOptions.unicodeText, WinIOSBridge.shared.unicodeTextBusy,
           WinIOSBridge.shared.sendUnicodeText("\u{8}") {
            return
        }
        sendKey(0x2a, withShift: false)
    }

    /// Committed text to Windows: USB keys for ASCII, the focus agent for the rest.
    func deliverText(_ text: String) {
        guard !text.isEmpty else { return }
        let bridge = WinIOSBridge.shared
        let mapped = text.map { Self.asciiToHID($0) }
        let ascii = !mapped.contains { $0 == nil }
        // a latched Ctrl/Alt/Win makes it a shortcut: always keys
        if ascii && (keys.hasActiveModifiers || !KeyboardOptions.unicodeText || !bridge.unicodeTextBusy) {
            for m in mapped { if let m { sendKey(m.0, withShift: m.1) } }
            return
        }
        if KeyboardOptions.unicodeText && bridge.sendUnicodeText(text) {
            KeyboardDiagnostics.shared.unicodeSent += text.count
            keys.consumeOnce()
            return
        }
        var lost = 0
        for m in mapped {
            if let m { sendKey(m.0, withShift: m.1) } else { lost += 1 }
        }
        if lost > 0 {
            KeyboardDiagnostics.shared.unicodeUndeliverable += lost
            KeyboardDiagnostics.shared.log("\(lost) characters not typed: no WinKit focus agent")
            keyBar.showNotice(L("中文、表情等需要 Windows 里的 WinKit 小助手（运行 WINKIT 盘上的 START.bat）",
                                "Chinese, accents and emoji need the WinKit helper in Windows (START.bat on the WINKIT drive)"))
        }
    }

    func text(in range: UITextRange) -> String? {
        guard let r = range as? CanvasTextRange else { return nil }
        let lo = min(r.lo, textDoc.length), hi = min(r.hi, textDoc.length)
        return textDoc.marked.substring(with: NSRange(location: lo, length: hi - lo))
    }

    func replace(_ range: UITextRange, withText text: String) {
        // only the composition is here: replacing any of it commits the result
        guard let r = range as? CanvasTextRange, textDoc.length > 0 else {
            deliverText(text)
            return
        }
        let lo = min(r.lo, textDoc.length), hi = min(r.hi, textDoc.length)
        textDoc.marked = textDoc.marked.replacingCharacters(in: NSRange(location: lo, length: hi - lo), with: text) as NSString
        textDoc.selection = NSRange(location: lo + (text as NSString).length, length: 0)
    }

    var selectedTextRange: UITextRange? {
        get { CanvasTextRange(textDoc.selection.location, NSMaxRange(textDoc.selection)) }
        set {
            guard let r = newValue as? CanvasTextRange else { return }
            let lo = min(r.lo, textDoc.length), hi = min(r.hi, textDoc.length)
            textDoc.selection = NSRange(location: lo, length: hi - lo)
        }
    }

    var markedTextRange: UITextRange? {
        textDoc.length > 0 ? CanvasTextRange(0, textDoc.length) : nil
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let t = (markedText ?? "") as NSString
        textDoc.marked = t
        let loc = min(selectedRange.location == NSNotFound ? t.length : selectedRange.location, t.length)
        textDoc.selection = NSRange(location: loc, length: min(selectedRange.length, t.length - loc))
    }

    func unmarkText() {
        let t = textDoc.marked as String
        textDoc.marked = ""
        textDoc.selection = NSRange(location: 0, length: 0)
        deliverText(t)
    }

    /// Windows moved the focus while something was being composed: the composition is dropped.
    func discardComposition() {
        guard textDoc.length > 0 else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        textDoc.marked = ""
        textDoc.selection = NSRange(location: 0, length: 0)
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    var beginningOfDocument: UITextPosition { CanvasTextPosition(0) }
    var endOfDocument: UITextPosition { CanvasTextPosition(textDoc.length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = fromPosition as? CanvasTextPosition, let b = toPosition as? CanvasTextPosition else { return nil }
        return CanvasTextRange(a.offset, b.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? CanvasTextPosition else { return nil }
        let o = p.offset + offset
        return o >= 0 && o <= textDoc.length ? CanvasTextPosition(o) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: return self.position(from: position, offset: -offset)
        default: return self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? CanvasTextPosition)?.offset ?? 0
        let b = (other as? CanvasTextPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? CanvasTextPosition)?.offset ?? 0) - ((from as? CanvasTextPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: return range.start
        default: return range.end
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? CanvasTextPosition else { return nil }
        switch direction {
        case .left, .up: return CanvasTextRange(0, p.offset)
        default: return CanvasTextRange(p.offset, textDoc.length)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .natural
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// Where the candidates (on iPad) and the text loupe point: at Windows' caret, or the tap point.
    func firstRect(for range: UITextRange) -> CGRect { caretRectOnScreen() }
    func caretRect(for position: UITextPosition) -> CGRect { caretRectOnScreen() }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    private func caretRectOnScreen() -> CGRect {
        if let t = panTarget() { return viewport.project(t) }
        return CGRect(x: bounds.midX, y: bounds.midY, width: 2, height: 20)
    }
}

// MARK: - Following Windows' focus

extension MetalCanvasUIView {
    @objc func focusReportArrived(_ note: Notification) {
        guard let d = note.userInfo?["report"] as? [AnyHashable: Any], let r = FocusReport(d) else { return }
        let diag = KeyboardDiagnostics.shared
        let previous = lastFocus
        diag.lastReport = r
        diag.reports += 1
        diag.changed()
        guard KeyboardOptions.focusReports else { return }
        lastFocus = r
        keyBar.miniMap.caretFramebufferRect = r.caret.map { scaleToFramebuffer($0, from: r.framebuffer) }
        floatingMap?.caretFramebufferRect = keyBar.miniMap.caretFramebufferRect

        let now = CACurrentMediaTime()
        let recentTouch = now - lastTouchAt < 1.2
        let canAuto = KeyboardOptions.autoShow && keyboardResizesView && !hardwareKeyboard

        switch r.event {
        case "focus", "foreground":
            discardComposition()
            pendingHide?.cancel()
            pendingHide = nil
            keyBar.showNotice(r.kind == "secure" ? L("密码框：输入的内容不会显示在这里", "Password field: what you type isn't shown here") : nil,
                              persistent: true)
            if r.isText {
                updateSecureEntry(r.kind == "secure")
                if canAuto && recentTouch && !isFirstResponder {
                    keyboardAutoShown = true
                    diag.autoShows += 1
                    diag.log("focus \(r.kind) (\(r.source)) in \(r.exe): keyboard up")
                    onKeyboardRequested?()
                } else if isFirstResponder {
                    followCaret(animated: true)
                }
            } else if canAuto && recentTouch && isFirstResponder && (keyboardAutoShown || (previous?.isText ?? false)) {
                // a little grace: moving from one box to the next must not drop the keyboard in between
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isFirstResponder, !(self.lastFocus?.isText ?? false) else { return }
                    diag.autoHides += 1
                    diag.log("focus none in \(self.lastFocus?.exe ?? "?"): keyboard down")
                    self.keyboardAutoShown = false
                    self.dismissKeyboard()
                }
                pendingHide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        case "caret":
            followCaret(animated: true)
        case "typefail":
            keyBar.showNotice(L("Windows 没有接收这些文字（管理员窗口或登录界面只能用英文键盘输入）",
                                "Windows didn't take that text (administrator windows and the sign-in screen take only plain keys)"))
            diag.log("the agent could not type in \(r.exe)")
        default:
            break
        }
    }

    /// The agent's rectangles are in its own idea of the screen size; Windows' framebuffer may differ
    /// (scaling): rescale.
    func scaleToFramebuffer(_ r: CGRect, from agentFB: CGSize) -> CGRect {
        let fb = viewport.framebufferSize
        guard agentFB.width > 0, agentFB.height > 0, fb.width > 0, fb.height > 0 else { return r }
        let sx = fb.width / agentFB.width, sy = fb.height / agentFB.height
        return CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    /// What must stay visible above the keyboard, in unzoomed picture points: Windows' caret (fresh, in a
    /// text box), else the bottom of the focused box, else where the finger last tapped.
    func panTarget() -> CGRect? {
        if let r = lastFocus, r.isText, CACurrentMediaTime() - r.receivedAt < 120 {
            if let c = r.caret {
                return viewport.pictureRect(fromFramebuffer: scaleToFramebuffer(c, from: r.framebuffer))
            }
            if let e = r.elem {
                let p = viewport.pictureRect(fromFramebuffer: scaleToFramebuffer(e, from: r.framebuffer))
                return CGRect(x: p.minX, y: max(p.minY, p.maxY - 28), width: min(p.width, 40), height: min(p.height, 28))
            }
        }
        if let p = lastTapPicturePoint {
            return CGRect(x: p.x - 4, y: p.y - 14, width: 8, height: 28)
        }
        return nil
    }

    func followCaret(animated: Bool) {
        guard KeyboardOptions.followCaret, isFirstResponder || viewport.isZoomed, let t = panTarget() else { return }
        KeyboardDiagnostics.shared.pans += 1
        viewport.reveal(t, band: viewport.isZoomed && !isFirstResponder ? ViewportController.followBand : nil,
                        duration: animated ? 0.18 : 0)
    }

    private func updateSecureEntry(_ secure: Bool) {
        guard isSecureTextEntry != secure else { return }
        isSecureTextEntry = secure // no learning, no suggestions while typing a password
        if isFirstResponder { reloadInputViews() }
    }
}
