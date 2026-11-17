// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Network
import SwiftUI
import UIKit
import UserNotifications

// Server mode: Windows keeps running while the app is in the background, so Remote Desktop (and any other port
// forward) keeps answering, from other devices or from an app on this iPhone. iOS keeps an app with background
// audio running while its audio plays: the bridge keeps the HDA output unit running with silence
// (hv_audio_set_keepalive). iOS refuses GPU work from the background, so it only works without host 3D: the
// graphics hot switch (2D/3D without a restart, virtio_gpu.c + winkit/gpu_switch.ps1) gets there without
// restarting Windows. docs/networking.md ("Server mode") has the whole picture.

// MARK: - The controller

/// Where a graphics switch stands.
enum GraphicsSwitchPhase: Equatable {
    case idle
    case waiting(to3D: Bool, started: Date, guestAnswered: Bool)
    case done(String)
    case warning(String)
    case failed(String)

    var busy: Bool { if case .waiting = self { return true } else { return false } }
}

@MainActor
final class ServerModeController: ObservableObject {
    static let shared = ServerModeController()

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: "winios.serverMode") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "winios.serverMode")
            if enabled { requestNotifications() }
            applyToBridge()
        }
    }
    /// An info card in place of the picture; the Metal layer is unbound and Windows keeps its size.
    @Published var headless: Bool = UserDefaults.standard.bool(forKey: "winios.serverHeadless") {
        didSet { UserDefaults.standard.set(headless, forKey: "winios.serverHeadless"); applyToBridge() }
    }
    /// Off by default in server mode: the locked phone is just "the background", where Windows keeps running. The
    /// screen stays on anyway while Windows could not run in the background (the bridge's applyIdleTimer).
    @Published var keepScreenOn: Bool = UserDefaults.standard.bool(forKey: "winios.serverKeepScreenOn") {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "winios.serverKeepScreenOn"); applyToBridge() }
    }
    /// Switch back to 3D by itself when the app comes back to the front from the background (after this session's
    /// switch to 2D, by hand or by auto-2D). One setting for server mode and auto-2D.
    @Published var autoBackTo3D: Bool = UserDefaults.standard.bool(forKey: "winios.serverAuto3D") {
        didSet { UserDefaults.standard.set(autoBackTo3D, forKey: "winios.serverAuto3D") }
    }
    /// Auto-2D: leaving the app (the background, not Control Center or a Face ID sheet) with Windows on 3D switches it
    /// to 2D there and keeps it running, also without server mode (the bridge: startAutoSwitch).
    @Published var auto2D: Bool = UserDefaults.standard.bool(forKey: "winios.auto2D") {
        didSet {
            UserDefaults.standard.set(auto2D, forKey: "winios.auto2D")
            if auto2D { requestNotifications() } // the guard's notices
            applyToBridge()
        }
    }
    /// Windows in Picture in Picture while the app is away (winios_pip.m).
    @Published var pipEnabled: Bool = UserDefaults.standard.bool(forKey: "winios.pip") {
        didSet { UserDefaults.standard.set(pipEnabled, forKey: "winios.pip"); applyPiP() }
    }
    /// The Windows port Remote Desktop listens on (enable_rdp.ps1's Get-RdpPort): the forward to it is the RDP one.
    @Published var rdpGuestPort: Int = {
        let v = UserDefaults.standard.integer(forKey: "winios.rdpGuestPort")
        return (1...65535).contains(v) ? v : 3389
    }() {
        didSet { UserDefaults.standard.set(rdpGuestPort, forKey: "winios.rdpGuestPort") }
    }

    // live state (refresh())
    @Published private(set) var blocker: WinIOSBackgroundBlocker = .notRunning
    @Published private(set) var graphics = WinIOSGraphicsMode()
    @Published private(set) var guardPaused = false
    @Published private(set) var guardReason = ""
    /// The guard's condition holds now (critical temperature or battery): why, else empty. In the foreground it is
    /// only shown; the pause itself happens in the background.
    @Published private(set) var guardWarning = ""
    /// The user resumed Windows from the guard: no pause again until conditions are back to normal.
    @Published private(set) var resumedByUser = false
    /// Seconds a graphics switch has waited while Windows ran (time paused does not count).
    @Published private(set) var switchElapsed = 0
    @Published private(set) var audioRunning = false
    @Published private(set) var graphicsPhase: GraphicsSwitchPhase = .idle
    @Published private(set) var runningSince: Date?
    /// Auto-2D would switch if the app left now (bridge.autoSwitchPossible).
    @Published private(set) var autoSwitchReady = false
    /// This session switched to 2D (what "back to 3D" undoes).
    private(set) var switchedTo2D = false
    /// The app really went to the background since that switch (not just a trip to Control Center or an alert).
    private var backgroundSince2D = false
    /// Back in front with "back to 3D" on while auto-2D's switch was still under way: back to 3D once that switch
    /// (this request number) is done; 0 for none. Any other end of it, a switch by hand or Windows stopping clears it.
    private var backTo3DSeq: Int64 = 0
    /// Leaving the app now keeps Windows running (pipCanRun): Picture in Picture may be armed.
    @Published private(set) var pipPossible = false

    private var bridge: WinIOSBridge { WinIOSBridge.shared }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var thermalSink: AnyCancellable?
    private var switchSeq: Int64 = 0
    private var switchFrom = WinIOSGraphicsMode()
    private var switchTo3D = false
    private var switchRunSecs: Double = 0     // time the guest ran since the request
    private var guestAnsweredRun: Double?     // switchRunSecs when Windows answered
    private var lastTick = Date()
    /// The switch timed out: a late success still turns into done.
    private var lateWatch = false

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ServerModeController.shared.appBecameActive() }
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ServerModeController.shared.appEnteredBackground() }
        })
        observers.append(nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ServerModeController.shared.checkGuard() }
        })
        thermalSink = DeviceStatus.shared.$thermalState.sink { _ in
            Task { @MainActor in ServerModeController.shared.checkGuard() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in ServerModeController.shared.tick() }
        }
    }

    /// Pushes the settings to the bridge (also before Windows starts).
    /// Also when the machine changes: Linux has no server mode and no headless.
    func applyToBridge() {
        let b = bridge
        let on = enabled && !isLinux
        let auto = auto2D && !isLinux
        b.runInBackground = on
        b.autoSwitch2D = auto
        b.audioKeepAlive = on || auto // the silent output keeps the app running wherever Windows runs in the background
        b.keepScreenOn = keepScreenOn // and on anyway while Windows could not run in the background (the bridge)
        b.headless = on && headless
        if on || auto { UIDevice.current.isBatteryMonitoringEnabled = true }
        if !(on || auto) && b.guardPaused { b.setGuardPaused(false, reason: "server mode and auto-2D off") } // its guard goes with them
        if !(on || auto) { resumedByUser = false; guardWarning = "" }
        applyPiP()
        refresh()
    }

    /// Windows runs in the background by server mode or auto-2D: the guard watches over it.
    var backgroundRunning: Bool { (enabled || auto2D) && !isLinux }

    /// Leaving the app now keeps Windows running: auto-2D would switch it, or server mode or auto-2D keeps a Windows
    /// with nothing in the way (no host 3D, no switch pending, no debugger) running. Never Linux.
    var pipCanRun: Bool {
        let b = bridge
        guard !isLinux, b.isVMRunning else { return false }
        return b.autoSwitchPossible || (backgroundRunning && b.backgroundBlocker == .nothing)
    }

    /// PiP is armed only while leaving the app keeps Windows running: otherwise its picture would be a paused
    /// Windows that looks live. Followed every second (refresh()).
    func applyPiP() {
        let can = pipCanRun
        if can != pipPossible { pipPossible = can }
        let armed = pipEnabled && can
        let pip = WinIOSPictureInPicture.shared
        if pip.armed != armed { pip.armed = armed }
    }

    /// Why Picture in Picture would not show Windows now (the setting's note), nil when it would.
    var pipBlockedReason: String? {
        if pipPossible { return nil }
        if !bridge.isVMRunning { return L("Windows 运行时才可用。", "Available while Windows runs.") }
        if !backgroundRunning {
            return L("先打开“离开 App 时切到 2D”或服务器模式：否则 Windows 在后台会暂停，小窗只会停在一个画面。",
                     "Turn on Switch to 2D when leaving the app, or server mode, first: otherwise Windows pauses in the background and the window would only hold a still picture.")
        }
        switch blocker {
        case .debugger:
            return L("调试器还连着：Windows 在后台会暂停。", "A debugger is attached: Windows pauses in the background.")
        case .host3D, .switchPending:
            return auto2D && graphics.capable && !bridge.graphicsTaskPresent
                ? L("Windows 里还没有 WinKit 的显卡切换任务（运行一次 START.bat）：用着 3D 时 Windows 在后台会暂停。",
                    "WinKit's graphics task has not been seen in Windows (run START.bat once): on 3D, Windows pauses in the background.")
                : L("正在用主机 3D：Windows 在后台会暂停。打开“离开 App 时切到 2D”，或先切到 2D。",
                    "Host 3D is in use: Windows pauses in the background. Turn on Switch to 2D when leaving the app, or switch to 2D first.")
        default:
            return L("Windows 现在不能在后台运行。", "Windows cannot run in the background now.")
        }
    }

    /// The Arch Linux machine (always 3D): no server mode, no headless.
    var isLinux: Bool { UserDefaults.standard.string(forKey: "winios.machine") == "Arch" }
    var headlessActive: Bool { enabled && headless && !isLinux && bridge.isVMRunning }
    var isVMRunning: Bool { bridge.isVMRunning }
    var isLiveContainer: Bool { getenv("LC_HOME_PATH") != nil }

    func refresh() {
        let b = bridge
        let running = b.isVMRunning
        if running && runningSince == nil { runningSince = Date() }
        if !running {
            runningSince = nil
            lateWatch = false
            backTo3DSeq = 0
            if graphicsPhase.busy { graphicsPhase = .idle }
        }
        let bl = b.backgroundBlocker
        if bl != blocker {
            blocker = bl
            b.updateIdleTimer() // e.g. a switch finished: the screen may lock now (or must stay on)
        }
        let g = b.graphicsMode()
        if !Self.same(g, graphics) { graphics = g }
        if b.guardPaused != guardPaused { guardPaused = b.guardPaused }
        let a = b.audioOutputRunning
        if a != audioRunning { audioRunning = a }
        let ready = b.autoSwitchPossible
        if ready != autoSwitchReady { autoSwitchReady = ready }
        applyPiP() // Windows started or stopped
    }

    private static func same(_ a: WinIOSGraphicsMode, _ b: WinIOSGraphicsMode) -> Bool {
        a.capable == b.capable && a.offered3D == b.offered3D && a.negotiated3D == b.negotiated3D &&
            a.driverOK == b.driverOK && a.resets == b.resets
    }

    private func tick() {
        let now = Date()
        // a switch waits only while Windows runs: time paused (in the background or by the guard) does not count, nor
        // time the app was suspended (no ticks then: a gap counts as one tick at most)
        if graphicsPhase.busy && bridge.isVMRunning && !bridge.machinePaused {
            switchRunSecs += min(max(now.timeIntervalSince(lastTick), 0), 1.5)
            let e = Int(switchRunSecs.rounded())
            if e != switchElapsed { switchElapsed = e }
        }
        lastTick = now
        refresh()
        if graphicsPhase.busy || lateWatch { pollSwitch() }
        if backgroundRunning { checkGuard() }
    }

    // MARK: Status text

    var statusText: String {
        if !bridge.isVMRunning { return L("Windows 没有在运行", "Windows is not running") }
        if guardPaused { return L("已暂停：", "Paused: ") + guardReason }
        if backgroundRunning && !guardWarning.isEmpty {
            return resumedByUser
                ? L("\(guardWarning)：你选择了继续运行，到后台也不会暂停，直到情况恢复正常。",
                    "\(guardWarning): you resumed Windows, so it is not paused in the background until conditions are back to normal.")
                : L("\(guardWarning)：App 到后台时 Windows 会暂停。", "\(guardWarning): Windows pauses when the app goes to the background.")
        }
        if autoSwitchReady && (blocker == .host3D || blocker == .switchPending) {
            return L("正在用主机 3D：App 到后台时自动切到 2D，Windows 继续运行", "Host 3D is in use: it switches to 2D when the app leaves, and Windows keeps running")
        }
        if auto2D && blocker == .host3D && graphics.capable && !bridge.graphicsTaskPresent {
            return L("正在用主机 3D，Windows 里还没有 WinKit 的显卡切换任务（运行一次 START.bat）：到后台会暂停。",
                     "Host 3D is in use and WinKit's graphics task has not been seen in Windows (run START.bat once): Windows pauses in the background.")
        }
        switch blocker {
        case .nothing:
            return enabled || auto2D ? L("App 到后台后 Windows 继续运行", "Windows keeps running when the app is in the background")
                                     : L("可以在后台运行（服务器模式关闭）", "Could run in the background (server mode is off)")
        case .host3D:
            return L("正在用主机 3D：到后台会暂停。先切到 2D。", "Host 3D is in use: Windows pauses in the background. Switch to 2D first.")
        case .switchPending:
            return L("正在切到 2D：Windows 还没重启显卡。", "Switching to 2D: Windows has not restarted its display adapter yet.")
        case .debugger:
            return L("调试器还连着：到后台会暂停（每个断点都会停住 App）。", "A debugger is attached: Windows pauses in the background (every trap would stop the app).")
        case .notRunning:
            return L("Windows 没有在运行", "Windows is not running")
        @unknown default:
            return ""
        }
    }

    // MARK: Guard: critical temperature or battery

    private func batteryCritical() -> Bool {
        let d = UIDevice.current
        return d.batteryState == .unplugged && d.batteryLevel >= 0 && d.batteryLevel <= 0.05
    }

    /// The guard is for server mode's background running: it pauses Windows only while the app is in the
    /// background. In the foreground it only shows the state (statusText); a pause from the background stays until
    /// conditions are back to normal with the app in front, or the user resumes, which sticks until then.
    func checkGuard() {
        guard backgroundRunning, bridge.isVMRunning else { return }
        let thermal = DeviceStatus.shared.thermalState
        let hot = thermal == .critical
        let empty = batteryCritical()
        let reason = hot ? L("设备严重过热", "The device is critically hot")
                   : empty ? L("电池电量严重不足", "The battery is critically low") : ""
        if reason != guardWarning { guardWarning = reason }
        let normal = !hot && thermal != .serious && !empty
        if normal && resumedByUser { resumedByUser = false }
        let state = UIApplication.shared.applicationState
        // only while Windows really keeps running in the background: otherwise the bridge's own background pause
        // already holds it, and a guard pause would outlive the trip
        if !bridge.guardPaused && !reason.isEmpty && state == .background && !resumedByUser && bridge.runningInBackground {
            guardReason = reason
            bridge.setGuardPaused(true, reason: reason)
            // the Resume Windows button is in the server mode section, and under Display > When leaving the app
            let whereZh = enabled ? "设置 → 网络 → 服务器模式" : "设置 → 显示 → 离开 App 时"
            let whereEn = enabled ? "Settings > Network > Server mode" : "Settings > Display > When leaving the app"
            notify(L("Windows 已暂停", "Windows paused"),
                   body: L("后台运行：\(reason)。打开 App：情况恢复正常后自动继续，也可以在“\(whereZh)”里点“继续运行 Windows”。",
                           "Running in the background: \(reason). Open the app: Windows resumes by itself once conditions are back to normal, or tap Resume Windows in \(whereEn)."))
        } else if bridge.guardPaused && normal && state == .active {
            // cooled down (or charging) and the app is in front: on again by itself
            bridge.setGuardPaused(false, reason: "conditions back to normal")
        }
        refresh()
    }

    /// Sticks: the guard does not pause Windows again until conditions are back to normal.
    func resumeFromGuard() {
        resumedByUser = !guardWarning.isEmpty
        bridge.setGuardPaused(false, reason: resumedByUser ? "resumed by the user (the guard holds off until conditions are normal)"
                                                         : "resumed by the user")
        refresh()
    }

    // MARK: Graphics hot switch

    /// Offers the new mode and has Windows restart its display adapter; progress in graphicsPhase.
    func switchGraphics(to3D: Bool) {
        guard !graphicsPhase.busy else { return }
        guard UIApplication.shared.applicationState == .active else {
            graphicsPhase = .failed(L("App 在后台时不能切换：离开 3D 需要用 GPU。", "Not while the app is in the background: leaving 3D needs the GPU."))
            return
        }
        guard bridge.graphicsTaskPresent else { // the same evidence auto-2D needs (the bridge's autoSwitchPossible)
            graphicsPhase = .failed(L("Windows 里没有 WinKit 的显卡切换任务。在 Windows 里运行一次 WINKIT 盘上的 START.bat（会请求管理员权限），之后就能切换。",
                                      "WinKit's graphics task is not in Windows. Run START.bat from the WINKIT drive in Windows once (it asks for administrator rights); then you can switch."))
            return
        }
        switchFrom = bridge.graphicsMode()
        var why: NSString?
        let seq = bridge.requestGraphics3D(to3D, restartAdapter: true, why: &why)
        guard seq > 0 else {
            graphicsPhase = .failed((why as String?) ?? L("没有切换。", "Not switched."))
            return
        }
        switchSeq = seq
        switchTo3D = to3D
        switchRunSecs = 0
        switchElapsed = 0
        guestAnsweredRun = nil
        lateWatch = false
        backTo3DSeq = 0 // a switch by hand: an earlier "back to 3D once done" no longer applies
        if !to3D { switchedTo2D = true; backgroundSince2D = false }
        graphicsPhase = .waiting(to3D: to3D, started: Date(), guestAnswered: false)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// The fallback: 2D is offered and Windows restarts (the helper's job); it comes back without 3D.
    func restartWindowsWithout3D() -> String {
        var why: NSString?
        if bridge.requestGraphics3D(false, restartAdapter: false, why: &why) < 0 {
            return (why as String?) ?? ""
        }
        switchedTo2D = true
        backgroundSince2D = false
        lateWatch = false
        backTo3DSeq = 0
        refresh()
        if bridge.requestWindowsRestart() {
            return L("Windows 正在重启，回来时不带 3D（直到 App 关闭；3D 设置本身保持打开）。",
                     "Windows is restarting and comes back without 3D (until the app is closed; the 3D setting itself stays on).")
        }
        return L("在 Windows 里用“开始 → 电源 → 重启”：重启后不带 3D（直到 App 关闭；3D 设置本身保持打开）。",
                 "Restart Windows from Start > Power > Restart: it comes back without 3D (until the app is closed; the 3D setting itself stays on).")
    }

    func clearGraphicsResult() {
        if !graphicsPhase.busy { graphicsPhase = .idle }
    }

    static func sharedURL(_ name: String) -> URL {
        VMViewModel.documentsURL.appendingPathComponent("Shared").appendingPathComponent(name)
    }

    /// WinKit's report (gpu_mode_applied.txt): key=value lines.
    private func guestReport() -> [String: String] {
        guard let t = bridge.graphicsSwitchReport() else { return [:] }
        var r: [String: String] = [:]
        for line in t.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { r[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces) }
        }
        return r
    }

    private func pollSwitch() {
        let to3D = switchTo3D
        var answered = true
        if case let .waiting(_, _, a) = graphicsPhase { answered = a } else if !lateWatch { return }
        let g = bridge.graphicsMode()
        let report = guestReport()
        let acked = report["seq"] == String(switchSeq)
        if acked && guestAnsweredRun == nil { guestAnsweredRun = switchRunSecs }
        if acked && !answered, case let .waiting(t, started, _) = graphicsPhase {
            graphicsPhase = .waiting(to3D: t, started: started, guestAnswered: true)
        }
        let hostDone = g.resets > switchFrom.resets && g.driverOK && g.negotiated3D == to3D
        let mode = to3D ? "3D" : "2D"
        let secs = Int(switchRunSecs.rounded())
        if lateWatch {
            // after a timeout only a late success changes what is shown
            if hostDone {
                lateWatch = false
                graphicsPhase = .done(L("Windows 现在是 \(mode) 了（比预期晚）。", "Windows is on \(mode) now (later than expected)."))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                refresh()
            }
            return
        }
        if hostDone && (acked || secs > 20) {
            graphicsPhase = .done(L("Windows 现在是 \(mode)（显卡重启用了 \(secs) 秒，没有重启 Windows）。",
                                    "Windows is on \(mode) now (its display adapter restarted in \(secs) s; Windows did not restart)."))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            refresh()
            if !to3D && backTo3DSeq != 0 && backTo3DSeq == switchSeq { backTo3DSoon() } // auto-2D's switch finished after the app came back
            backTo3DSeq = 0
            return
        }
        if acked, report["result"] == "at-start" {
            backTo3DSeq = 0
            graphicsPhase = .failed(L("Windows 还在启动，没有重启显卡。等它启动完再切换一次。",
                                      "Windows was still starting and did not restart its display adapter. Switch again once it is up."))
            refresh()
            return
        }
        if acked, let result = report["result"], result != "restarted" {
            let detail = report["detail"] ?? result
            backTo3DSeq = 0
            graphicsPhase = .failed(L("Windows 没能重启显卡：\(detail)。显卡设备从现在起提供 \(mode)：重启 Windows 后生效。",
                                      "Windows could not restart its display adapter: \(detail). The display device offers \(mode) from now on: it applies when Windows restarts."))
            refresh()
            return
        }
        if acked, let at = guestAnsweredRun, switchRunSecs - at > 15 {
            let status = report["status"] ?? "?"
            let problem = report["problem"] ?? "0"
            let name = report["name"] ?? L("显卡", "the display adapter")
            backTo3DSeq = 0
            graphicsPhase = .warning(to3D
                ? L("Windows 重启了显卡（\(name)：\(status)，问题代码 \(problem)），但驱动没有用上 3D。再试一次，或重启 Windows。",
                    "Windows restarted its display adapter (\(name): \(status), problem code \(problem)), but its driver did not take 3D. Try again, or restart Windows.")
                : L("Windows 重启了显卡（\(name)：\(status)，问题代码 \(problem)），但它的驱动没有以 2D 运行：没有主机 3D 时，3D 驱动可能不工作，Windows 改用基本显示（画面可能黑屏，远程桌面不受影响）。主机已不再提供 3D，所以后台运行可以用。",
                    "Windows restarted its display adapter (\(name): \(status), problem code \(problem)), but its driver is not running on 2D: without host 3D the 3D driver may not work, and Windows falls back to its basic display (the screen may stay black; Remote Desktop is not affected). Host 3D is no longer in use, so background running works."))
            refresh()
            return
        }
        if secs > 60 {
            backTo3DSeq = 0 // a late success is shown, but does not switch back by itself
            graphicsPhase = .failed(acked
                ? L("Windows 应答了，但显卡在它运行的 60 秒内没有以 \(mode) 启动。可以再试一次；之后如果成功了，这里会更新。",
                    "Windows answered, but its display adapter did not start on \(mode) within 60 s of Windows running. You can try again; if it still succeeds later, this updates.")
                : L("Windows 在运行的 60 秒内没有应答。WinKit 的显卡切换任务可能还没装：在 Windows 里运行一次 START.bat。显卡设备从现在起提供 \(mode)：Windows 重启显卡或重启后生效；之后如果成功了，这里会更新。",
                    "Windows did not answer within 60 s of running. WinKit's graphics task may be missing: run START.bat in Windows once. The display device offers \(mode) from now on: it applies when Windows restarts its display adapter, or restarts; if it still succeeds later, this updates."))
            lateWatch = true // a late success still reports done
            refresh()
        }
    }

    private func appEnteredBackground() {
        let before = graphics // the mode before the bridge's handler (it ran first) asked for a switch
        backTo3DSeq = 0
        if bridge.autoSwitchAway { adoptAutoSwitch(from: before) }
        if switchedTo2D { backgroundSince2D = true }
        refresh()
        var pendingTo3D = false
        if case .waiting(let to3D, _, _) = graphicsPhase { pendingTo3D = to3D }
        if enabled && !isLinux && bridge.isVMRunning && !bridge.autoSwitchAway && (graphicsPhase.busy || blocker == .switchPending) {
            // the bridge has paused Windows (and logged why): the switch goes on when the app is back
            FileHandle.standardError.write(Data("winvm: server mode: in the background with the graphics switch pending: Windows paused until the app is back\n".utf8))
            if pendingTo3D {
                notify(L("Windows 已暂停", "Windows paused"),
                       body: L("正在切回 3D，3D 不能在后台运行，所以 Windows 在后台暂停了。打开 App 继续。",
                               "Windows is switching back to 3D, which cannot run in the background, so it is paused. Open the app to go on."))
            } else {
                notify(L("Windows 已暂停", "Windows paused"),
                       body: L("切到 2D 还没完成，所以 Windows 在后台暂停了。打开 App 让它完成，之后就能在后台运行。",
                               "The switch to 2D was not finished, so Windows is paused in the background. Open the app to let it finish; then it can run in the background."))
            }
        }
        checkGuard() // a critical state pauses Windows now that the app is away
    }

    private func appBecameActive() {
        checkGuard() // cooled down meanwhile: on again
        refresh()
        if bridge.autoSwitchRestored3D && graphicsPhase.busy && switchSeq == bridge.autoSwitchSeq {
            // the bridge found Windows never answered auto-2D's request and offered 3D again: nothing to wait for
            graphicsPhase = .warning(L("Windows 在后台没有应答切到 2D 的请求（WinKit 的显卡切换任务没有运行），所以还是 3D。在 Windows 里运行一次 START.bat。",
                                       "Windows did not answer the switch to 2D in the background (WinKit's graphics task did not run), so it stays on 3D. Run START.bat in Windows once."))
            switchedTo2D = false
            backgroundSince2D = false
            lateWatch = false
            backTo3DSeq = 0
            return
        }
        // optional: back to 3D once the app is in front again, only after this session's switch to 2D and a real
        // trip to the background since (not Control Center, a banner or an alert: those only make the app inactive)
        let wasAway = backgroundSince2D
        backgroundSince2D = false
        guard backgroundRunning && autoBackTo3D && switchedTo2D && wasAway && graphics.capable && !graphics.offered3D else { return }
        if case .waiting(false, _, _) = graphicsPhase {
            backTo3DSeq = switchSeq // the switch to 2D is still under way: 3D once that one is done
            FileHandle.standardError.write(Data("winvm: back to 3D once the switch to 2D that is under way (request \(switchSeq)) is done\n".utf8))
        } else if !graphicsPhase.busy {
            backTo3DSoon()
        }
    }

    private func backTo3DSoon() {
        backTo3DSeq = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, UIApplication.shared.applicationState == .active, !self.graphics.offered3D else { return }
            self.switchGraphics(to3D: true)
        }
    }

    /// The bridge started a switch to 2D as the app left (auto-2D): it is followed here like one started by hand.
    private func adoptAutoSwitch(from before: WinIOSGraphicsMode) {
        let seq = bridge.autoSwitchSeq
        // the same request still followed: a switch to 2D started by hand before the app left goes on as it is
        guard seq > 0, !(seq == switchSeq && graphicsPhase.busy) else { return }
        switchFrom = before
        switchSeq = seq
        switchTo3D = false
        switchRunSecs = 0
        switchElapsed = 0
        guestAnsweredRun = nil
        lateWatch = false
        switchedTo2D = true
        graphicsPhase = .waiting(to3D: false, started: Date(), guestAnswered: false)
    }

    // MARK: Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "applevm.server.\(UUID().uuidString)",
                                                                     content: content, trigger: nil))
    }
}

