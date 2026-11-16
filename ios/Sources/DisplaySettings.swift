// SPDX-License-Identifier: GPL-2.0-or-later
//
// How Windows is shaped for the glass: Display Size, Sharpness, frame rate and immersive sizing, remembered
// for each screen (inner, laptop lid, cover), plus the measurements and counters Settings > Status shows.
// The sizing itself (the guest mode, Windows' scale, the reshape pipeline) runs in the bridge
// (winios_bridge.m); the presenter (devices/fb_metal.m) draws it 1:1. This file is the model and two
// Form sections another view mounts: DisplaySettingsSection and DisplayStatusSection.
import Combine
import Foundation
import SwiftUI
import UIKit

/// The screens the app can be on. Each remembers its own Display Size, Sharpness, frame rate and immersive choice.
enum DisplaySurface: String, CaseIterable, Codable {
    case inner  // the unfolded inner screen (Studio)
    case lid    // the laptop posture's top half
    case cover  // the outer cover screen
    case main   // any device that does not fold

    var title: String {
        switch self {
        case .inner: return L("内屏", "Inner screen")
        case .lid: return L("笔记本上半屏", "Laptop lid")
        case .cover: return L("外屏", "Cover screen")
        case .main: return L("屏幕", "Screen")
        }
    }
}

/// How big things look in Windows. Apple's own Displays wording: Larger Text, Default, More Space.
enum DisplaySizePreset: Int, CaseIterable {
    case largerText = 0
    case standard = 1
    case moreSpace = 2

    var title: String {
        switch self {
        case .largerText: return L("更大字体", "Larger Text")
        case .standard: return L("默认", "Default")
        case .moreSpace: return L("更多空间", "More Space")
        }
    }
}

/// Sharp: one Windows pixel per panel pixel. Balanced: half each way, shown at exactly 2x.
enum DisplaySharpness: Int, CaseIterable {
    case automatic = 0
    case sharp = 1
    case balanced = 2

    var title: String {
        switch self {
        case .automatic: return L("自动", "Automatic")
        case .sharp: return L("锐利", "Sharp")
        case .balanced: return L("均衡", "Balanced")
        }
    }
}

/// What immersive full screen does to Windows' size.
enum ImmersiveSizing: String, CaseIterable {
    case fullPanel   // Windows takes the whole panel (sharpest, one re-mode)
    case keepSize    // Windows keeps its resolution (no re-mode flash)

    var title: String {
        switch self {
        case .fullPanel: return L("Windows 改成整块屏幕的大小", "Resize Windows to the whole panel")
        case .keepSize: return L("保持 Windows 当前分辨率", "Keep Windows' resolution")
        }
    }
}

/// One surface's measurements (UX P0-1), as the view last saw them. Points unless named px.
struct DisplayMetrics: Codable, Equatable {
    var nativeWidth = 0.0, nativeHeight = 0.0 // UIScreen.nativeBounds (px, portrait-up)
    var nativeScale = 0.0, scale = 0.0
    var windowWidth = 0.0, windowHeight = 0.0
    var safeTop = 0.0, safeLeft = 0.0, safeBottom = 0.0, safeRight = 0.0
    var viewX = 0.0, viewY = 0.0, viewWidth = 0.0, viewHeight = 0.0 // the Windows view, in the window
    var drawableWidth = 0.0, drawableHeight = 0.0
    var verticalBarEdge = "-"
    var occlusion: [String] = []
    var division: [String] = []

    var orientation: String { windowWidth >= windowHeight ? "landscape" : "portrait" }
    /// The view's frame lands on whole panel pixels (no resampling by the compositor).
    var pixelAligned: Bool {
        let n = nativeScale
        func whole(_ v: Double) -> Bool { abs(v * n - (v * n).rounded()) < 0.02 }
        return whole(viewX) && whole(viewY) && whole(viewWidth) && whole(viewHeight)
    }

