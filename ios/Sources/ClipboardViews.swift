// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// "Paste to Windows": the system paste button (PasteButton / UIPasteControl). Tapping it is the person's
/// own paste, so iOS never asks "Allow Paste?" for it. Mount it anywhere, e.g. in a toolbar.
struct ClipboardButton: View {
    /// With "to Windows" next to the system's "Paste" label; icon only otherwise.
    var labeled = false

    var body: some View {
        HStack(spacing: 6) {
            PasteButton(payloadType: String.self) { strings in
                let text = strings.joined(separator: "\n")
                DispatchQueue.main.async { ClipboardSync.shared.sendToWindows(text) }
            }
            .labelStyle(labeled ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.accentColor)
            if labeled {
                Text(L("到 Windows", "to Windows")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint(L("把 iPhone 剪贴板里的文字发到 Windows 的剪贴板", "Sends the text on the iPhone's clipboard to Windows' clipboard"))
    }
}

/// A label style chosen at run time (PasteButton takes any).
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// The clipboard's settings and the helper's status, as a Form section. Mount it in a settings Form.
struct ClipboardSettingsSection: View {
    @ObservedObject private var sync = ClipboardSync.shared

    var body: some View {
        Section {
            Toggle(L("Windows → iPhone 自动同步", "Windows → iPhone automatically"), isOn: $sync.fromWindows)
            Toggle(L("回到 App 时 iPhone → Windows", "iPhone → Windows when returning to the app"), isOn: $sync.toWindowsOnActivate)
            if sync.toWindowsOnActivate {
                HStack {
                    LabeledContent(L("从其他 App 粘贴", "Paste from other apps"), value: permissionText)
                    Button(L("检查", "Check")) { sync.checkPastePermission() }
                        .buttonStyle(.borderless)
                }
                if sync.pastePermission != .allowed {
                    Button(L("打开 iOS 设置", "Open iOS Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
            Toggle(L("点粘贴按钮后在 Windows 里粘贴（Ctrl+V）", "Paste into Windows after tapping Paste"), isOn: $sync.pasteAfterSend)
            HStack {
                Text(L("粘贴到 Windows", "Paste to Windows"))
                Spacer()
                ClipboardButton()
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                LabeledContent(L("Windows 里的剪贴板小助手", "Clipboard helper in Windows"), value: helperText)
            }
        } header: {
            Text(L("剪贴板", "Clipboard"))
        } footer: {
            Text(L("Windows 里拷贝的文字会自动出现在 iPhone 的剪贴板上（App 在前台时）。iPhone → Windows 用粘贴按钮，iOS 不会弹出询问。想在回到 App 时自动发送，需要在 iOS 设置 › Apple VM › 从其他 App 粘贴 里选“允许”（这一项在 App 第一次读剪贴板后才出现），然后点“检查”。Windows 那边需要 WinKit 的剪贴板小助手：运行 WINKIT 盘里的 START.bat 或 CLIPBOARD.bat。只同步文字，最多 1 MB。",
                   "Text copied in Windows appears on the iPhone's clipboard (while the app is in front). iPhone → Windows goes through the paste button, which iOS never asks about. To send by itself when you return to the app, set iOS Settings › Apple VM › Paste from Other Apps › Allow (the item appears after the app first reads the clipboard), then tap Check. Windows needs WinKit's clipboard helper: run START.bat or CLIPBOARD.bat from the WINKIT drive. Text only, up to 1 MB."))
        }
    }

    private var permissionText: String {
        switch sync.pastePermission {
        case .allowed: return L("允许", "Allow")
        case .ask: return L("每次询问：自动发送已暂停", "Ask: automatic sending paused")
        case .denied: return L("拒绝", "Deny")
        case .unknown: return L("未检查", "Not checked")
        }
    }

    private var helperText: String {
        guard WinIOSBridge.shared.isVMRunning else { return L("Windows 没在运行", "Windows is not running") }
        let seen = sync.helperSeenSeconds
        if seen < 0 { return L("未运行（运行 CLIPBOARD.bat）", "Not running (run CLIPBOARD.bat)") }
        if seen < ClipboardSync.helperAliveSeconds { return L("运行中", "Running") }
        return L("\(seen) 秒前", "Last heard \(seen) s ago")
    }
}

extension View {
    /// Starts the clipboard sync and shows its short confirmations at the bottom of this view.
    func clipboardSync() -> some View { modifier(ClipboardSyncModifier()) }
}

private struct ClipboardSyncModifier: ViewModifier {
    @ObservedObject private var sync = ClipboardSync.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = sync.toast {
                    Label(toast.text, systemImage: toast.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                        .padding(.bottom, 28)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.snappy(duration: 0.25), value: sync.toast)
            .onAppear { sync.start() }
    }
}
