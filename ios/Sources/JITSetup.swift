// SPDX-License-Identifier: GPL-2.0-or-later
//
// Getting from "opened without JIT" to "JIT is live" with StikDebug or the built-in helper
// (BuiltInJIT.swift, docs/builtin-jit.md), and keeping that reliable:
// - a debugger that attaches late (StikDebug can bring the app back before it attaches) is still
//   noticed: after each activation the app watches for one for about 10 s;
// - one request at a time (a second StikDebug session that attaches after the first let go stays
//   attached, and then every trap stops Windows until it answers);
// - a debugger still attached after the JIT region is held is told to let go (winios_jit.c);
// - LocalDevVPN, which StikDebug reaches this device through: checked, and connected first when it
//   is installed, coming back through the applevm:// URL scheme (not for the built-in helper set to
//   reach this device through the user's own VPN, JITConnectionMode);
// - "Turn on JIT when the app opens";
// - failures say what to check.
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: JITBootstrap.swift (requestAttach,
// releaseLingeringDebugger), JITSetup.swift (busy guard, awaitStikDebug, LocalDevVPN, enableAtLaunchIfAsked)
// and HengeApp.swift (the poll after each activation). Henge commits 294d017 (liukaixiang817: prepare JIT
// when launched from StikDebug), ca44144 (Leviidev: busy guard and lingering-debugger detach) and e332ee2
// (Braedon Saunders: JIT at launch connects LocalDevVPN first). The method picker and the built-in helper's
// requests (enableBuiltIn, prepareBuiltIn, resetDDI, the retries on cellular) are from Henge's JITSetup.swift
// at 7b55730 too.
import Foundation
import Network
import SwiftUI
import UIKit

func jitLog(_ line: String) {
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

    /// How a debugger is attached: StikDebug, or the helper inside the app (BuiltInJIT.swift).
    @Published var method = JITMethod.stored {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: JITMethod.defaultsKey) }
    }
    /// The built-in method's pairing file, if there is one.
    @Published private(set) var pairingSource = JITPairingFileStore.source
    /// The last Prepare (LocalDevVPN and the Developer Disk Image) passed for this pairing file.
    @Published private(set) var prepared = false
    /// Whether the helper saw a Trusted Execution Monitor (StikJIT.isTXMPresent), once it has run.
    @Published private(set) var txmPresent: Bool?
    /// The built-in method needs a step done first: the setup sheet (BuiltInJITView.swift) opens.
    @Published var showBuiltInSetup = false
    /// A request to the helper other than enable (Prepare, Reset DDI, Test connection) is under way.
    @Published private(set) var helperBusy = false
    /// What the last Prepare or Reset DDI said.
    @Published private(set) var helperNote: String?

    /// How the built-in helper reaches this device: LocalDevVPN, or the user's own VPN at
    /// vpnDeviceAddress. StikDebug is a separate app and always uses its own setting (LocalDevVPN).
    @Published var connectionMode = JITConnectionMode.stored {
        didSet {
            UserDefaults.standard.set(connectionMode.rawValue, forKey: JITConnectionMode.defaultsKey)
            if connectionMode != oldValue { connectionChanged() }
        }
    }
    /// The device address for the user's own VPN, as typed in the setup.
    @Published var vpnAddressText = UserDefaults.standard.string(forKey: JITConnectionMode.addressKey) ?? "" {
        didSet {
            UserDefaults.standard.set(vpnAddressText, forKey: JITConnectionMode.addressKey)
            if JITDeviceAddress.normalized(vpnAddressText) != JITDeviceAddress.normalized(oldValue) { connectionChanged() }
        }
    }
    /// A tunnel interface of a VPN is up (OwnVPN), as last checked.
    @Published private(set) var ownVPNConnected = OwnVPN.isConnected
    /// Test connection is under way (it holds helperBusy too).
    @Published private(set) var testingConnection = false
    /// What the last Test connection said, and whether it passed.
    @Published private(set) var connectionTestNote: String?
    @Published private(set) var connectionTestPassed: Bool?

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
    /// Watches for a built-in helper that may still attach after the app stopped waiting for it.
    private var lateHelperTask: Task<Void, Never>?
    /// Back from LocalDevVPN, on to StikDebug. Its own task: another activation (Control Center pulled
    /// down, say) cancels activationTask, and that must not drop the request with busy still set.
    private var vpnTask: Task<Void, Never>?
    private var awaitingVPN = false
    private var autoTried = false
    /// CS_DEBUGGED as last seen by check(), to notice it turning on (iOS before 26).
    private var csDebuggedSeen = winios_jit_is_debugger_attached()

    /// Bumped by each built-in enable, so an answer from an earlier helper request is not taken for this one.
    private var builtInRequest = 0
    /// The network path: the helper reaches this device through LocalDevVPN, but iOS may send that
    /// connection over cellular; which network is in use decides the advice and the retries.
    private let pathMonitor = NWPathMonitor()

    private init() {
        pathMonitor.start(queue: DispatchQueue(label: "applevm.jit-path", qos: .utility))
    }

    var hasPairing: Bool { pairingSource != nil }

    /// The method a request uses now: Automatic is Built-in when it is available here and paired,
    /// StikDebug otherwise.
    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        return hasPairing && WinBuiltInJIT.isAvailable ? .builtIn : .stikDebug
    }

    private var networkSituation: JITNetworkSituation { JITNetworkSituation(pathMonitor.currentPath) }

    /// The device address the user's own VPN routes back to this device, normalised; nil when the text
    /// is not an IPv4 or IPv6 address.
    var vpnDeviceAddress: String? { JITDeviceAddress.normalized(vpnAddressText) }

    /// The built-in helper is to reach this device through the user's own VPN, not LocalDevVPN.
    var builtInUsesOwnVPN: Bool { resolvedMethod == .builtIn && connectionMode == .ownVPN }

    /// The address for the helper's requests: nil for LocalDevVPN (StikJIT's 10.7.0.1).
    private var helperDeviceAddress: String? { connectionMode == .ownVPN ? vpnDeviceAddress : nil }

    /// A Prepare or Test result was for the other connection.
    private func connectionChanged() {
        prepared = false
        connectionTestNote = nil
        connectionTestPassed = nil
        RemotePairingPortDiscovery.invalidate()
    }

    func refreshVPNStatus() {
        vpnConnected = LocalDevVPN.isConnected
        ownVPNConnected = OwnVPN.isConnected
    }

    private var jitLive: Bool { WinIOSBridge.shared.isJITLive }

    // MARK: Activation

    /// Each time the app becomes active. `onLive` runs when this side turns JIT on (the view model then
    /// syncs and, if asked to, starts the machine).
    func appBecameActive(onLive: @escaping () -> Void) {
        self.onLive = onLive
        refreshVPNStatus()
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
            vpnTask = Task { [weak self] in await self?.continueAfterVPN() }
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
                jitLog("turn on JIT at launch: no debugger after 1.5 s, using \(resolvedMethod.rawValue)")
                enable(atLaunch: true)
                return
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
    }

    private enum CheckResult { case live, waiting, failed }

    /// Turns JIT on when a debugger traces the process now, or (before iOS 26) when CS_DEBUGGED has just
    /// turned on: there StikDebug attaches and detaches straight away, which is all that is needed, so a
    /// late attach can be over before a tick sees it traced. Only on the mark turning on, not on the mark
    /// alone: it stays set after a detach, and the view model already tries once on it each time the app
    /// becomes active, so a stale mark costs no trap on every tick here.
    private func check() -> CheckResult {
        if jitLive {
            becameLive()
            return .live
        }
        var markJustSet = false
        if #unavailable(iOS 26) {
            let marked = winios_jit_is_debugger_attached()
            markJustSet = marked && !csDebuggedSeen
            csDebuggedSeen = marked
        }
        let traced = winios_jit_is_traced()
        guard traced || markJustSet else { return .waiting }
        jitLog(traced ? "a debugger is attached; claiming the JIT region"
                      : "CS_DEBUGGED turned on (a debugger came and went); claiming the JIT region")
        _ = WinIOSBridge.shared.tryAcquireJIT(true)
        if jitLive {
            becameLive(turnedOnHere: true)
            return .live
        }
        let detail = WinIOSBridge.shared.jitStatusText
        if detail.hasPrefix("Failed") || !traced {
            // The debugger answered, but the region it gave did not work out, or (CS_DEBUGGED only) the
            // plain RX/RW region did not (winios_jit.c says why).
            fail(L("调试器已连接，但 JIT 内存没能准备好：", "A debugger is attached, but the JIT memory could not be set up: ")
                 + detail + L("。请彻底关闭 Apple VM 再打开，然后重试。", ". Close Apple VM completely, open it again and retry."))
            return .failed
        }
        // Attached, but nothing answered the JIT script's traps.
        if resolvedMethod == .builtIn && (busy || WinBuiltInJIT.enableOutstanding) {
            fail(L("内置助手已连接，但没有回应 Apple VM 的 JIT 脚本。请彻底关闭 Apple VM 再打开，然后重试。",
                   "The built-in helper attached but did not answer Apple VM's JIT script. Close Apple VM completely, open it again and retry.")
                 + "\n(" + detail + ")")
            return .failed
        }
        fail(L("调试器已连接，但没有运行 Apple VM 的 JIT 脚本，所以没能开启 JIT。从 StikDebug 的应用列表里直接打开 Apple VM，或在某些容器 App 里运行时会这样。请彻底关闭 Apple VM，从主屏幕打开，再点“用 StikDebug 开启”。",
               "A debugger is attached but did not run Apple VM's JIT script, so JIT could not be turned on. This happens when Apple VM is opened from StikDebug's app list, or inside some container apps. Close Apple VM completely, open it from the Home Screen and tap Enable with StikDebug.")
             + "\n(" + detail + ")")
        return .failed
    }

    private func becameLive(turnedOnHere: Bool = false) {
        let changed = turnedOnHere || busy || status != nil || error != nil
        busy = false
        status = nil
        error = nil
        awaitTask?.cancel()
        awaitTask = nil
        lateHelperTask?.cancel()
        lateHelperTask = nil
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

    /// Every 10 s while JIT is on, every 2 s while a built-in helper request is still out: a debugger
    /// still attached after the region was held is told to let go (winios_jit.c decides which). One
    /// sysctl when there is nothing to do.
    private func watchForLingeringDebugger() {
        guard lingeringTask == nil else { return }
        lingeringTask = Task {
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                tick += 1
                if WinBuiltInJIT.enableOutstanding ? tick % 4 == 0 : tick % 20 == 7 {
                    _ = winios_jit_release_lingering_debugger()
                }
            }
        }
    }

    /// The app stopped waiting for the built-in helper, but its request is still out: it can attach
    /// late (a slow Developer Disk Image download, cellular). Keep watching until that request ends,
    /// so a late attach turns JIT on now rather than at the next activation.
    private func watchForLateHelper() {
        guard WinBuiltInJIT.enableOutstanding else { return }
        jitLog("the helper's request is still running; still watching for it to attach")
        lateHelperTask?.cancel()
        lateHelperTask = Task { [weak self] in
            while !Task.isCancelled, WinBuiltInJIT.enableOutstanding {
                guard let self else { return }
                switch self.check() {
                case .live, .failed:
                    return
                case .waiting:
                    break
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
    }

    // MARK: Requests

    /// The Enable button: LocalDevVPN first when it is installed and off, then StikDebug or the
    /// built-in helper (resolvedMethod). `atLaunch`: "Turn on JIT when the app opens" asked, so a
    /// built-in method that is not set up is skipped instead of opening its setup.
    func enable(atLaunch: Bool = false) {
        guard !jitLive else { return }
        // A second request while one is under way would start a second debugger session that attaches
        // once the first lets go, and stays (Henge measured the phone 1.5-2x slower with one attached).
        guard !busy else {
            jitLog("JIT is being turned on already; not asking again")
            return
        }
        // Prepare and Reset DDI run in a helper process of their own, and every helper process works on
        // the same Developer Disk Image cache: an enable alongside would mount the image while the other
        // downloads or deletes it.
        guard !helperBusy else {
            jitLog("Prepare or Reset DDI is still running; not enabling now")
            return
        }
        error = nil
        refreshPairingStatus()
        if resolvedMethod == .builtIn {
            if let reason = WinBuiltInJIT.unavailableReason {
                if atLaunch { jitLog("JIT at launch: built-in JIT is unavailable here; skipped"); return }
                error = reason
                return
            }
            guard hasPairing else {
                if atLaunch { jitLog("JIT at launch: built-in JIT is not paired; skipped"); return }
                jitLog("built-in JIT is not paired; opening its setup")
                showBuiltInSetup = true
                return
            }
        }
        if builtInUsesOwnVPN {
            // The user's own VPN: LocalDevVPN is neither needed nor opened (iOS would drop that VPN for it).
            guard vpnDeviceAddress != nil else {
                if atLaunch { jitLog("JIT at launch: no device address for your VPN; skipped"); return }
                jitLog("built-in JIT over your VPN has no valid device address; opening its setup")
                error = L("请在内置 JIT 设置里填写你的 VPN 转回本机的地址（IPv4 或 IPv6）。",
                          "Enter the address your VPN routes back to this device (IPv4 or IPv6) in Built-in JIT setup.")
                showBuiltInSetup = true
                return
            }
            ownVPNConnected = OwnVPN.isConnected
            // Not a hard stop: a VPN whose interface is named otherwise still gets its try, and the helper
            // says what failed.
            if !ownVPNConnected { jitLog("no VPN tunnel interface is up; trying the device address anyway") }
            requestDebugger()
            return
        }
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
        requestDebugger()
    }

    /// StikDebug or the built-in helper, whichever resolvedMethod says.
    private func requestDebugger() {
        if resolvedMethod == .builtIn { enableBuiltIn() } else { requestStikDebug() }
    }

    /// Back in the foreground after LocalDevVPN was opened: on to the debugger once the tunnel is up.
    private func continueAfterVPN() async {
        // The tunnel's interface can show up a moment after the app is back.
        for _ in 0..<20 where !LocalDevVPN.isConnected {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        vpnConnected = LocalDevVPN.isConnected
        guard !jitLive else { becameLive(); return }
        guard vpnConnected else {
            fail(resolvedMethod == .builtIn
                 ? L("LocalDevVPN 没有连接。内置 JIT 要通过它连到本机：请在 LocalDevVPN 里连接，然后重试。",
                     "LocalDevVPN is not connected. Built-in JIT reaches this device through it: connect it in LocalDevVPN, then try again.")
                 : L("LocalDevVPN 没有连接。StikDebug 要通过它连到本机：请在 LocalDevVPN 里连接，再点“用 StikDebug 开启”。",
                     "LocalDevVPN is not connected. StikDebug reaches this device through it: connect it in LocalDevVPN, then tap Enable with StikDebug again."))
            return
        }
        jitLog("back from LocalDevVPN, connected; asking \(resolvedMethod == .builtIn ? "the built-in helper" : "StikDebug")")
        busy = false
        requestDebugger()
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
                    self.awaitDebugger(timeout: 60, timeoutMessage: L("StikDebug 一分钟内没有连接。请确认 LocalDevVPN 已连接、StikDebug 里有本机的配对文件，然后再试。",
                                                                      "StikDebug did not attach within a minute. Check that LocalDevVPN is connected and that StikDebug has this device's pairing file, then try again."))
                } else {
                    self.fail(L("没有找到 StikDebug。请先安装 StikDebug 并导入本机的配对文件，然后再试。",
                                "StikDebug was not found. Install StikDebug and give it this device's pairing file, then try again."))
                }
            }
        }
    }

    /// open() cannot tell whether StikDebug will attach, and the helper's start does not say when it
    /// will: watch for a debugger until `timeout`, then say what to check.
    private func awaitDebugger(timeout: TimeInterval, timeoutMessage: String) {
        awaitTask?.cancel()
        let deadline = Date().addingTimeInterval(timeout)
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
                    self.fail(timeoutMessage)
                    self.watchForLateHelper()
                    return
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
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

    private static var script: String? {
        guard let path = Bundle.main.path(forResource: "henge-jit", ofType: "js") else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// henge-jit.js as the built-in helper takes it (StikJIT's .customBase64): standard base64.
    static var scriptBase64: String? { script.map { Data($0.utf8).base64EncodedString() } }

    /// henge-jit.js as StikDebug takes it: base64url without padding, percent-encoded for the query.
    private static var scriptBase64URL: String? {
        guard let script else { return nil }
        let b64 = Data(script.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    // MARK: Built-in JIT (BuiltInJIT.swift, docs/builtin-jit.md)

    func refreshPairingStatus() {
        pairingSource = JITPairingFileStore.source
    }

    /// Asks the helper inside the app to attach and run henge-jit.js. The app stays in the
    /// foreground, so the attach is watched here (check() claims the JIT region, and winios_jit.c
    /// then asks the script to detach, which ends the helper's request). `attempt` counts tries on
    /// cellular (JITRetryPolicy).
    private func enableBuiltIn(attempt: Int = 1) {
        // Back from LocalDevVPN, or a retry: Prepare or Reset DDI may have been started meanwhile, and
        // they share the helper's Developer Disk Image cache (enable() says more).
        guard !helperBusy else {
            fail(L("“准备”或“重置开发者磁盘映像”还在进行，请等它完成后再开启 JIT。",
                   "Prepare or Reset Developer Disk Image is still running. Wait for it to finish, then enable JIT."))
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            fail(L("请先配对本机，或导入它的配对文件。", "Pair this device or import its pairing file first."))
            refreshPairingStatus()
            return
        }
        guard let script = Self.scriptBase64 else {
            fail(L("安装包里缺少 Apple VM 的 JIT 脚本（henge-jit.js），请重新安装。",
                   "Apple VM's JIT script (henge-jit.js) is missing from this installation. Reinstall Apple VM."))
            return
        }
        // Never LocalDevVPN's address in its stead: My VPN without a valid address stops here.
        if connectionMode == .ownVPN && vpnDeviceAddress == nil {
            fail(L("请在内置 JIT 设置里填写你的 VPN 转回本机的地址（IPv4 或 IPv6）。",
                   "Enter the address your VPN routes back to this device (IPv4 or IPv6) in Built-in JIT setup."))
            return
        }
        busy = true
        error = nil
        if attempt == 1 { status = L("正在启动内置 JIT 助手…", "Starting the built-in JIT helper…") }
        builtInRequest += 1
        let request = builtInRequest
        // Fixed for this request, whatever the setting is changed to meanwhile.
        let deviceAddress = helperDeviceAddress
        let connection: JITConnectionMode = deviceAddress == nil ? .localDevVPN : .ownVPN
        jitLog("enabling JIT with the built-in helper" + (attempt > 1 ? " (attempt \(attempt))" : "")
               + (deviceAddress.map { " through your VPN (\(JITDeviceAddress.family($0)))" } ?? ""))
        RemotePairingPortDiscovery.resolve { [weak self] port in
            guard let self, request == self.builtInRequest, self.busy else { return }
            WinBuiltInJIT.send(
                .enable(targetPID: getpid(), pairingData: pairing, scriptBase64: script, rsdPort: port,
                        deviceAddress: deviceAddress),
                started: { [weak self] in
                    guard let self, request == self.builtInRequest, self.busy else { return }
                    if attempt == 1 { self.status = L("正在等待内置助手连接…", "Waiting for the helper to attach…") }
                    // The first Enable can download and mount the Developer Disk Image before it attaches.
                    self.awaitDebugger(timeout: 150, timeoutMessage: connection == .ownVPN
                        ? L("内置助手 150 秒内没有连接。请确认你的 VPN 已连接，在设置里点“测试连接”和“准备”，然后重试。",
                            "The helper did not attach within 150 seconds. Check that your VPN is connected, run Test connection and Prepare in the setup, then try again.")
                        : L("内置助手 150 秒内没有连接。请确认 LocalDevVPN 已连接，先点“准备”，然后重试。",
                            "The helper did not attach within 150 seconds. Check that LocalDevVPN is connected, run Prepare, then try again."))
                },
                completion: { [weak self] result in
                    self?.builtInEnableFinished(result, attempt: attempt, request: request, connection: connection)
                })
        }
    }

    /// The helper's enable request ended: after the script detached (success), or when attaching failed.
    private func builtInEnableFinished(_ result: Result<WinJITRequest.Response, Error>, attempt: Int, request: Int,
                                       connection: JITConnectionMode) {
        let current = request == builtInRequest
        // This request failed, but an earlier one the app gave up on may still attach.
        defer { if !jitLive && !busy { watchForLateHelper() } }
        switch result {
        case .success(let response):
            txmPresent = response.txmPresent ?? txmPresent
            jitLog("helper: " + response.message)
            if response.success {
                prepared = true
                guard current, !jitLive, busy else { return }
                // Detached already: the attach was too quick for the watch, or the region could not be claimed.
                _ = check()
                if !jitLive && busy {
                    fail(L("内置助手连接过又断开了，但 JIT 没有开启：", "The helper attached and detached, but JIT is not on: ")
                         + WinIOSBridge.shared.jitStatusText)
                }
                return
            }
            guard current, !jitLive, busy else { return }
            if connection == .ownVPN, let check = response.connection, check != .ok {
                // The helper checked the address first and says which stage failed.
                RemotePairingPortDiscovery.invalidate()
                fail(JITOwnVPNAdvice.text(for: check) + "\n(" + response.message + ")")
                return
            }
            if let problem = JITConnectionProblem(helperMessage: response.message) {
                RemotePairingPortDiscovery.invalidate()
                if let wait = JITRetryPolicy.retryDelay(situation: networkSituation, problem: problem, attempt: attempt,
                                                        connection: connection) {
                    awaitTask?.cancel()
                    awaitTask = nil
                    status = JITRetryPolicy.statusText(nextAttempt: attempt + 1)
                    jitLog("helper could not connect (attempt \(attempt)); retrying in \(Int(wait)) s")
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        guard let self, request == self.builtInRequest, self.busy, !self.jitLive else { return }
                        self.enableBuiltIn(attempt: attempt + 1)
                    }
                    return
                }
                fail(problem.advice(networkSituation, connection: connection))
                return
            }
            fail(L("内置 JIT 没能开启：", "Built-in JIT could not turn on: ") + response.message)
        case .failure(let failure):
            guard current, !jitLive, busy else { return }
            fail(failure.localizedDescription)
        }
    }

    /// Prepare: checks LocalDevVPN (or the user's own VPN) and mounts the Developer Disk Image
    /// (downloading it the first time).
    func prepareBuiltIn(attempt: Int = 1) {
        guard !helperBusy, !busy else { return }
        if let reason = WinBuiltInJIT.unavailableReason { helperNote = reason; return }
        guard let pairing = try? JITPairingFileStore.data() else {
            helperNote = L("请先配对本机，或导入它的配对文件。", "Pair this device or import its pairing file first.")
            return
        }
        let deviceAddress = helperDeviceAddress
        let connection: JITConnectionMode = deviceAddress == nil ? .localDevVPN : .ownVPN
        if connectionMode == .ownVPN && deviceAddress == nil {
            helperNote = L("请先填写你的 VPN 转回本机的地址。", "Enter the address your VPN routes back to this device first.")
            return
        }
        helperBusy = true
        if attempt == 1 {
            helperNote = connection == .ownVPN
                ? L("正在检查通过你的 VPN 的连接和开发者磁盘映像（第一次会下载）…",
                    "Checking the connection through your VPN and the Developer Disk Image (downloaded the first time)…")
                : L("正在检查 LocalDevVPN 和开发者磁盘映像（第一次会下载）…",
                    "Checking LocalDevVPN and the Developer Disk Image (downloaded the first time)…")
        }
        RemotePairingPortDiscovery.resolve { [weak self] port in
            WinBuiltInJIT.send(.prepare(pairingData: pairing, rsdPort: port, deviceAddress: deviceAddress)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let response):
                    jitLog("prepare \(response.success ? "passed" : "failed"): \(response.message)")
                    txmPresent = response.txmPresent ?? txmPresent
                    if !response.success, connection == .ownVPN, let check = response.connection, check != .ok {
                        RemotePairingPortDiscovery.invalidate()
                        helperBusy = false
                        prepared = false
                        helperNote = JITOwnVPNAdvice.text(for: check) + "\n(" + response.message + ")"
                        return
                    }
                    if !response.success, let problem = JITConnectionProblem(helperMessage: response.message) {
                        RemotePairingPortDiscovery.invalidate()
                        if let wait = JITRetryPolicy.retryDelay(situation: networkSituation, problem: problem, attempt: attempt,
                                                                connection: connection) {
                            helperNote = JITRetryPolicy.statusText(nextAttempt: attempt + 1)
                            Task { [weak self] in
                                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                                self?.helperBusy = false
                                self?.prepareBuiltIn(attempt: attempt + 1)
                            }
                            return
                        }
                        helperBusy = false
                        prepared = false
                        helperNote = problem.advice(networkSituation, connection: connection)
                        return
                    }
                    helperBusy = false
                    prepared = response.success
                    helperNote = !response.success ? response.message
                        : connection == .ownVPN
                        ? L("本机通过你的 VPN 有回应，开发者磁盘映像已就绪。", "This device answers through your VPN and the Developer Disk Image is ready.")
                        : L("LocalDevVPN 可用，开发者磁盘映像已就绪。", "LocalDevVPN is reachable and the Developer Disk Image is ready.")
                case .failure(let failure):
                    helperBusy = false
                    prepared = false
                    helperNote = failure.localizedDescription
                }
            }
        }
    }

    /// Reset DDI: forgets the helper's cached Developer Disk Image, for a download that went wrong.
    func resetDDI() {
        guard !helperBusy, !busy else { return }
        helperBusy = true
        helperNote = L("正在重置开发者磁盘映像缓存…", "Resetting the Developer Disk Image cache…")
        WinBuiltInJIT.send(.resetDDI) { [weak self] result in
            guard let self else { return }
            helperBusy = false
            prepared = false
            switch result {
            case .success(let response):
                helperNote = response.success
                    ? L("开发者磁盘映像缓存已重置。", "Developer Disk Image cache reset.")
                    : response.message
            case .failure(let failure):
                helperNote = failure.localizedDescription
            }
        }
    }

    /// Test connection (the user's own VPN): the helper connects to RemotePairing's port at the device
    /// address and, once paired, checks that RemotePairing answers there. Says which stage failed.
    func testConnection() {
        guard !helperBusy, !busy else { return }
        if let reason = WinBuiltInJIT.unavailableReason {
            connectionTestPassed = false
            connectionTestNote = reason
            return
        }
        guard let address = vpnDeviceAddress else {
            connectionTestPassed = false
            connectionTestNote = L("这不是有效的 IPv4 或 IPv6 地址。", "That is not a valid IPv4 or IPv6 address.")
            return
        }
        let pairing = try? JITPairingFileStore.data()
        helperBusy = true
        testingConnection = true
        connectionTestPassed = nil
        connectionTestNote = L("正在测试通过你的 VPN 的连接…", "Testing the connection through your VPN…")
        jitLog("testing the connection through your VPN (\(JITDeviceAddress.family(address)), \(pairing == nil ? "not paired" : "paired"))")
        RemotePairingPortDiscovery.resolve { [weak self] port in
            WinBuiltInJIT.send(.testConnection(pairingData: pairing, rsdPort: port, deviceAddress: address)) { [weak self] result in
                guard let self else { return }
                helperBusy = false
                testingConnection = false
                switch result {
                case .success(let response):
                    jitLog("connection test \(response.success ? "passed" : "failed"): \(response.message)")
                    txmPresent = response.txmPresent ?? txmPresent
                    if !response.success { RemotePairingPortDiscovery.invalidate() }
                    connectionTestPassed = response.success
                    let summary = response.connection.map(JITOwnVPNAdvice.text(for:))
                    connectionTestNote = summary.map { $0 + "\n(" + response.message + ")" } ?? response.message
                case .failure(let failure):
                    connectionTestPassed = false
                    connectionTestNote = failure.localizedDescription
                }
            }
        }
    }

    /// A pairing file picked in the setup sheet, made on a computer or taken from StikDebug.
    func importPairingFile(_ url: URL) {
        do {
            try JITPairingFileStore.importFile(from: url)
            OnDevicePairing.shared.cancel()
            pairingDidChange()
            helperNote = L("配对文件已导入。", "Pairing file imported.")
            jitLog("pairing file imported")
        } catch {
            helperNote = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        pairingDidChange()
        helperNote = L("已在本机完成配对。", "Paired on this device.")
    }

    func removePairing() {
        JITPairingFileStore.remove()
        pairingDidChange()
        helperNote = nil
        jitLog("pairing file removed")
    }

    private func pairingDidChange() {
        refreshPairingStatus()
        prepared = false
        RemotePairingPortDiscovery.invalidate()
        // A pairing made or imported here is meant to be used: StikDebug, if picked, gives way to
        // Built-in (Automatic picks Built-in by itself once paired).
        if hasPairing && method == .stikDebug { method = .builtIn }
    }
}

/// LocalDevVPN, the VPN StikDebug and the built-in helper reach this device through (the helper unless
/// it is set to the user's own VPN, JITConnectionMode).
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
/// the JIT method (and the built-in method's setup), LocalDevVPN's state (or, for the built-in helper
/// set to the user's own VPN, whether a VPN is up), and "Turn on JIT when the app opens".
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
            JITMethodRow()
            if jit.builtInUsesOwnVPN {
                // No LocalDevVPN here: the helper goes through the user's own VPN.
                HStack(spacing: 6) {
                    Image(systemName: jit.ownVPNConnected ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundStyle(jit.ownVPNConnected ? .green : .secondary)
                    Text(jit.ownVPNConnected ? L("VPN 已连接（内置 JIT 通过它连到本机）", "VPN connected (built-in JIT reaches this device through it)")
                                             : L("没有连接 VPN：内置 JIT 要通过你的 VPN 连到本机", "No VPN connected: built-in JIT reaches this device through your VPN"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
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
            }
            Toggle(L("打开 App 时自动开启 JIT", "Turn on JIT when the app opens"), isOn: $jit.enableAtLaunch)
                .font(.footnote)
        }
        .padding(.top, 2)
        .sheet(isPresented: $jit.showBuiltInSetup) { BuiltInJITSetupView() }
    }
}