    var logLine: String {
        func f(_ v: Double) -> String { String(format: v == v.rounded() ? "%.0f" : "%.2f", v) }
        return "native \(f(nativeWidth))x\(f(nativeHeight)) px nativeScale \(String(format: "%.4f", nativeScale)) scale \(f(scale))"
            + " window \(f(windowWidth))x\(f(windowHeight)) safe t\(f(safeTop)) l\(f(safeLeft)) b\(f(safeBottom)) r\(f(safeRight))"
            + " view (\(f(viewX)),\(f(viewY)) \(f(viewWidth))x\(f(viewHeight))) aligned=\(pixelAligned ? 1 : 0)"
            + " drawable \(f(drawableWidth))x\(f(drawableHeight)) bar \(verticalBarEdge)"
            + " occlusion [\(occlusion.joined(separator: "; "))] division [\(division.joined(separator: "; "))]"
    }
}

/// Snapping helpers for whoever lays out the Windows view: a frame on whole panel pixels is shown with no
/// resampling (the drawable is exactly the view's pixels).
enum DisplayGeometry {
    static func snapped(_ v: CGFloat, nativeScale n: CGFloat) -> CGFloat {
        n > 0 ? (v * n).rounded(.down) / n : v
    }

    static func snapped(_ r: CGRect, nativeScale n: CGFloat) -> CGRect {
        guard n > 0 else { return r }
        let x = (r.minX * n).rounded() / n, y = (r.minY * n).rounded() / n
        return CGRect(x: x, y: y, width: snapped(r.maxX - x, nativeScale: n), height: snapped(r.maxY - y, nativeScale: n))
    }
}

@MainActor
final class DisplaySettings: ObservableObject {
    static let shared = DisplaySettings()

    // MARK: the current surface's choices

    @Published private(set) var surface: DisplaySurface = .main
    @Published var displaySize: DisplaySizePreset = .standard {
        didSet { if oldValue != displaySize { store(displaySize.rawValue, "displaySize"); push() } }
    }
    @Published var sharpness: DisplaySharpness = .automatic {
        didSet { if oldValue != sharpness { store(sharpness.rawValue, "sharpness"); push() } }
    }
    /// Frame rate for this surface (30, 60, 120); mirrored into VMViewModel.frameRate.
    @Published var frameRate: Int = 60 {
        didSet {
            guard oldValue != frameRate else { return }
            store(frameRate, "fps")
            WinIOSBridge.shared.setDisplayFrameRate(frameRate)
            if let vm, vm.frameRate != frameRate { vm.frameRate = frameRate }
        }
    }
    /// Immersive full screen: Windows edge to edge, no bars. The session view sets it; remembered per surface.
    @Published var immersive: Bool = false {
        didSet { if oldValue != immersive { store(immersive, "immersive"); push() } }
    }
    /// What immersive does to Windows' size (one setting for every surface).
    @Published var immersiveSizing: ImmersiveSizing = ImmersiveSizing(rawValue: UserDefaults.standard.string(forKey: "winios.display.immersiveSizing") ?? "") ?? .fullPanel {
        didSet {
            UserDefaults.standard.set(immersiveSizing.rawValue, forKey: "winios.display.immersiveSizing")
            push()
        }
    }

    // MARK: state from the bridge

    @Published private(set) var plan = WinIOSDisplayPlan()
    @Published private(set) var applied = WinIOSDisplayApplied()
    @Published private(set) var reshapeState: WinIOSReshapeState = .idle
    @Published private(set) var legacy = false
    /// The last measurements per "surface.orientation", kept across launches so every screen's numbers can be compared.
    @Published private(set) var metrics: [String: DisplayMetrics] = [:]

    private weak var vm: VMViewModel?
    private var cancellables: Set<AnyCancellable> = []
    private var lastLogged: [String: DisplayMetrics] = [:]
    private var applying = false

