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
    /// Off by default in server mode: the locked phone is just "the background", where Windows keeps running.
    @Published var keepScreenOn: Bool = UserDefaults.standard.bool(forKey: "winios.serverKeepScreenOn") {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: "winios.serverKeepScreenOn"); applyToBridge() }
    }
    /// Switch back to 3D by itself when the app comes back to the front (after this session's switch to 2D).
    @Published var autoBackTo3D: Bool = UserDefaults.standard.bool(forKey: "winios.serverAuto3D") {
        didSet { UserDefaults.standard.set(autoBackTo3D, forKey: "winios.serverAuto3D") }
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
    @Published private(set) var audioRunning = false
    @Published private(set) var graphicsPhase: GraphicsSwitchPhase = .idle
    @Published private(set) var runningSince: Date?
    /// This session switched to 2D (what "back to 3D" undoes).
    private(set) var switchedTo2D = false

    private var bridge: WinIOSBridge { WinIOSBridge.shared }
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var thermalSink: AnyCancellable?
    private var switchSeq: Int64 = 0
    private var switchFrom = WinIOSGraphicsMode()
    private var guestAnsweredAt: Date?

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ServerModeController.shared.appBecameActive() }
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
    func applyToBridge() {
        let b = bridge
        b.runInBackground = enabled
        b.audioKeepAlive = enabled
        b.keepScreenOn = !enabled || keepScreenOn
        b.headless = enabled && headless
        if enabled { UIDevice.current.isBatteryMonitoringEnabled = true }
        refresh()
    }

    var headlessActive: Bool { enabled && headless && bridge.isVMRunning }
    var isVMRunning: Bool { bridge.isVMRunning }
    var isLiveContainer: Bool { getenv("LC_HOME_PATH") != nil }

    func refresh() {
        let b = bridge
        let running = b.isVMRunning
        if running && runningSince == nil { runningSince = Date() }
        if !running { runningSince = nil; if graphicsPhase.busy { graphicsPhase = .idle } }
        let bl = b.backgroundBlocker
        if bl != blocker { blocker = bl }
        let g = b.graphicsMode()
        if !Self.same(g, graphics) { graphics = g }
        if b.guardPaused != guardPaused { guardPaused = b.guardPaused }
        let a = b.audioOutputRunning
        if a != audioRunning { audioRunning = a }
    }

    private static func same(_ a: WinIOSGraphicsMode, _ b: WinIOSGraphicsMode) -> Bool {
        a.capable == b.capable && a.offered3D == b.offered3D && a.negotiated3D == b.negotiated3D &&
            a.driverOK == b.driverOK && a.resets == b.resets
    }

    private func tick() {
        refresh()
        if graphicsPhase.busy { pollSwitch() }
        if enabled { checkGuard() }
    }

    // MARK: Status text

    var statusText: String {
        if !bridge.isVMRunning { return L("Windows 没有在运行", "Windows is not running") }
        if guardPaused { return L("已暂停：", "Paused: ") + guardReason }
        switch blocker {
        case .nothing:
            return enabled ? L("App 到后台后 Windows 继续运行", "Windows keeps running when the app is in the background")
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

    func checkGuard() {
        guard enabled, bridge.isVMRunning else { return }
        let thermal = DeviceStatus.shared.thermalState
        let hot = thermal == .critical
        let empty = batteryCritical()
        if !bridge.guardPaused && (hot || empty) {
            guardReason = hot ? L("设备严重过热", "the device is critically hot")
                              : L("电池电量严重不足", "the battery is critically low")
            bridge.setGuardPaused(true, reason: guardReason)
            notify(L("Windows 已暂停", "Windows paused"),
                   body: L("服务器模式：\(guardReason)。打开 App 后可以继续。", "Server mode: \(guardReason). Open the app to resume it."))
        } else if bridge.guardPaused && !hot && thermal != .serious && !empty && UIApplication.shared.applicationState == .active {
            // cooled down (or charging) and the app is in front: on again by itself
            bridge.setGuardPaused(false, reason: "conditions back to normal")
        }
        refresh()
    }

    func resumeFromGuard() {
        bridge.setGuardPaused(false, reason: "resumed by the user")
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
        guard VMViewModel.guestHelperAlive || FileManager.default.fileExists(atPath: Self.sharedURL("gpu_mode_applied.txt").path) else {
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
        guestAnsweredAt = nil
        if !to3D { switchedTo2D = true }
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
        guard case let .waiting(to3D, started, answered) = graphicsPhase else { return }
        let g = bridge.graphicsMode()
        let report = guestReport()
        let acked = report["seq"] == String(switchSeq)
        if acked && guestAnsweredAt == nil { guestAnsweredAt = Date() }
        if acked && !answered { graphicsPhase = .waiting(to3D: to3D, started: started, guestAnswered: true) }
        let hostDone = g.resets > switchFrom.resets && g.driverOK && g.negotiated3D == to3D
        let mode = to3D ? "3D" : "2D"
        let secs = Int(Date().timeIntervalSince(started).rounded())
        if hostDone && (acked || secs > 20) {
            graphicsPhase = .done(L("Windows 现在是 \(mode)（显卡重启用了 \(secs) 秒，没有重启 Windows）。",
                                    "Windows is on \(mode) now (its display adapter restarted in \(secs) s; Windows did not restart)."))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            refresh()
            return
        }
        if acked, report["result"] == "at-start" {
            graphicsPhase = .failed(L("Windows 还在启动，没有重启显卡。等它启动完再切换一次。",
                                      "Windows was still starting and did not restart its display adapter. Switch again once it is up."))
            refresh()
            return
        }
        if acked, let result = report["result"], result != "restarted" {
            let detail = report["detail"] ?? result
            graphicsPhase = .failed(L("Windows 没能重启显卡：\(detail)。显卡设备从现在起提供 \(mode)：重启 Windows 后生效。",
                                      "Windows could not restart its display adapter: \(detail). The display device offers \(mode) from now on: it applies when Windows restarts."))
            refresh()
            return
        }
        if acked, let at = guestAnsweredAt, Date().timeIntervalSince(at) > 15 {
            let status = report["status"] ?? "?"
            let problem = report["problem"] ?? "0"
            let name = report["name"] ?? L("显卡", "the display adapter")
            graphicsPhase = .warning(to3D
                ? L("Windows 重启了显卡（\(name)：\(status)，问题代码 \(problem)），但驱动没有用上 3D。再试一次，或重启 Windows。",
                    "Windows restarted its display adapter (\(name): \(status), problem code \(problem)), but its driver did not take 3D. Try again, or restart Windows.")
                : L("Windows 重启了显卡（\(name)：\(status)，问题代码 \(problem)），但它的驱动没有以 2D 运行：没有主机 3D 时，3D 驱动可能不工作，Windows 改用基本显示（画面可能黑屏，远程桌面不受影响）。主机已不再提供 3D，所以后台运行可以用。",
                    "Windows restarted its display adapter (\(name): \(status), problem code \(problem)), but its driver is not running on 2D: without host 3D the 3D driver may not work, and Windows falls back to its basic display (the screen may stay black; Remote Desktop is not affected). Host 3D is no longer in use, so background running works."))
            refresh()
            return
        }
        if secs > 60 {
            graphicsPhase = .failed(acked
                ? L("Windows 应答了，但显卡 60 秒内没有以 \(mode) 启动。可以再试一次。", "Windows answered, but its display adapter did not start on \(mode) within 60 s. You can try again.")
                : L("Windows 60 秒内没有应答。WinKit 的显卡切换任务可能还没装：在 Windows 里运行一次 START.bat。显卡设备从现在起提供 \(mode)：Windows 重启显卡或重启后生效。",
                    "Windows did not answer within 60 s. WinKit's graphics task may be missing: run START.bat in Windows once. The display device offers \(mode) from now on: it applies when Windows restarts its display adapter, or restarts."))
            refresh()
        }
    }

    private func appBecameActive() {
        checkGuard() // cooled down meanwhile: on again
        refresh()
        // optional: back to 3D once the app is in front again (only after this session's switch to 2D)
        if enabled && autoBackTo3D && switchedTo2D && graphics.capable && !graphics.offered3D && !graphicsPhase.busy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, UIApplication.shared.applicationState == .active else { return }
                self.switchGraphics(to3D: true)
            }
        }
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
        Section {
            Toggle(isOn: $server.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("服务器模式", "Server mode"))
                    Text(server.statusText)
                        .font(.caption)
                        .foregroundStyle(server.blocker == .nothing || !server.isVMRunning ? Color.secondary : Color.orange)
                }
            }
            if server.enabled {
                if server.guardPaused {
                    Button(L("继续运行 Windows", "Resume Windows"), systemImage: "play.fill") { server.resumeFromGuard() }
                }
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
            Text(L("打开后，没有主机 3D 时 App 到后台（或锁屏）Windows 继续运行：远程桌面和端口转发照常应答。靠持续播放静音让 iOS 不挂起 App。耗电、发热；建议接上电源。设备严重过热或电量严重不足时会暂停 Windows 并发通知；低电量模式在上面显示。",
                   "On: without host 3D, Windows keeps running while the app is in the background or the phone is locked, and Remote Desktop and port forwards keep answering. iOS keeps the app running because it keeps playing silence. It uses power and heat; keep the phone charging. At a critical temperature or a critically low battery Windows is paused and you get a notification; Low Power Mode is shown above."))
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
                            showGlobal6: rule.ipv6Global ?? true, port: rule.hostPort, showLoopback: true,
                            title: L("远程桌面连接到", "Connect Remote Desktop to"))
                testRows(rule)
            } else {
                Picker(L("谁能连接", "Who can connect"), selection: $scope) {
                    ForEach(ForwardScope.allCases) { Text($0.title).tag($0) }
                }
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
                    if server.enabled {
                        Toggle(L("回到前台时自动切回 3D", "Back to 3D when the app returns to the front"), isOn: $server.autoBackTo3D)
                    }
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
        case let .waiting(to3D, started, answered):
            HStack(spacing: 8) {
                ProgressView()
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    Text((answered ? L("Windows 正在重启显卡", "Windows is restarting its display adapter")
                                   : L("等 Windows 应答", "Waiting for Windows")) +
                         " → \(to3D ? "3D" : "2D") · \(Int(ctx.date.timeIntervalSince(started)))s")
                        .font(.footnote)
                }
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
        Section(L("服务器", "Server")) {
            Toggle(L("服务器模式", "Server mode"), systemImage: "server.rack", isOn: $server.enabled)
            if server.enabled {
                Toggle(L("无画面", "Headless"), systemImage: "rectangle.slash", isOn: $server.headless)
            }
            if !isLinux && server.isVMRunning && server.graphics.capable {
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
}