// MARK: - Test connection: an RDP handshake, not just TCP

/// A forward listens in this device's kernel, which completes a TCP handshake even with nothing behind it in
/// Windows (or with Windows paused). So the test sends an X.224 Connection Request (TPKT, with an RDP negotiation
/// request for TLS and CredSSP) and wants Windows' X.224 Connection Confirm back.
enum RDPProbe {
    enum Outcome: Equatable {
        case rdp(String)    // Windows answered as Remote Desktop
        case notRDP(String) // connected, but no Connection Confirm (something else, or nothing, behind the port)
        case failed(String) // refused, unreachable or timed out
    }

    static let connectionRequest: [UInt8] = [
        0x03, 0x00, 0x00, 0x13,                         // TPKT: version 3, length 19
        0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,       // X.224: length 14, Connection Request, dst/src ref, class 0
        0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00, // RDP_NEG_REQ: TLS | CredSSP
    ]

    /// TPKT version 3 carrying an X.224 Connection Confirm (code 0xd0).
    static func isConnectionConfirm(_ d: [UInt8]) -> Bool {
        d.count >= 6 && d[0] == 0x03 && d[1] == 0x00 && (d[5] & 0xf0) == 0xd0
    }

    /// "127.0.0.1:3389" or "[::1]:3389" -> host and port.
    static func split(_ listen: String) -> (String, Int)? {
        guard let colon = listen.lastIndex(of: ":"), let port = Int(listen[listen.index(after: colon)...]) else { return nil }
        var host = String(listen[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host, port)
    }

    static func probe(host: String, port: Int, timeout: TimeInterval = 6) async -> Outcome {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .failed("bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let queue = DispatchQueue(label: "applevm.rdp-probe")
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            var finished = false
            func finish(_ o: Outcome) {
                queue.async {
                    guard !finished else { return }
                    finished = true
                    conn.cancel()
                    cont.resume(returning: o)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(connectionRequest), completion: .contentProcessed { err in
                        if let err { finish(.failed(err.localizedDescription)); return }
                        conn.receive(minimumIncompleteLength: 6, maximumLength: 256) { data, _, done, err in
                            let bytes = [UInt8](data ?? Data())
                            if isConnectionConfirm(bytes) {
                                finish(.rdp(L("Windows 按远程桌面应答了", "Windows answered as Remote Desktop")))
                            } else if let err {
                                finish(.notRDP(L("连上了，但 Windows 没有应答：", "Connected, but Windows did not answer: ") + err.localizedDescription))
                            } else if bytes.isEmpty || done {
                                finish(.notRDP(L("连上后被关闭：Windows 里的远程桌面可能没打开", "Closed after connecting: Remote Desktop may be off in Windows")))
                            } else {
                                finish(.notRDP(L("有应答，但不是远程桌面", "Something answered, but not Remote Desktop")))
                            }
                        }
                    })
                case .failed(let err), .waiting(let err):
                    finish(.failed(err.localizedDescription))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.notRDP(L("\(Int(timeout)) 秒内没有应答（Windows 暂停了，或远程桌面没打开）",
                                 "No answer within \(Int(timeout)) s (Windows is paused, or Remote Desktop is off)")))
            }
        }
    }
}

