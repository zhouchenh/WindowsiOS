// SPDX-License-Identifier: GPL-2.0-or-later
import BackgroundTasks
import Foundation
import Metal
import SwiftUI
import UIKit

// The background test (Settings > Display > Background test): what really happens on this phone when the app leaves,
// for auto-2D and Picture in Picture (ServerMode.swift, winios_pip.m). Armed, the next trip to the background is
// logged with times relative to willResignActive:
//   - a trivial Metal command buffer committed every ~16 ms on a background queue: its status and error code (when the
//     GPU is refused, and when it works again), as changes;
//   - PiP willStart / didStart / failed and its other events, didEnterBackground, willEnterForeground, didBecomeActive;
//   - whether BGTaskScheduler offers background GPU at all (supportedResources);
//   - if a graphics switch runs, its timeline: the offer, Windows' answer (gpu_mode_applied.txt), the display driver's
//     restart and the mode it took, and the 3D device's background drain.
// Lines go to winvm.log (stderr, "winvm: bgtest:"), the whole log to Documents/background_test.txt, and a short
// summary to the settings. Off unless armed; one trip, then it disarms. A trip that only makes the app inactive
// (Control Center, a banner) is not a trip to the background: the test stays armed.

/// The Metal probe: one tiny blit per ~16 ms on its own queue; reports each change of (status, error code).
private final class MetalProbe: @unchecked Sendable {
    private let device = MTLCreateSystemDefaultDevice()
    private let queue: MTLCommandQueue?
    private let buffer: MTLBuffer?
    private let q = DispatchQueue(label: "applevm.bgtest.metal", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let t0: CFAbsoluteTime
    private let report: @Sendable (String) -> Void
    // the probe's queue only
    private var inFlight = 0, committed = 0, ok = 0, failed = 0, noBuffer = 0
    private var fill: UInt8 = 0
    private var last: (Int, Int)?
    private var firstFail: Double?, lastOK: Double?, firstOKAfterFail: Double?

    init(t0: CFAbsoluteTime, report: @escaping @Sendable (String) -> Void) {
        self.t0 = t0
        self.report = report
        queue = device?.makeCommandQueue()
        buffer = device?.makeBuffer(length: 256, options: .storageModeShared)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private static func name(_ s: Int) -> String {
        ["not enqueued", "enqueued", "committed", "scheduled", "completed", "error"][min(max(s, 0), 5)]
    }

    private func tick() {
        guard inFlight < 8 else { return }
        let at = CFAbsoluteTimeGetCurrent() - t0
        guard let queue, let buffer, let cb = queue.makeCommandBuffer() else {
            noBuffer += 1
            if noBuffer == 1 { report(String(format: "metal: +%.3f s no command buffer", at)) }
            return
        }
        fill &+= 1
        if let enc = cb.makeBlitCommandEncoder() {
            enc.fill(buffer: buffer, range: 0..<16, value: fill)
            enc.endEncoding()
        }
        inFlight += 1
        committed += 1
        cb.addCompletedHandler { [weak self] done in
            let status = Int(done.status.rawValue)
            let code = (done.error as NSError?)?.code ?? 0
            self?.q.async { self?.finished(at: at, status: status, code: code) }
        }
        cb.commit()
    }

    private func finished(at: Double, status: Int, code: Int) {
        inFlight -= 1
        if status == Int(MTLCommandBufferStatus.completed.rawValue) {
            ok += 1
            if firstFail != nil && firstOKAfterFail == nil { firstOKAfterFail = at }
            if firstFail == nil { lastOK = at }
        } else {
            failed += 1
            if firstFail == nil { firstFail = at }
        }
        if last == nil || last! != (status, code) {
            last = (status, code)
            report(String(format: "metal: committed at +%.3f s: %@ (error %d)", at, Self.name(status), code))
        }
    }

    /// Stops, and the totals.
    func stop() -> String {
        timer?.cancel()
        timer = nil
        return q.sync {
            var s = "metal: \(committed) committed, \(ok) completed, \(failed) refused or failed"
            if noBuffer > 0 { s += ", \(noBuffer) without a command buffer" }
            if let f = firstFail { s += String(format: "; last success before +%.3f s, first refusal +%.3f s", lastOK ?? 0, f) }
            else { s += "; never refused" }
            if let b = firstOKAfterFail { s += String(format: ", working again at +%.3f s", b) }
            else if firstFail != nil { s += ", not working again by the end" }
            return s
        }
    }
}

@MainActor
final class BackgroundTest: ObservableObject {
    static let shared = BackgroundTest()

    @Published private(set) var armed = false
    @Published private(set) var running = false
    @Published private(set) var summary: String = UserDefaults.standard.string(forKey: "winios.bgTestSummary") ?? ""
    /// The audio session while PiP is armed (bridge.pipAudioCategory): 0 the app's own, 1 Playback that mixes,
    /// 2 Playback alone. Not saved.
    @Published var pipAudio: Int = 0 {
        didSet { WinIOSBridge.shared.pipAudioCategory = pipAudio }
    }

    private var t0: CFAbsoluteTime = 0
    private var lines: [String] = []
    private var first: [String: Double] = [:]
    private var sawBackground = false
    private var probe: MetalProbe?
    private var poll: Timer?
    private var finishWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    // the switch timeline
    private var lastMode = WinIOSGraphicsMode()
    private var lastReport = ""
    private var lastDrain = ""
    private var lastDrainAt: Double = -10
    private var lastAway = false
    private var lastPaused = false

    private var bridge: WinIOSBridge { WinIOSBridge.shared }

    private init() {
        let nc = NotificationCenter.default
        // queue nil: run as the notification is posted (main thread), so the times are the system's
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { note in
                MainActor.assumeIsolated { body(note) }
            })
        }
        on(UIApplication.willResignActiveNotification) { _ in self.willResignActive() }
        on(UIApplication.didEnterBackgroundNotification) { _ in
            guard self.running else { return }
            self.sawBackground = true
            self.mark("didEnterBackground", key: "background")
        }
        on(UIApplication.willEnterForegroundNotification) { _ in
            if self.running { self.mark("willEnterForeground", key: "foreground") }
        }
        on(UIApplication.didBecomeActiveNotification) { _ in self.didBecomeActive() }
        on(.WinIOSPiPEvent) { note in
            guard self.running, let e = note.userInfo?["event"] as? String else { return }
            let key: String? = e.hasPrefix("willStart") ? "pipWillStart" : e.hasPrefix("didStart") ? "pipDidStart"
                : e.hasPrefix("failed") ? "pipFailed" : e.hasPrefix("didStop") ? "pipDidStop" : nil
            self.mark("pip: " + e, key: key)
        }
    }

