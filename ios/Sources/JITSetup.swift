// SPDX-License-Identifier: GPL-2.0-or-later
//
// Getting from "opened without JIT" to "JIT is live" with StikDebug, and keeping that reliable:
// - a debugger that attaches late (StikDebug can bring the app back before it attaches) is still
//   noticed: after each activation the app watches for one for about 10 s;
// - one request at a time (a second StikDebug session that attaches after the first let go stays
//   attached, and then every trap stops Windows until it answers);
// - a debugger still attached after the JIT region is held is told to let go (winios_jit.c);
// - LocalDevVPN, which StikDebug reaches this device through: checked, and connected first when it
//   is installed, coming back through the applevm:// URL scheme;
// - "Turn on JIT when the app opens";
// - failures say what to check.
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: JITBootstrap.swift (requestAttach,
// releaseLingeringDebugger), JITSetup.swift (busy guard, awaitStikDebug, LocalDevVPN, enableAtLaunchIfAsked)
// and HengeApp.swift (the poll after each activation). Henge commits 294d017 (liukaixiang817: prepare JIT
// when launched from StikDebug), ca44144 (Leviidev: busy guard and lingering-debugger detach) and e332ee2
// (Braedon Saunders: JIT at launch connects LocalDevVPN first). Henge's built-in StikJIT helper and its
// on-device pairing need Husk's StikJIT and rppairing libraries and are not part of this.
import Foundation
import SwiftUI
import UIKit

private func jitLog(_ line: String) {
    FileHandle.standardError.write(Data(("[winios-jit] " + line + "\n").utf8))
}

@MainActor
final class JITSetup: ObservableObject {
    static let shared = JITSetup()

    /// A request is under way (LocalDevVPN, then StikDebug). Another is not started meanwhile.
    @Published private(set) var busy = false
    /// What is happening now, while busy.
    @Published private(set) var status: String?
    /// Why the last request did not end with JIT on.
    @Published private(set) var error: String?
    /// LocalDevVPN's tunnel, as last checked.
    @Published private(set) var vpnConnected = LocalDevVPN.isConnected

    static let enableAtLaunchKey = "winios.jit.enableAtLaunch"
    /// "Turn on JIT when the app opens": once per launch, when no debugger shows up by itself, go to
    /// LocalDevVPN (when it is off) and then StikDebug without a tap.
    @Published var enableAtLaunch = UserDefaults.standard.bool(forKey: JITSetup.enableAtLaunchKey) {
        didSet { UserDefaults.standard.set(enableAtLaunch, forKey: JITSetup.enableAtLaunchKey) }
    }

    private var onLive: (() -> Void)?
    private var activationTask: Task<Void, Never>?
    private var awaitTask: Task<Void, Never>?
    private var lingeringTask: Task<Void, Never>?
    private var awaitingVPN = false
    private var autoTried = false

    private init() {}

    private var jitLive: Bool { WinIOSBridge.shared.isJITLive }

    // MARK: Activation

    /// Each time the app becomes active. `onLive` runs when this side turns JIT on (the view model then
    /// syncs and, if asked to, starts the machine).
    func appBecameActive(onLive: @escaping () -> Void) {
        self.onLive = onLive
        vpnConnected = LocalDevVPN.isConnected
        activationTask?.cancel()
        activationTask = Task { [weak self] in await self?.watchActivation() }
    }

    private func watchActivation() async {
        if jitLive {
            becameLive()
            return
        }
        if awaitingVPN {
            awaitingVPN = false
            await continueAfterVPN()
            return
        }
        // StikDebug can open the app before it attaches: watch for a debugger for about 10 s.
        for tick in 0..<100 {
            if Task.isCancelled { return }
            switch check() {
            case .live, .failed:
                return
            case .waiting:
                break
            }
            if tick == 15, enableAtLaunch, !autoTried, !busy {
                autoTried = true
                jitLog("turn on JIT at launch: no debugger after 1.5 s, asking StikDebug")
                enable()
                return
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
    }

    private enum CheckResult { case live, waiting, failed }

    /// Turns JIT on when a debugger traces the process now. Not on CS_DEBUGGED alone: that mark stays
    /// set after a detach, and the view model already tries once on it each time the app becomes active
    /// (all an iOS before 26 needs), so a stale mark costs no trap on every tick here.
    private func check() -> CheckResult {
        if jitLive {
            becameLive()
            return .live
        }
        guard winios_jit_is_traced() else { return .waiting }
        jitLog("a debugger is attached; claiming the JIT region")
        _ = WinIOSBridge.shared.tryAcquireJIT(true)
        if jitLive {
            becameLive(turnedOnHere: true)
            return .live
        }
        // Attached, but nothing answered the JIT script's traps.
        fail(L("调试器已连接，但没有运行 Apple VM 的 JIT 脚本，所以没能开启 JIT。从 StikDebug 的应用列表里直接打开 Apple VM，或在某些容器 App 里运行时会这样。请彻底关闭 Apple VM，从主屏幕打开，再点“用 StikDebug 开启”。",
               "A debugger is attached but did not run Apple VM's JIT script, so JIT could not be turned on. This happens when Apple VM is opened from StikDebug's app list, or inside some container apps. Close Apple VM completely, open it from the Home Screen and tap Enable with StikDebug.")
             + "\n(" + WinIOSBridge.shared.jitStatusText + ")")
        return .failed
    }

    private func becameLive(turnedOnHere: Bool = false) {
        let changed = turnedOnHere || busy || status != nil || error != nil
        busy = false
        status = nil
        error = nil
        awaitTask?.cancel()
        awaitTask = nil
        watchForLingeringDebugger()
        if changed {
            jitLog("JIT is on")
            onLive?()
        }
    }

    private func fail(_ message: String) {
        busy = false
        status = nil
        error = message
        awaitTask?.cancel()
        awaitTask = nil
        jitLog("failed: " + message)
    }

    /// Every 10 s while JIT is on: a debugger still attached after the region was held is told to let go
    /// (three tries a launch, in winios_jit.c). One sysctl when there is nothing to do.
    private func watchForLingeringDebugger() {
        guard lingeringTask == nil else { return }
        lingeringTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                _ = winios_jit_release_lingering_debugger()
                try? await Task.sleep(nanoseconds: 6_500_000_000)
            }
        }
    }

    // MARK: Requests

    /// The "Enable with StikDebug" button: LocalDevVPN first when it is installed and off, then StikDebug.
    func enable() {
        guard !jitLive else { return }
        // A second request while one is under way would start a second StikDebug session that attaches
        // once the first lets go, and stays (Henge measured the phone 1.5-2x slower with one attached).
        guard !busy else {
            jitLog("JIT is being turned on already; not asking again")
            return
        }
        error = nil
        vpnConnected = LocalDevVPN.isConnected
        if !vpnConnected && LocalDevVPN.isInstalled {
            jitLog("LocalDevVPN is not connected; opening it to connect (it comes back through applevm://)")
            busy = true
            status = L("正在连接 LocalDevVPN…", "Connecting LocalDevVPN…")
            awaitingVPN = true
            UIApplication.shared.open(LocalDevVPN.connectURL, options: [:]) { [weak self] ok in
                guard !ok else { return }
                Task { @MainActor in
                    self?.awaitingVPN = false
                    self?.fail(L("没能打开 LocalDevVPN。", "LocalDevVPN could not be opened."))
                }
            }
            return
        }
        requestStikDebug()
    }

    /// Back in the foreground after LocalDevVPN was opened: on to StikDebug once the tunnel is up.
    private func continueAfterVPN() async {
        // The tunnel's interface can show up a moment after the app is back.
        for _ in 0..<20 where !LocalDevVPN.isConnected {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        vpnConnected = LocalDevVPN.isConnected
        guard !jitLive else { becameLive(); return }
        guard vpnConnected else {
            fail(L("LocalDevVPN 没有连接。StikDebug 要通过它连到本机：请在 LocalDevVPN 里连接，再点“用 StikDebug 开启”。",
                   "LocalDevVPN is not connected. StikDebug reaches this device through it: connect it in LocalDevVPN, then tap Enable with StikDebug again."))
            return
        }
        jitLog("back from LocalDevVPN, connected; asking StikDebug")
        busy = false
        requestStikDebug()
    }

    /// Asks StikDebug to attach to this process and run the JIT script, which is sent inline. The app goes
    /// to the background; StikDebug attaches and brings it back.
    private func requestStikDebug() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        // pid as well as bundle-id: the pid path attaches to this running process, which also works when
        // the app runs inside a container app that iOS knows under another bundle id.
        var url = "stikjit://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())"
        if let script = Self.scriptBase64URL {
            url += "&script-data=\(script)"
        } else {
            jitLog("henge-jit.js is missing from the bundle; StikDebug falls back to the script assigned to this app")
        }
        guard let launchURL = URL(string: url) else { return }
        busy = true
        status = L("正在等待 StikDebug 连接…", "Waiting for StikDebug to attach…")
        jitLog("opening stikjit:// for \(bundleID), pid \(getpid())")
        // Not canOpenURL first: in a container app the query is answered for the container. open() says.
        UIApplication.shared.open(launchURL, options: [:]) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                if ok {
                    self.awaitStikDebug()
                } else {
                    self.fail(L("没有找到 StikDebug。请先安装 StikDebug 并导入本机的配对文件，然后再试。",
                                "StikDebug was not found. Install StikDebug and give it this device's pairing file, then try again."))
                }
            }
        }
    }

    /// open() cannot tell whether StikDebug will attach: watch for it for a minute, then say what to check.
    private func awaitStikDebug() {
        awaitTask?.cancel()
        let deadline = Date().addingTimeInterval(60)
        awaitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch self.check() {
                case .live, .failed:
                    return
                case .waiting:
                    break
                }
                if Date() >= deadline {
                    self.fail(L("StikDebug 一分钟内没有连接。请确认 LocalDevVPN 已连接、StikDebug 里有本机的配对文件，然后再试。",
                                "StikDebug did not attach within a minute. Check that LocalDevVPN is connected and that StikDebug has this device's pairing file, then try again."))
                    return
                }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }

    /// applevm:// links: LocalDevVPN's way back (nothing to do: becoming active goes on), and
    /// applevm://enable-jit, which asks for JIT as the button does (for Shortcuts, say).
    func handleOpenURL(_ url: URL) {
        jitLog("opened with \(url.scheme ?? "")://\(url.host ?? "")")
        guard url.scheme?.lowercased() == "applevm" else { return }
        if url.host?.lowercased() == "enable-jit" { enable() }
    }

    /// henge-jit.js as StikDebug takes it: base64url without padding, percent-encoded for the query.
    private static var scriptBase64URL: String? {
        guard let path = Bundle.main.path(forResource: "henge-jit", ofType: "js"),
              let script = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let b64 = Data(script.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

/// LocalDevVPN, the VPN StikDebug reaches this device through.
enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects; `scheme` has LocalDevVPN come back to this app afterwards.
    static let connectURL = URL(string: "localdevvpn://enable?scheme=applevm")!

    /// Needs localdevvpn in LSApplicationQueriesSchemes.
    @MainActor static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }

    /// A tunnel interface that is up with an address in 10.7.0.0/16: the network LocalDevVPN routes to
    /// reach this device at 10.7.0.1, where StikDebug looks for it.
    static var isConnected: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0, let sa = ifa.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if ip >> 16 == 0x0a07, String(cString: ifa.ifa_name).hasPrefix("utun") { return true }
        }
        return false
    }

    @MainActor static func open() {
        UIApplication.shared.open(isInstalled ? connectURL : appStoreURL)
    }
}

/// Under the JIT row of the launch page while JIT is off: what a request is doing or why it failed,
/// LocalDevVPN's state, and "Turn on JIT when the app opens".
struct JITPanel: View {
    @ObservedObject private var jit = JITSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if jit.busy, let status = jit.status {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error = jit.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: jit.vpnConnected ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(jit.vpnConnected ? .green : .secondary)
                Text(jit.vpnConnected ? L("LocalDevVPN 已连接", "LocalDevVPN connected")
                                      : L("LocalDevVPN 未连接", "LocalDevVPN not connected"))
                    .font(.footnote).foregroundStyle(.secondary)
                if !jit.vpnConnected {
                    Button(LocalDevVPN.isInstalled ? L("连接", "Connect") : L("获取", "Get")) { LocalDevVPN.open() }
                        .font(.footnote)
                        .disabled(jit.busy)
                }
            }
            Toggle(L("打开 App 时自动开启 JIT", "Turn on JIT when the app opens"), isOn: $jit.enableAtLaunch)
                .font(.footnote)
        }
        .padding(.top, 2)
    }
}