// MARK: - The settings section (Settings > Network, above Port forwarding)

struct ServerModeSection: View {
    @ObservedObject private var server = ServerModeController.shared
    @ObservedObject private var status = DeviceStatus.shared
    @StateObject private var forwards = PortForwardingModel()
    @State private var scope: ForwardScope = .vpn
    @State private var ipv6Global = ForwardScope.vpn.defaultIPv6Global
    @State private var addError: String?
    @State private var jobNote: String?
    @State private var fallbackNote: String?
    @State private var probing = false
    @State private var probeResults: [(String, RDPProbe.Outcome)] = []
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var rdpRule: PortForward? {
        let mine = forwards.rules.filter { $0.guestPort == server.rdpGuestPort && $0.proto != "udp" }
        return mine.first { $0.enabled } ?? mine.first
    }

    var body: some View {
        if server.isLinux {
            // Arch Linux always runs host 3D: no server mode, no headless (and no Remote Desktop)
            Section {
                Text(L("Arch Linux 一直用主机 3D：没有服务器模式和无画面模式。App 到后台时 Linux 会暂停。",
                       "Arch Linux always uses host 3D: there is no server mode or headless mode. Linux pauses when the app goes to the background."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("服务器模式", "Server mode"))
            }
        } else {
            windowsBody
        }
    }

    @ViewBuilder
    private var windowsBody: some View {
        Section {
            Toggle(isOn: $server.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("服务器模式", "Server mode"))
                    Text(server.statusText)
                        .font(.caption)
                        .foregroundStyle(server.blocker == .nothing || server.autoSwitchReady || !server.isVMRunning ? Color.secondary : Color.orange)
                }
            }
            if server.guardPaused { // also when auto-2D's background running was paused, with server mode off
                Button(L("继续运行 Windows", "Resume Windows"), systemImage: "play.fill") { server.resumeFromGuard() }
            }
            if server.enabled {
                if server.isVMRunning && (server.blocker == .host3D || server.blocker == .switchPending) {
                    to2DButtons
                }
                Toggle(L("无画面（显示信息卡）", "Headless (an info card instead of the picture)"), isOn: $server.headless)
                Toggle(L("保持屏幕常亮", "Keep the screen on"), isOn: $server.keepScreenOn)
                LabeledContent(L("设备", "Device")) {
                    Text(deviceText)
                        .foregroundStyle(status.isThrottling || status.lowPowerMode ? .orange : .secondary)
                }
                if server.isLiveContainer {
                    Label(L("在 LiveContainer 里运行：后台音频取决于 LiveContainer 自己的设置（UIBackgroundModes），不一定能在后台运行。",
                            "Running inside LiveContainer: background audio depends on LiveContainer's own settings (UIBackgroundModes), so background running may not work."),
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(L("服务器模式", "Server mode"))
        } footer: {
            Text(L("打开后，没有主机 3D 时 App 到后台（或锁屏）Windows 继续运行：远程桌面和端口转发照常应答。靠持续播放静音让 iOS 不挂起 App。耗电、发热；建议接上电源。在后台时，设备严重过热或电量严重不足会暂停 Windows 并发通知（在前台只显示状态）；低电量模式在上面显示。Windows 不能在后台运行时（用着主机 3D 等），屏幕保持常亮。",
                   "On: without host 3D, Windows keeps running while the app is in the background or the phone is locked, and Remote Desktop and port forwards keep answering. iOS keeps the app running because it keeps playing silence. It uses power and heat; keep the phone charging. In the background, a critical temperature or a critically low battery pauses Windows and you get a notification (in the front it is only shown); Low Power Mode is shown above. While Windows could not run in the background (host 3D and so on), the screen stays on."))
        }

        GraphicsSwitchSection()

        if server.enabled {
            remoteDesktopSection
        }
    }

    @ViewBuilder
    private var to2DButtons: some View {
        Button {
            server.switchGraphics(to3D: false)
        } label: {
            Label(L("现在切到 2D（Windows 继续运行）", "Switch to 2D now (Windows keeps running)"), systemImage: "square.on.square")
        }
        .disabled(server.graphicsPhase.busy)
        Button {
            fallbackNote = server.restartWindowsWithout3D()
        } label: {
            Label(L("改为不带 3D 重启 Windows", "Restart Windows without 3D"), systemImage: "arrow.clockwise")
        }
        .disabled(server.graphicsPhase.busy)
        if let fallbackNote {
            Text(fallbackNote).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var deviceText: String {
        var s = status.thermalText
        if status.lowPowerMode { s += L(" · 低电量模式", " · Low Power Mode") }
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            s += " · \(Int((level * 100).rounded()))%"
            if UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full { s += L(" 充电中", " charging") }
        }
        return s
    }

    // MARK: Remote Desktop

    private var remoteDesktopSection: some View {
        Section {
            if let rule = rdpRule {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Circle().fill(rule.state == "listening" ? Color.green : rule.state == "error" ? Color.red : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(rule.name + " · " + ForwardScope(json: rule.scope).title)
                    }
                    if !rule.enabled {
                        Text(L("这个转发关着：在下面的端口转发里打开它。", "This forward is off: turn it on under Port forwarding below."))
                            .font(.caption).foregroundStyle(.orange)
                    } else if rule.state == "listening" {
                        ForwardFamilyLines(rule: rule)
                    } else if !rule.message.isEmpty {
                        Text(rule.message).font(.caption).foregroundStyle(.red)
                    }
                }
                AddressRows(lan: forwards.lan, vpn: forwards.vpn, showLAN: rule.scope == "lan", showVPN: rule.scope == "vpn",
                            showGlobal6: rule.ipv6Global ?? false, showVPNGlobal6: rule.ipv6Global ?? false,
                            port: rule.hostPort, showLoopback: true,
                            title: L("远程桌面连接到", "Connect Remote Desktop to"))
                testRows(rule)
            } else {
                Picker(L("谁能连接", "Who can connect"), selection: $scope) {
                    ForEach(ForwardScope.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: scope) { _, s in ipv6Global = s.defaultIPv6Global }
                Text(scope.detail(global6: ipv6Global)).font(.footnote).foregroundStyle(.secondary)
                ForwardScopeExtras(scope: scope, ipv6Global: $ipv6Global)
                Button(L("添加远程桌面转发", "Add a Remote Desktop forward"), systemImage: "plus.circle") { addForward() }
                if let addError { Text(addError).font(.footnote).foregroundStyle(.red) }
            }
            Button(L("在 Windows 里打开远程桌面", "Turn on Remote Desktop in Windows"), systemImage: "desktopcomputer") { turnOnInWindows() }
                .disabled(!server.isVMRunning)
            if let jobNote { Text(jobNote).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text(L("远程桌面", "Remote Desktop"))
        } footer: {
            Text(L("""
                   检查清单：
                   • Windows 账户要有密码（PIN 不够）。微软账户：用账户邮箱和密码登录；在“设置 → 账户 → 登录选项”里关掉“仅允许 Windows Hello 登录微软账户”；只用过 PIN 的话，先在 Windows 里用密码登录一次。
                   • 远程桌面客户端要允许 UDP（转发同时开了 TCP 和 UDP）。
                   • 远程桌面连上后，虚拟机的屏幕会锁住；要把会话还给这块屏幕而不用重新登录，在远程桌面里运行 C:\\WinKit\\RETURN-TO-SCREEN.bat。
                   • 电话、别的 App 独占音频或内存紧张时，iOS 仍可能暂停或结束 App（对 Windows 相当于断电，磁盘数据是安全的）。
                   • JIT 在 App 活着时一直有效；App 被结束后要在前台重新开 JIT。
                   """,
                   """
                   Checklist:
                   • The Windows account needs a password (a PIN is not enough). Microsoft account: sign in with its email and password; turn off "For improved security, only allow Windows Hello sign-in for Microsoft accounts" in Settings > Accounts > Sign-in options; if you only ever used the PIN, sign in once with the password in Windows first.
                   • Let the Remote Desktop client use UDP (the forward opens TCP and UDP).
                   • A Remote Desktop connection locks the VM's own screen; to hand the session back to it without signing in again, run C:\\WinKit\\RETURN-TO-SCREEN.bat inside the Remote Desktop session.
                   • A phone call, an app taking the audio for itself, or memory pressure can still make iOS stop the app (for Windows a power cut; its disks are safe).
                   • JIT stays on while the app lives; after iOS ends the app, JIT has to be enabled again in the foreground.
                   """))
        }
        .onAppear { forwards.start() }
        .onDisappear { forwards.stop() }
        .onReceive(tick) { _ in forwards.reload(); server.refresh() }
    }

    @ViewBuilder
    private func testRows(_ rule: PortForward) -> some View {
        Button {
            Task { await runProbe(rule) }
        } label: {
            HStack {
                Label(L("测试连接", "Test connection"), systemImage: "checkmark.shield")
                if probing { Spacer(); ProgressView() }
            }
        }
        .disabled(probing || rule.state != "listening")
        ForEach(Array(probeResults.enumerated()), id: \.offset) { item in
            let at = item.element.0
            switch item.element.1 {
            case .rdp(let t):
                Label(at + " · " + t, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .notRDP(let t):
                Label(at + " · " + t, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            case .failed(let t):
                Label(at + " · " + t, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// One IPv4 and one IPv6 address the forward listens on (both families where it listens on both).
    private func runProbe(_ rule: PortForward) async {
        probing = true
        probeResults = []
        var targets: [String] = []
        if let v4 = rule.listen4.first { targets.append(v4) }
        if let v6 = rule.listen6.first { targets.append(v6) }
        for t in targets {
            guard let (host, port) = RDPProbe.split(t) else { continue }
            let o = await RDPProbe.probe(host: host, port: port)
            probeResults.append((t, o))
        }
        probing = false
    }

    private func addForward() {
        guard let preset = PortForwardPreset.all.first else { return }
        var d = PortForwardDraft(name: preset.name, proto: preset.proto, hostPort: preset.hostPort,
                                 guestPort: server.rdpGuestPort)
        d.scope = scope
        d.ipv6Global = ipv6Global // shown with its warning above
        addError = forwards.save(d)
    }

    /// The WinKit helper runs REMOTE-DESKTOP.bat (it asks for administrator rights on the VM's screen): from
    /// C:\WinKit, else from the WINKIT drive.
    private func turnOnInWindows() {
        let line = #"if exist C:\WinKit\REMOTE-DESKTOP.bat (C:\WinKit\REMOTE-DESKTOP.bat) else (powershell -NoProfile -ExecutionPolicy Bypass -Command "$v = Get-Volume -FileSystemLabel WINKIT -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Select-Object -First 1; if ($v) { Start-Process ($v.DriveLetter + ':\REMOTE-DESKTOP.bat') } else { Write-Host 'The WINKIT drive was not found.'; pause }")"#
        if VMViewModel.postAgentJob(line) {
            jobNote = L("Windows 里会弹出管理员权限提示（在虚拟机的屏幕上）：选“是”。完成后点“测试连接”。",
                        "Windows shows an administrator prompt on the VM's screen: choose Yes. Then tap Test connection.")
        } else {
            jobNote = L("Windows 里还没有 WinKit 的后台小助手：在 Windows 里运行一次 WINKIT 盘上的 START.bat，或直接双击 REMOTE-DESKTOP.bat。",
                        "WinKit's background helper is not running in Windows: run START.bat from the WINKIT drive once, or double-click REMOTE-DESKTOP.bat there.")
        }
    }
}

// MARK: - Graphics: 3D / 2D without restarting Windows

struct GraphicsSwitchSection: View {
    @ObservedObject private var server = ServerModeController.shared

    var body: some View {
        if server.isVMRunning && !isLinux {
            Section {
                if server.graphics.capable {
                    Picker(L("图形", "Graphics"), selection: Binding(
                        get: { server.graphics.offered3D },
                        set: { server.switchGraphics(to3D: $0) }
                    )) {
                        Text("3D").tag(true)
                        Text("2D").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(server.graphicsPhase.busy)
                    LabeledContent(L("显卡驱动现在", "Display driver now")) {
                        Text(driverText).foregroundStyle(.secondary)
                    }
                    phaseRow
                    LeavingAppStatusRow() // the settings themselves are under Display > When leaving the app
                } else {
                    Text(L("这次 Windows 启动时没有开主机 3D，现在是 2D。要能随时切换：在“显示”里打开 3D 加速，重启一次 Windows。",
                           "Windows was started without host 3D and runs on 2D. To switch both ways: turn on 3D acceleration under Display and restart Windows once."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("图形：3D / 2D（不重启）", "Graphics: 3D / 2D (no restart)"))
            } footer: {
                Text(L("只有 App 在前台时能切换。Windows 只重启它的显卡（需要 WinKit 的显卡切换任务：START.bat）。风险：屏幕会黑几秒；正在用 3D 的程序会失去显卡设备（多数能恢复，个别会崩溃）；已知的 UTM Neptune 上下文泄漏每切换一次都会变多，直到 App 重启。没有主机 3D 时，Windows 的 3D 驱动可能不工作，Windows 改用基本显示（远程桌面不受影响）。",
                       "Only while the app is in the front. Windows restarts only its display adapter (needs WinKit's graphics task: START.bat). Risks: the screen goes black for a few seconds; apps using 3D lose their graphics device (most recover, some crash); the known UTM Neptune context leak grows with each switch until the app restarts. Without host 3D, Windows' 3D driver may not work and Windows falls back to its basic display (Remote Desktop is not affected)."))
            }
        }
    }

    private var isLinux: Bool { UserDefaults.standard.string(forKey: "winios.machine") == "Arch" }

    private var driverText: String {
        let g = server.graphics
        if !g.driverOK { return L("没有运行（启动中或基本显示）", "not running (starting, or basic display)") }
        return g.negotiated3D ? "3D" : "2D"
    }

    @ViewBuilder
    private var phaseRow: some View {
        switch server.graphicsPhase {
        case .idle:
            EmptyView()
        case let .waiting(to3D, _, answered):
            HStack(spacing: 8) {
                ProgressView()
                // the time Windows ran since the request (paused time does not count)
                Text((answered ? L("Windows 正在重启显卡", "Windows is restarting its display adapter")
                               : L("等 Windows 应答", "Waiting for Windows")) +
                     " → \(to3D ? "3D" : "2D") · \(server.switchElapsed)s" +
                     (server.isVMRunning && WinIOSBridge.shared.machinePaused ? L("（已暂停）", " (paused)") : ""))
                    .font(.footnote)
            }
        case .done(let t):
            Label(t, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                .onTapGesture { server.clearGraphicsResult() }
        case .warning(let t):
            Label(t, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                .onTapGesture { server.clearGraphicsResult() }
        case .failed(let t):
            Label(t, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red)
                .onTapGesture { server.clearGraphicsResult() }
        }
    }
}

// MARK: - Leaving the app: auto-2D, Picture in Picture, back to 3D

/// The three settings for leaving the app with Windows on 3D (ServerModeController), shown in one place: Settings >
/// Display > When leaving the app. The graphics section beside server mode shows only their state
/// (LeavingAppStatusRow).
struct LeavingAppToggles: View {
    @ObservedObject private var server = ServerModeController.shared

    var body: some View {
        Toggle(isOn: $server.auto2D) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("离开 App 时切到 2D", "Switch to 2D when leaving the app"))
                Text(L("Windows 在后台继续运行（不需要服务器模式）", "Windows keeps running in the background (no server mode needed)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Toggle(isOn: $server.pipEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("用画中画显示 Windows", "Show Windows in Picture in Picture"))
                if let why = server.pipBlockedReason {
                    Text(why).font(.caption).foregroundStyle(server.pipEnabled ? Color.orange : Color.secondary)
                }
            }
        }
        // only while leaving the app keeps Windows running; once on it can always be turned off
        .disabled(!server.pipPossible && !server.pipEnabled)
        Toggle(L("回到 App 时切回 3D", "Back to 3D on return"), isOn: $server.autoBackTo3D)
            .disabled(!server.auto2D && !server.enabled)
    }
}

/// The graphics section's line for the settings under Display > When leaving the app.
struct LeavingAppStatusRow: View {
    @ObservedObject private var server = ServerModeController.shared

    var body: some View {
        let on = L("开", "on"), off = L("关", "off")
        VStack(alignment: .leading, spacing: 2) {
            Text(L("离开 App 时：切到 2D \(server.auto2D ? on : off) · 画中画 \(server.pipEnabled ? on : off) · 切回 3D \(server.autoBackTo3D ? on : off)",
                   "When leaving the app: switch to 2D \(server.auto2D ? on : off) · Picture in Picture \(server.pipEnabled ? on : off) · back to 3D \(server.autoBackTo3D ? on : off)"))
                .font(.footnote)
            Text(L("在“设置 → 显示 → 离开 App 时”里更改。", "Change them under Settings > Display > When leaving the app."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LeavingAppSection: View {
    @ObservedObject private var server = ServerModeController.shared

    var body: some View {
        if !server.isLinux {
            Section {
                LeavingAppToggles()
                if server.guardPaused && !server.enabled { // server mode's section has its own
                    Button(L("继续运行 Windows", "Resume Windows"), systemImage: "play.fill") { server.resumeFromGuard() }
                }
            } header: {
                Text(L("离开 App 时", "When leaving the app"))
            } footer: {
                Text(L("切到 2D：App 真正到后台时（不是控制中心或面容 ID 弹窗），用着主机 3D 的 Windows 在后台重启显卡并改用 2D，然后继续运行（靠持续播放静音）；Windows 要以 3D 启动过，需要 WinKit 的显卡切换任务（START.bat）；还没见到这个任务时，Windows 照旧在后台暂停。切换 60 秒内没完成，Windows 暂停到回到 App；Windows 一直没应答的话，回来时仍提供 3D。画中画：在小窗里显示 Windows，只在离开 App 后 Windows 继续运行时可用（切到 2D 或服务器模式）；后台没有 GPU，所以 3D 时小窗停在离开那一刻的画面，切到 2D 后才实时更新。切回 3D：回到 App 后屏幕先是 2D，黑几秒后回到 3D。耗电、发热；正在用 3D 的程序每次切换都会失去显卡设备。",
                       "Switch to 2D: when the app really goes to the background (not Control Center or a Face ID sheet), a Windows using host 3D restarts its display adapter on 2D there and keeps running (the app keeps playing silence). Windows must have been started with 3D, and WinKit's graphics task is needed (START.bat); until it has been seen, Windows pauses in the background as before. If the switch is not done within 60 s, Windows pauses until you come back; if Windows never answered, 3D is offered again on return. Picture in Picture: Windows in a small window, only while Windows keeps running when you leave (Switch to 2D, or server mode); there is no GPU in the background, so on 3D the window holds the picture from the moment you left, and it goes live once Windows is on 2D. Back to 3D: on return the screen is 2D first, then black for a few seconds, then 3D. It uses power and heat; apps using 3D lose their graphics device at each switch."))
            }
        }
    }
}

// MARK: - Headless: the info card in place of the picture

struct HeadlessCard: View {
    @ObservedObject private var server = ServerModeController.shared
    @ObservedObject private var status = DeviceStatus.shared
    @StateObject private var forwards = PortForwardingModel()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(white: 0.06)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(L("Windows 正在运行（无画面）", "Windows is running (headless)"), systemImage: "server.rack")
                        .font(.title3.weight(.semibold))
                    Text(server.statusText).font(.callout).foregroundStyle(.secondary)
                    if let since = server.runningSince {
                        TimelineView(.periodic(from: since, by: 30)) { ctx in
                            Text(L("已运行 ", "Up ") + Self.duration(ctx.date.timeIntervalSince(since)))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Text(status.thermalText + (status.lowPowerMode ? L(" · 低电量模式", " · Low Power Mode") : "") + battery)
                        .font(.callout)
                        .foregroundStyle(status.isThrottling ? .orange : .secondary)
                    ForEach(forwards.rules.filter { $0.enabled && $0.state == "listening" }) { rule in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.callout.weight(.medium))
                            ForwardFamilyLines(rule: rule)
                        }
                    }
                    if server.guardPaused {
                        Button(L("继续运行 Windows", "Resume Windows"), systemImage: "play.fill") { server.resumeFromGuard() }
                            .buttonStyle(.bordered)
                    }
                    Button(L("显示 Windows", "Show Windows"), systemImage: "display") {
                        server.headless = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onAppear { forwards.start() }
        .onDisappear { forwards.stop() }
        .onReceive(tick) { _ in forwards.reload(); server.refresh() }
    }

    private var battery: String {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? "" : " · \(Int((level * 100).rounded()))%"
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}

// MARK: - The session's More menu

struct ServerModeMenuItems: View {
    @ObservedObject private var server = ServerModeController.shared
    let isLinux: Bool

    var body: some View {
        if !isLinux { // Arch Linux always runs host 3D: no server mode, no headless, no graphics switch
            Section(L("服务器", "Server")) {
                items
            }
        }
    }

    @ViewBuilder
    private var items: some View {
        Toggle(L("服务器模式", "Server mode"), systemImage: "server.rack", isOn: $server.enabled)
        if server.enabled {
            Toggle(L("无画面", "Headless"), systemImage: "rectangle.slash", isOn: $server.headless)
        }
        if server.isVMRunning && server.graphics.capable {
            Picker(selection: Binding(
                get: { server.graphics.offered3D },
                set: { server.switchGraphics(to3D: $0) }
            )) {
                Text("3D").tag(true)
                Text("2D").tag(false)
            } label: {
                Label(L("图形：", "Graphics: ") + (server.graphics.offered3D ? "3D" : "2D"), systemImage: "cube")
            }
            .pickerStyle(.menu)
            .disabled(server.graphicsPhase.busy)
        }
    }
}