    func arm() {
        guard !armed else { return }
        armed = true
        FileHandle.standardError.write(Data("winvm: bgtest: armed: the next trip to the background is logged\n".utf8))
    }

    func disarm() {
        if running { finish(L("测试中途关闭", "stopped by hand")) }
        armed = false
    }

    // MARK: The trip

    private func willResignActive() {
        if running {
            mark("willResignActive again")
            return
        }
        guard armed else { return }
        begin()
    }

    private func begin() {
        t0 = CFAbsoluteTimeGetCurrent()
        running = true
        lines = []
        first = [:]
        sawBackground = false
        finishWork?.cancel()
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let server = ServerModeController.shared
        let g = bridge.graphicsMode()
        lastMode = g
        lastReport = bridge.graphicsSwitchReport() ?? ""
        lastAway = bridge.autoSwitchAway
        lastPaused = bridge.machinePaused
        let pip = WinIOSPictureInPicture.shared
        mark("willResignActive (background test, \(df.string(from: Date())))")
        mark("machine: \(server.isLinux ? "Arch Linux" : "Windows"), running \(bridge.isVMRunning), " + modeText(g))
        mark("settings: auto-2D \(server.auto2D), PiP \(server.pipEnabled), back to 3D \(server.autoBackTo3D), server mode \(server.enabled); auto-2D would switch \(bridge.autoSwitchPossible)")
        mark("pip: supported \(pip.supported), possible \(pip.possible), armed \(pip.armed), frames so far \(pip.framesSent); audio session \(bridge.audioCategoryName)")
        if #available(iOS 26.0, *) {
            let r = BGTaskScheduler.supportedResources
            mark("BGTaskScheduler supportedResources: raw \(r.rawValue), gpu \(r.contains(.gpu))")
            first["bgGPU"] = r.contains(.gpu) ? 1 : 0
        } else {
            mark("BGTaskScheduler supportedResources: not available before iOS 26")
        }
        let p = MetalProbe(t0: t0) { line in
            DispatchQueue.main.async { BackgroundTest.shared.markProbe(line) }
        }
        probe = p
        p.start()
        poll?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { BackgroundTest.shared.pollSwitch() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func didBecomeActive() {
        guard running else { return }
        mark("didBecomeActive", key: "active")
        if !sawBackground {
            // Control Center, a banner, a sheet: not the background. Still armed for the real one.
            mark("inactive only (no background): still armed")
            stop(write: false)
            return
        }
        // a few seconds more: when the GPU works again, the switch back
        let w = DispatchWorkItem { [weak self] in self?.finish(nil) }
        finishWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    private func markProbe(_ line: String) {
        guard running else { return }
        mark(line, key: line.contains("completed") ? nil : "metalRefused")
    }

    private func mark(_ what: String, key: String? = nil) {
        let at = CFAbsoluteTimeGetCurrent() - t0
        if let key, first[key] == nil { first[key] = at }
        let line = String(format: "+%.3f s  ", at) + what
        lines.append(line)
        FileHandle.standardError.write(Data("winvm: bgtest: \(line)\n".utf8))
    }

    private func modeText(_ g: WinIOSGraphicsMode) -> String {
        "graphics: offered \(g.offered3D ? "3D" : "2D"), driver \(g.driverOK ? (g.negotiated3D ? "3D" : "2D") : "not running"), resets \(g.resets)"
    }

    /// The switch timeline, the drain, the pause, every 0.25 s while the test runs.
    private func pollSwitch() {
        guard running else { return }
        if CFAbsoluteTimeGetCurrent() - t0 > 15 * 60 {
            finish(L("15 分钟上限", "15 minute limit"))
            return
        }
        let g = bridge.graphicsMode()
        if g.offered3D != lastMode.offered3D { mark("offer: \(g.offered3D ? "3D" : "2D") from the next driver start", key: g.offered3D ? "offer3D" : "offer2D") }
        if g.resets != lastMode.resets { mark("display driver reset (#\(g.resets))", key: "driverReset") }
        if g.driverOK != lastMode.driverOK || g.negotiated3D != lastMode.negotiated3D || g.resets != lastMode.resets {
            if g.driverOK {
                mark("display driver started: \(g.negotiated3D ? "3D" : "2D")", key: g.negotiated3D ? "driver3D" : "driver2D")
            } else if lastMode.driverOK {
                mark("display driver stopped")
            }
        }
        lastMode = g
        let report = bridge.graphicsSwitchReport() ?? ""
        if report != lastReport {
            lastReport = report
            let flat = report.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).filter { !$0.hasPrefix("time=") }.joined(separator: " ")
            mark("Windows answered: " + flat, key: "guestAck")
        }
        let away = bridge.autoSwitchAway
        if away != lastAway {
            lastAway = away
            mark(away ? "auto-2D: switching in the background (drain on)" : "auto-2D: over (drain off)")
        }
        let paused = bridge.machinePaused
        if paused != lastPaused {
            lastPaused = paused
            mark(paused ? "Windows paused" : "Windows running", key: paused ? "paused" : nil)
        }
        // the drain's counters, at most once a second
        let now = CFAbsoluteTimeGetCurrent() - t0
        if now - lastDrainAt >= 1, let line = bridge.gpuStatusLine(), let r = line.range(of: "drain=") {
            let drain = String(line[r.lowerBound...])
            if drain != lastDrain {
                lastDrain = drain
                lastDrainAt = now
                mark("3D " + drain)
            }
        }
    }

    private func stop(write: Bool) {
        finishWork?.cancel()
        finishWork = nil
        poll?.invalidate()
        poll = nil
        let totals = probe?.stop() ?? ""
        probe = nil
        if write && !totals.isEmpty { mark(totals) }
        running = false
    }

    private func at(_ key: String) -> String {
        guard let t = first[key] else { return "-" }
        return String(format: "+%.2f s", t)
    }

    private func finish(_ why: String?) {
        guard running else { return }
        if let why { mark("ended: " + why) }
        if let line = bridge.gpuStatusLine(), let r = line.range(of: "drain=") { mark("3D " + String(line[r.lowerBound...])) }
        mark(modeText(bridge.graphicsMode()))
        stop(write: true)
        armed = false
        var s: [String] = []
        s.append(L("后台：", "Background: ") + at("background") + L("；回到前台：", "; foreground: ") + at("foreground") +
                 L("；活跃：", "; active: ") + at("active"))
        s.append("Metal: " + L("第一次被拒 ", "first refused ") + at("metalRefused"))
        if let t = lines.last(where: { $0.contains("metal: ") && $0.contains("committed,") }) {
            s.append(String(t.drop(while: { $0 != "m" })))
        }
        s.append(L("画中画：", "PiP: ") + "willStart " + at("pipWillStart") + ", didStart " + at("pipDidStart") +
                 (first["pipFailed"] != nil ? ", failed " + at("pipFailed") : "") +
                 (first["pipWillStart"] == nil && first["pipFailed"] == nil ? L("（没有启动）", " (did not start)") : ""))
        if first["offer2D"] != nil || first["driverReset"] != nil || first["guestAck"] != nil {
            s.append(L("切换：", "Switch: ") + L("提供 2D ", "2D offered ") + at("offer2D") + L("，Windows 应答 ", ", Windows answered ") +
                     at("guestAck") + L("，驱动重启 ", ", driver reset ") + at("driverReset") + L("，2D 驱动 ", ", 2D driver ") +
                     at("driver2D") + (first["driver3D"] != nil ? L("，3D 驱动 ", ", 3D driver ") + at("driver3D") : "") +
                     (first["paused"] != nil ? L("，暂停 ", ", paused ") + at("paused") : ""))
        }
        if let d = lines.last(where: { $0.contains("3D drain=") }), let r = d.range(of: "drain=") {
            s.append(String(d[r.lowerBound...]))
        }
        if let gpu = first["bgGPU"] { s.append(L("后台 GPU（BGTaskScheduler）：", "Background GPU (BGTaskScheduler): ") + (gpu > 0 ? L("支持", "yes") : L("不支持", "no"))) }
        let text = s.joined(separator: "\n")
        summary = text
        UserDefaults.standard.set(text, forKey: "winios.bgTestSummary")
        let file = VMViewModel.documentsURL.appendingPathComponent("background_test.txt")
        let body = (["Background test"] + lines + ["", "Summary:", text]).joined(separator: "\n") + "\n"
        try? body.write(to: file, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("winvm: bgtest: done, written to background_test.txt\n".utf8))
    }
}

// MARK: - Settings > Display

struct BackgroundTestSection: View {
    @ObservedObject private var test = BackgroundTest.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { test.armed }, set: { $0 ? test.arm() : test.disarm() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("测试下一次到后台", "Test the next trip to the background"))
                    if test.running {
                        Text(L("正在记录：回到 App 几秒后结束", "Recording: it ends a few seconds after you come back"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Picker(L("画中画时的音频会话", "Audio session with Picture in Picture on"), selection: $test.pipAudio) {
                Text(L("App 自己的（播放和录音，混音）", "The app's own (play and record, mixes)")).tag(0)
                Text(L("播放（混音）", "Playback (mixes)")).tag(1)
                Text(L("播放（独占）", "Playback (alone)")).tag(2)
            }
            if !test.summary.isEmpty {
                Text(test.summary)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text(L("后台测试", "Background test"))
        } footer: {
            Text(L("诊断用。打开后，下一次 App 到后台（主屏幕手势、锁屏、切到别的 App）时记录：GPU 什么时候被拒绝、画中画是否启动、图形切换的每一步。回到 App 几秒后结束，结果在这里、winvm.log 和“文件”里的 background_test.txt。只经过控制中心或横幅不算，测试保持打开。音频会话只在画中画打开时改变，App 重启后恢复默认；“独占”会停掉别的 App 的声音，Windows 的麦克风也不可用。",
                   "Diagnostics. On, the next time the app goes to the background (home gesture, lock, another app) is logged: when the GPU is refused, whether Picture in Picture starts, each step of a graphics switch. It ends a few seconds after you come back; the results are here, in winvm.log and in background_test.txt in Files. Control Center or a banner alone does not count; the test stays on. The audio session changes only while Picture in Picture is on, and goes back to the default when the app restarts; Alone stops other apps' sound, and Windows' microphone is off."))
        }
    }
}
