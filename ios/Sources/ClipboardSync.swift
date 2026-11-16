// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// The clipboard shared with Windows (docs/clipboard.md). host/share.c keeps one slot of text; the
/// WinKit clipboard helper in Windows (winkit/clipboard_agent.cs) sends what Windows copies and waits for
/// what this side puts there.
///
/// Windows → iPhone: writing UIPasteboard never asks the person anything, so what Windows copies is put on
/// the iPhone's clipboard right away while the app is in front, or as soon as it is again.
///
/// iPhone → Windows: an app that reads the clipboard by itself gets iOS's "Allow Paste" question, unless
/// the person set Settings › Apple VM › Paste from Other Apps › Allow. So it goes through the system's
/// paste button (ClipboardButton), which never asks, and only by itself when the person switched that on
/// AND the app found the permission to be Allow (checkPastePermission, which runs only when the person
/// asks for it). Before reading, hasStrings and changeCount (neither asks) skip a clipboard with no text
/// or nothing new.
final class ClipboardSync: ObservableObject {
    static let shared = ClipboardSync()

    /// What reading the clipboard does, as far as the app could tell.
    enum PastePermission: String {
        case unknown, allowed, ask, denied
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    private enum Key {
        static let fromWindows = "winios.clip.fromWindows"
        static let toWindowsOnActivate = "winios.clip.toWindowsOnActivate"
        static let pasteAfterSend = "winios.clip.pasteAfterSend"
        static let permission = "winios.clip.pastePermission"
        static let changeCount = "winios.clip.changeCount"
    }

    /// The share server's limit (HV_SHARE_CLIP_MAX).
    static let maxBytes = 1 << 20
    /// The helper asks again at most 25 s apart.
    static let helperAliveSeconds = 40
    /// Notification name of WinIOSGuestClipboardDidChangeNotification (winios_bridge.m).
    static let guestChanged = Notification.Name("WinIOSGuestClipboardDidChange")

    @Published var fromWindows: Bool {
        didSet { defaults.set(fromWindows, forKey: Key.fromWindows) }
    }
    @Published var toWindowsOnActivate: Bool {
        didSet {
            defaults.set(toWindowsOnActivate, forKey: Key.toWindowsOnActivate)
            if toWindowsOnActivate && !oldValue && pastePermission != .allowed { checkPastePermission() }
        }
    }
    @Published var pasteAfterSend: Bool {
        didSet { defaults.set(pasteAfterSend, forKey: Key.pasteAfterSend) }
    }
    @Published private(set) var pastePermission: PastePermission {
        didSet { defaults.set(pastePermission.rawValue, forKey: Key.permission) }
    }
    /// A short confirmation ("Copied from Windows"), gone by itself.
    @Published private(set) var toast: Toast?

    private let defaults = UserDefaults.standard
    private var bridge: WinIOSBridge { WinIOSBridge.shared }
    private var started = false
    private var observers: [NSObjectProtocol] = []
    /// What Windows copied while the app was not in front.
    private var pendingFromWindows: String?
    /// UIPasteboard.changeCount when the app last wrote the clipboard or sent it: anything else is new.
    private var knownChangeCount: Int {
        didSet { defaults.set(knownChangeCount, forKey: Key.changeCount) }
    }
    private var toastGeneration = 0

    private init() {
        fromWindows = defaults.object(forKey: Key.fromWindows) as? Bool ?? true
        toWindowsOnActivate = defaults.bool(forKey: Key.toWindowsOnActivate)
        pasteAfterSend = defaults.bool(forKey: Key.pasteAfterSend)
        pastePermission = PastePermission(rawValue: defaults.string(forKey: Key.permission) ?? "") ?? .unknown
        knownChangeCount = defaults.object(forKey: Key.changeCount) as? Int ?? -1
    }