    private init() {
        migrate()
        if let data = UserDefaults.standard.data(forKey: "winios.display.metrics"),
           let saved = try? JSONDecoder().decode([String: DisplayMetrics].self, from: data) {
            metrics = saved
        }
        load(surface)
        NotificationCenter.default.addObserver(forName: .WinIOSDisplayStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in DisplaySettings.shared.refreshFromBridge() }
        }
    }

    /// Follows the posture and hinge of the session (call once, from VMViewModel's init).
    func attach(to vm: VMViewModel) {
        self.vm = vm
        vm.objectWillChange
            .receive(on: DispatchQueue.main) // after the change is stored
            .sink { [weak self] _ in self?.updateSurface() }
            .store(in: &cancellables)
        updateSurface()
        push()
        refreshFromBridge()
    }

    /// VMViewModel.frameRate was changed (its own picker): this surface keeps it.
    func frameRateDidChange(_ fps: Int) {
        if fps != frameRate { frameRate = fps }
    }

    // MARK: surfaces and persistence (UX 4.10)

    private func key(_ name: String, _ s: DisplaySurface) -> String { "winios.surface.\(s.rawValue).\(name)" }

    private func store(_ value: Any, _ name: String) {
        guard !applying else { return }
        UserDefaults.standard.set(value, forKey: key(name, surface))
    }

    /// Migration: a former "High resolution (HiDPI)" on makes every surface Sharp.
    private func migrate() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "winios.display.migrated") else { return }
        if ud.bool(forKey: "winios.hiDPIDisplay") {
            for s in DisplaySurface.allCases { ud.set(DisplaySharpness.sharp.rawValue, forKey: key("sharpness", s)) }
        }
        ud.set(true, forKey: "winios.display.migrated")
    }

    private func load(_ s: DisplaySurface) {
        let ud = UserDefaults.standard
        applying = true
        defer { applying = false }
        displaySize = DisplaySizePreset(rawValue: ud.object(forKey: key("displaySize", s)) as? Int ?? 1) ?? .standard
        sharpness = DisplaySharpness(rawValue: ud.object(forKey: key("sharpness", s)) as? Int ?? 0) ?? .automatic
        let globalFps = ud.integer(forKey: "winios.fps")
        frameRate = ud.object(forKey: key("fps", s)) as? Int ?? (globalFps > 0 ? globalFps : 60)
        immersive = ud.bool(forKey: key("immersive", s))
    }

    private static var lastScreenShortSide: Double = 0

    private func currentSurface() -> DisplaySurface {
        guard let vm, vm.supportsLaptopPosture else { return .main }
        // The cover: the hinge says closed, or the app is on a narrower panel than the inner one (1812 px short side).
        if vm.hingeStatusRaw == 1 || (Self.lastScreenShortSide > 0 && Self.lastScreenShortSide < 1600) { return .cover }
        if vm.isVMRunning && vm.isLaptopLayoutActive { return .lid }
        return .inner
    }

    /// Surface settings first, then the size request (the bridge waits 300 ms for the size to settle), so a
    /// posture change costs Windows one re-mode.
    private func updateSurface() {
        let s = currentSurface()
        guard s != surface else { return }
        FileHandle.standardError.write(Data("[display] surface \(surface.rawValue) -> \(s.rawValue)\n".utf8))
        surface = s
        load(s)
        push()
        WinIOSBridge.shared.displaySurfaceDidChange()
    }

    private func push() {
        let b = WinIOSBridge.shared
        b.immersiveKeepsResolution = immersiveSizing == .keepSize
        b.displaySizePreset = displaySize.rawValue
        b.displaySharpness = sharpness.rawValue
        b.displayImmersive = immersive
        b.setDisplayFrameRate(frameRate)
        if let vm, vm.frameRate != frameRate { vm.frameRate = frameRate }
        refreshFromBridge()
    }

    func refreshFromBridge() {
        let b = WinIOSBridge.shared
        plan = b.currentDisplayPlan
        applied = b.appliedDisplay
        reshapeState = b.displayReshapeState
        legacy = b.displayLegacy
        if let vm {
            let sharp = legacy ? b.hiDPIDisplay : plan.sharpness == 1
            if vm.hiDPIDisplay != sharp { vm.hiDPIDisplay = sharp }
        }
    }

    // MARK: readouts

    /// The plan another preset / sharpness would give here (for the pickers).
    func plan(for preset: DisplaySizePreset, sharpness s: DisplaySharpness? = nil) -> WinIOSDisplayPlan {
        WinIOSBridge.shared.displayPlan(forPreset: preset.rawValue, sharpness: (s ?? sharpness).rawValue)
    }

    /// Balanced keeps the workspace above the preset's floor here (it is not offered where it does not).
    var balancedAvailable: Bool {
        let p = WinIOSBridge.shared.displayPlan(forPreset: displaySize.rawValue, sharpness: DisplaySharpness.balanced.rawValue)
        return p.modeWidth > 0 && p.sharpness == 2
    }

    /// The scale Windows took when the helper's report is about the current mode, else the one asked for.
    var effectiveScale: (percent: UInt32, confirmed: Bool) {
        if applied.scalePercent > 0 && applied.modeWidth == plan.modeWidth && applied.modeHeight == plan.modeHeight {
            return (applied.scalePercent, true)
        }
        return (plan.scalePercent, false)
    }

    /// "Looks like 1030 × 725 · Windows at 250%", from the scale Windows actually accepted when known.
    var readout: String {
        guard plan.modeWidth > 0 else { return L("Windows 启动后显示", "Shown once Windows runs") }
        if plan.legacy != 0 { return "\(plan.modeWidth) × \(plan.modeHeight)" }
        let (s, confirmed) = effectiveScale
        let w = Int((Double(plan.modeWidth) * 100 / Double(max(s, 1))).rounded())
        let h = Int((Double(plan.modeHeight) * 100 / Double(max(s, 1))).rounded())
        return L("看起来像 \(w) × \(h) · Windows 缩放 \(s)%", "Looks like \(w) × \(h) · Windows at \(s)%")
            + (confirmed ? "" : L("（等待 Windows）", " (waiting for Windows)"))
    }

    static func readout(_ p: WinIOSDisplayPlan) -> String {
        p.modeWidth > 0 ? "\(p.lookWidth) × \(p.lookHeight) · \(p.scalePercent)%" : "-"
    }

    /// The not-ready copy for a reshape (UX 4.11), nil when there is nothing to say.
    var reshapeNotice: String? {
        switch reshapeState {
        case .slow: return L("Windows 正在换成新的大小…", "Windows is taking the new size…")
        case .stuck:
            return L("Windows 没有换成新的大小。你的应用都没事。在 WINKIT 盘上运行 START.bat 安装显卡驱动和小助手。",
                     "Windows didn't change size. Your apps are fine. Run START.bat on the WINKIT drive to install the display driver and helper.")
        default: return nil
        }
    }

    // MARK: measurements (UX P0-1)

    /// Called by the Windows view whenever its geometry is recomputed; stores and logs what changed.
    func record(view: UIView, drawable: CGSize) {
        guard let window = view.window else { return }
        let screen = window.windowScene?.screen ?? UIScreen.main
        var m = DisplayMetrics()
        m.nativeWidth = screen.nativeBounds.width
        m.nativeHeight = screen.nativeBounds.height
        m.nativeScale = screen.nativeScale
        m.scale = screen.scale
        m.windowWidth = window.bounds.width
        m.windowHeight = window.bounds.height
        let safe = window.safeAreaInsets
        m.safeTop = safe.top; m.safeLeft = safe.left; m.safeBottom = safe.bottom; m.safeRight = safe.right
        let f = view.convert(view.bounds, to: window)
        m.viewX = f.minX; m.viewY = f.minY; m.viewWidth = f.width; m.viewHeight = f.height
        m.drawableWidth = drawable.width
        m.drawableHeight = drawable.height
        if #available(iOS 27.1, *) {
            switch window.traitCollection.verticalBarEdge {
            case .leading: m.verticalBarEdge = "leading"
            case .trailing: m.verticalBarEdge = "trailing"
            default: m.verticalBarEdge = "unspecified"
            }
            func describe(_ r: UIView.ReservedRegion) -> String {
                let fr = r.frame, mg = r.margins
                return String(format: "%.0f,%.0f %.0fx%.0f m%.0f/%.0f/%.0f/%.0f%@", fr.minX, fr.minY, fr.width, fr.height,
                              mg.top, mg.left, mg.bottom, mg.right, r.isActive ? "" : " inactive")
            }
            m.occlusion = window.reservedRegions(kind: .occlusion, options: .includeInactive).map(describe)
            m.division = window.reservedRegions(kind: .division, options: .includeInactive).map(describe)
        }
        Self.lastScreenShortSide = min(m.nativeWidth, m.nativeHeight)
        // Published state changes after this layout pass, not during it.
        DispatchQueue.main.async { [weak self] in self?.store(metrics: m) }
    }

    private func store(metrics m: DisplayMetrics) {
        updateSurface()
        let k = "\(surface.rawValue).\(m.orientation)"
        guard lastLogged[k] != m else { return }
        lastLogged[k] = m
        FileHandle.standardError.write(Data("[display] metrics \(k): \(m.logLine)\n".utf8))
        metrics[k] = m
        if let data = try? JSONEncoder().encode(metrics) {
            UserDefaults.standard.set(data, forKey: "winios.display.metrics")
        }
    }

    // MARK: presenter counters (UX P0-3 gate, P1-8)

    struct PresenterRates {
        var fps = 0.0, cpuPercent = 0.0, uploadMBps = 0.0, heldPerSecond = 0.0
        var stats = WinIOSPresenterStats()
    }

    private var lastSample: (time: CFTimeInterval, stats: WinIOSPresenterStats)?

    /// Rates since the previous call (Status polls it once a second while it is shown).
    func samplePresenter() -> PresenterRates {
        let now = CACurrentMediaTime()
        let s = WinIOSBridge.shared.presenterStats()
        var r = PresenterRates(stats: s)
        if let (t, p) = lastSample, now - t > 0.2, s.frames >= p.frames {
            let dt = now - t
            r.fps = Double(s.frames - p.frames) / dt
            r.cpuPercent = Double(s.cpuNanos &- p.cpuNanos) / 1e9 / dt * 100
            r.uploadMBps = Double(s.uploadBytes &- p.uploadBytes) / 1_048_576 / dt
            r.heldPerSecond = Double(s.held &- p.held) / dt
        }
        lastSample = (now, s)
        return r
    }
}