    /// Once, from the main thread (the .clipboardSync() modifier does it).
    func start() {
        guard !started else { return }
        started = true
        bridge.startClipboardObserver()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Self.guestChanged, object: nil, queue: .main) { [weak self] _ in
            self?.guestCopied()
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.becameActive()
        })
        if UIApplication.shared.applicationState == .active { becameActive() }
    }

    // MARK: - Windows → iPhone

    private func guestCopied() {
        guard let text = bridge.takeGuestClipboard() else { return }
        guard fromWindows else { return } // taken, so that it does not arrive later
        if UIApplication.shared.applicationState == .active {
            putOnPasteboard(text)
        } else {
            pendingFromWindows = text // the newest wins
        }
    }

    private func putOnPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        knownChangeCount = UIPasteboard.general.changeCount
        show(L("已从 Windows 拷贝", "Copied from Windows"), symbol: "doc.on.clipboard")
    }

    private func becameActive() {
        if let text = pendingFromWindows ?? bridge.takeGuestClipboard() {
            pendingFromWindows = nil
            if fromWindows { putOnPasteboard(text) }
        }
        sendOnActivationIfAllowed()
    }

    // MARK: - iPhone → Windows

    /// From the system paste button: the person chose to paste, nothing is asked. Always sent, even when
    /// the shared clipboard holds this text already (Windows may have copied a picture since).
    func sendToWindows(_ text: String) {
        knownChangeCount = UIPasteboard.general.changeCount
        send(text, force: true)
    }

    private func sendOnActivationIfAllowed() {
        guard toWindowsOnActivate, pastePermission == .allowed, bridge.isVMRunning else { return }
        let board = UIPasteboard.general
        guard board.changeCount != knownChangeCount else { return } // nothing new, or what came from Windows
        knownChangeCount = board.changeCount
        guard board.hasStrings else { return } // a picture, or nothing: not read
        let (text, asked) = readPasteboard()
        if asked {
            // iOS asked after all: the setting was changed. Not by itself again until checked.
            pastePermission = .ask
        } else if text == nil {
            pastePermission = .denied
        }
        if let text { send(text, force: false) }
    }

    private func send(_ text: String, force: Bool) {
        guard !text.isEmpty else { return }
        guard text.utf8.count <= Self.maxBytes else {
            show(L("内容太大（超过 1 MB），没有发送", "Too large for Windows (over 1 MB): not sent"), symbol: "exclamationmark.triangle")
            return
        }
        let seq = bridge.sendClipboard(toGuest: text, force: force)
        guard seq != 0 else { return } // Windows has this text already
        guard bridge.isVMRunning && helperRunning else {
            show(L("Windows 里的剪贴板小助手没在运行", "Windows' clipboard helper is not running"), symbol: "exclamationmark.triangle")
            return
        }
        show(L("已发送到 Windows", "Sent to Windows"), symbol: "arrow.up.doc.on.clipboard")
        if pasteAfterSend { pasteWhenWindowsHasIt(seq, deadline: Date().addingTimeInterval(2.5)) }
    }

    /// Ctrl+V once the helper has put seq on Windows' clipboard (it asks for the next one only then).
    private func pasteWhenWindowsHasIt(_ seq: UInt, deadline: Date) {
        if bridge.clipboardAgentHasSeq() >= seq {
            bridge.sendPasteShortcut()
            return
        }
        guard Date() < deadline else {
            show(L("Windows 没有及时收到，未粘贴", "Windows did not get it in time: not pasted"), symbol: "exclamationmark.triangle")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.pasteWhenWindowsHasIt(seq, deadline: deadline)
        }
    }

    // MARK: - Paste permission

    /// Reads the clipboard and tells whether iOS asked first: the read waits for the person's answer.
    private func readPasteboard() -> (String?, Bool) {
        let start = CACurrentMediaTime()
        let text = UIPasteboard.general.string
        return (text, CACurrentMediaTime() - start > 0.35)
    }

    /// Finds out what reading the clipboard does. iOS has no call that says it, so this reads once (only
    /// when the person asks: switching the automatic mode on, or "Check" in settings), and a question
    /// from iOS then is expected. Reading what this app wrote itself never asks, so that tells nothing.
    func checkPastePermission() {
        let board = UIPasteboard.general
        guard board.hasStrings, board.changeCount != knownChangeCount else {
            pastePermission = .unknown
            show(L("先在别的 App 里拷贝一段文字，再检查", "Copy some text in another app first, then check"), symbol: "info.circle")
            return
        }
        let (text, asked) = readPasteboard()
        knownChangeCount = board.changeCount // looked at, not sent
        pastePermission = asked ? .ask : text == nil ? .denied : .allowed
    }

    // MARK: - Status

    /// Seconds since the helper in Windows was heard from (0 while it waits for news), -1 never.
    var helperSeenSeconds: Int { bridge.clipboardAgentSeenSeconds() }

    var helperRunning: Bool {
        let seen = helperSeenSeconds
        return seen >= 0 && seen < Self.helperAliveSeconds
    }

    // MARK: - Confirmation

    private func show(_ text: String, symbol: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast = Toast(text: text, symbol: symbol)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            self.toast = nil
        }
    }
}