// MARK: - Settings: Display (mounted by the settings sheet)

/// Display Size, Sharpness, frame rate and immersive sizing for the screen the app is on.
struct DisplaySettingsSection: View {
    @ObservedObject var display = DisplaySettings.shared

    var body: some View {
        Section {
            if display.legacy {
                LabeledContent(L("分辨率", "Resolution"), value: display.readout)
            } else {
                Picker(L("显示大小", "Display Size"), selection: $display.displaySize) {
                    ForEach(DisplaySizePreset.allCases, id: \.self) { p in
                        VStack(alignment: .leading) {
                            Text(p.title)
                            Text(DisplaySettings.readout(display.plan(for: p)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(p)
                    }
                }
                .pickerStyle(.navigationLink)
                Text(display.readout)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(display.readout)
                Picker(L("清晰度", "Sharpness"), selection: $display.sharpness) {
                    Text(DisplaySharpness.automatic.title + " (" + (display.plan.sharpness == 2 ? DisplaySharpness.balanced.title : DisplaySharpness.sharp.title) + ")")
                        .tag(DisplaySharpness.automatic)
                    Text(DisplaySharpness.sharp.title).tag(DisplaySharpness.sharp)
                    if display.balancedAvailable || display.sharpness == .balanced {
                        Text(DisplaySharpness.balanced.title).tag(DisplaySharpness.balanced)
                    }
                }
                Picker(L("沉浸全屏时", "In immersive full screen"), selection: $display.immersiveSizing) {
                    ForEach(ImmersiveSizing.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Picker(L("刷新率", "Frame rate"), selection: $display.frameRate) {
                ForEach(VMViewModel.frameRateChoices, id: \.self) { hz in
                    Text(hz >= 120 ? L("流畅（120 Hz）", "Smooth (120 Hz)")
                         : hz >= 60 ? L("标准（60 Hz）", "Standard (60 Hz)") : L("省电（30 Hz）", "Battery (30 Hz)")).tag(hz)
                }
            }
            if let notice = display.reshapeNotice {
                Label(notice, systemImage: display.reshapeState == .stuck ? "exclamationmark.triangle" : "hourglass")
                    .font(.footnote)
                    .foregroundStyle(display.reshapeState == .stuck ? .orange : .secondary)
            }
        } header: {
            Text(L("显示", "Display") + " · " + display.surface.title)
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        if display.legacy {
            return L("正在用旧的分辨率规则（HV_DISPLAY_LEGACY）。", "Using the former sizing (HV_DISPLAY_LEGACY).")
        }
        var lines: [String] = []
        switch display.sharpness == .automatic ? (display.plan.sharpness == 2 ? .balanced : .sharp) : display.sharpness {
        case .balanced:
            lines.append(L("均衡：四分之一的像素，文字稍软，手机更凉。", "Balanced: a quarter of the pixels. Softer text, cooler phone."))
        default:
            lines.append(L("锐利：用满屏幕的每一个像素，更耗电。", "Sharp: every pixel of the screen. Uses more of the phone."))
        }
        if display.applied.method == 2 {
            lines.append(L("Windows 的缩放要注销后才生效。", "Windows' scale applies after you sign out."))
        } else {
            lines.append(L("立即生效。应用不会关闭；少数老应用重新打开前可能有点模糊。",
                           "Changes now. Your apps stay open; a few older ones may look soft until you reopen them."))
        }
        lines.append(L("每块屏幕（内屏、笔记本、外屏）分别记住。", "Remembered for each screen: inner, laptop, cover."))
        lines.append(L("Windows 自身以 60 Hz 绘制；120 Hz 让滚动和指针更跟手。",
                       "Windows draws at 60. Smooth makes scrolling and the pointer feel quicker."))
        return lines.joined(separator: " ")
    }
}

// MARK: - Settings: Status (mounted by the settings sheet)

/// What the display is doing and what it costs: the numbers that decide Sharp vs Balanced (P0-3) and the
/// measurements of every screen (P0-1).
struct DisplayStatusSection: View {
    @ObservedObject var display = DisplaySettings.shared
    @ObservedObject private var device = DeviceStatus.shared
    @State private var rates = DisplaySettings.PresenterRates()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            LabeledContent(L("屏幕", "Surface"), value: display.surface.title)
            LabeledContent(L("请求", "Asked of Windows"), value: asked)
            LabeledContent("Windows", value: windowsNow)
            LabeledContent(L("画面像素", "Pixels"), value: pixels)
            LabeledContent(L("帧率", "Frame rate"), value: frameRateText)
            LabeledContent(L("绘制占用", "Presenter CPU"), value: String(format: "%.1f%% · %.0f MB/s", rates.cpuPercent, rates.uploadMBps))
            LabeledContent(L("改分辨率", "Re-modes"), value: remodes)
            LabeledContent(L("小助手", "Helper"), value: helper)
            if let verdict = gateVerdict {
                Text(verdict).font(.footnote).foregroundStyle(.secondary)
            }
            DisclosureGroup(L("各屏幕的测量值", "Measurements per screen")) {
                if display.metrics.isEmpty {
                    Text(L("还没有测量值", "Nothing measured yet")).foregroundStyle(.secondary)
                }
                ForEach(display.metrics.keys.sorted(), id: \.self) { k in
                    if let m = display.metrics[k] {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k).font(.footnote.bold())
                            Text(m.logLine).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        } header: {
            Text(L("显示状态", "Display status"))
        }
        .onReceive(tick) { _ in
            rates = display.samplePresenter()
            WinIOSBridge.shared.refreshAppliedDisplay()
            display.refreshFromBridge()
        }
        .onAppear { rates = display.samplePresenter() }
    }

    private var asked: String {
        let p = display.plan
        guard p.modeWidth > 0 else { return "-" }
        if p.legacy != 0 { return "\(p.modeWidth) × \(p.modeHeight) (legacy)" }
        let k = p.sharpness == 2 ? DisplaySharpness.balanced.title : DisplaySharpness.sharp.title
        let preset = DisplaySizePreset(rawValue: display.displaySize.rawValue)?.title ?? ""
        return "\(p.modeWidth) × \(p.modeHeight) @ \(p.scalePercent)% · \(k) · \(preset)" + (p.available != 0 ? "" : " ⚠︎")
    }

    private var windowsNow: String {
        // the last frame shown (with 3D the 2D framebuffer size is not Windows' mode)
        let s = rates.stats
        let w = s.srcWidth > 0 ? s.srcWidth : WinIOSBridge.shared.framebufferWidth
        let h = s.srcWidth > 0 ? s.srcHeight : WinIOSBridge.shared.framebufferHeight
        guard w > 0 else { return "-" }
        let a = display.applied
        let scale = a.scalePercent > 0 && a.modeWidth == w && a.modeHeight == h ? " · \(a.scalePercent)%" : ""
        return "\(w) × \(h)\(scale)"
    }

    private var pixels: String {
        let s = rates.stats
        guard s.srcWidth > 0 else { return "-" }
        let scale = Double(s.scaleX100) / 100
        let how = s.nearest != 0
            ? (s.scaleX100 == 100 ? L("1:1 原生像素", "1:1 native pixels") : String(format: L("整数 %.0f×", "exactly %.0f×"), scale))
            : String(format: L("缩放 %.2f×（平滑）", "scaled %.2f× (smoothed)"), scale)
        return "\(s.srcWidth) × \(s.srcHeight) → \(s.dstWidth) × \(s.dstHeight) · \(how)"
    }

    private var frameRateText: String {
        let s = rates.stats
        let link = s.idle != 0 ? L("空闲 \(s.linkHz) Hz", "idle \(s.linkHz) Hz") : "\(s.linkHz) Hz"
        return String(format: "%.0f fps · ", rates.fps) + link + (s.holding != 0 ? L(" · 保持上一帧", " · holding last frame") : "")
    }

    private var remodes: String {
        let b = WinIOSBridge.shared
        let ms = b.lastReshapeMillis
        return "\(b.displayRemodeCount)" + (ms > 0 ? String(format: L(" · 上次 %.0f 毫秒", " · last %.0f ms"), ms) : "")
    }

    private var helper: String {
        let a = display.applied
        switch a.method {
        case 1: return L("实时生效", "Live") + " · \(a.scalePercent)% (\(a.minPercent)–\(a.maxPercent)%, " + L("推荐", "rec.") + " \(a.recommendedPercent)%)"
        case 2: return L("注销后生效", "After sign-out") + " · \(a.scalePercent)%"
        case 3: return L("设置缩放失败", "Could not set the scale")
        default: return L("还没有报告", "No report yet")
        }
    }

    /// P0-3: does Sharp hold up on this screen? Sharp at 2576 × 1812 against Balanced at 1288 × 906.
    private var gateVerdict: String? {
        let s = rates.stats
        guard s.srcWidth > 0, rates.fps > 1 else { return nil }
        let px = Double(s.srcWidth) * Double(s.srcHeight) / 1e6
        let thermal = DeviceStatus.name(device.thermalState)
        return String(format: L("性能：%.1f MP 每帧，%.0f fps，绘制 %.1f%% CPU，温度 %@。", "Performance: %.1f MP a frame, %.0f fps, presenter %.1f%% CPU, thermal %@."),
                      px, rates.fps, rates.cpuPercent, thermal)
    }
}

/// A small chip for the session view while Windows takes a new size (UX 4.11); empty otherwise.
struct DisplayReshapeNotice: View {
    @ObservedObject var display = DisplaySettings.shared

    var body: some View {
        if let notice = display.reshapeNotice {
            Label(notice, systemImage: display.reshapeState == .stuck ? "exclamationmark.triangle" : "hourglass")
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
