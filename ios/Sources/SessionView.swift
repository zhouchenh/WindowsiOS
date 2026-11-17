// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Chinese when the device language is Chinese, English otherwise.
func L(_ zh: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? zh : en
}

/// The whole app: the Windows screen under standard toolbar items (Studio and the cover screen; on
/// the iPhone Duo iOS puts them in its vertical bar beside the status items, elsewhere in a top bar),
/// or on a half-folded foldable the Windows screen above the fold and a keyboard and trackpad below
/// it (Laptop); Immersive hides every bar and gives Windows the whole screen. A launch page while
/// Windows is not running, and a settings sheet.
struct SessionView: View {
    @ObservedObject var vm: VMViewModel
    @ObservedObject private var chrome = ChromeModel.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showPowerConfirm = false
    /// The display's "In immersive full screen": keep Windows' size (the canvas keeps its windowed size,
    /// drawn larger) or give it the whole panel (DisplaySettings.immersiveSizing).
    @State private var immersiveKeepsSize = DisplaySettings.shared.immersiveSizing == .keepSize

    /// Windows is on screen with nothing over it: the chrome's gestures and hooks apply.
    private var sessionActive: Bool { vm.isVMRunning && !vm.showSettings && vm.activeSafariURL == nil }
    private var laptopNow: Bool { vm.isVMRunning && vm.isLaptopLayoutActive }
    /// The toolbar: Studio and the cover screen with the controls shown (Laptop has the deck).
    private var toolbarShown: Bool { vm.isVMRunning && !laptopNow && !chrome.isImmersive }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Invisible: UIHingeInteraction (iOS 27.1) reports the fold; it also hands the window and
            // the vertical bar's edge to the chrome.
            HingeSensorView { statusRaw, angleDeg in
                DispatchQueue.main.async {
                    vm.updateHinge(statusRaw: statusRaw, angleDegrees: angleDeg, viewportSize: vm.viewportSize)
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            NavigationStack {
                stage
                    .sessionToolbar(SessionToolbarItems(
                        vm: vm, chrome: chrome, shown: toolbarShown,
                        compact: horizontalSizeClass == .compact && chrome.verticalBarSide == .none,
                        showPower: { showPowerConfirm = true }))
                    .toolbar(toolbarShown ? .visible : .hidden, for: .navigationBar)
                    .navigationBarTitleDisplayMode(.inline)
                    .modifier(DarkBarBackground())
            }

            if !vm.isVMRunning {
                LaunchPage(vm: vm)
            }
        }
        // Immersive hides the status bar and the home indicator and keeps edge swipes for Windows
        // first; otherwise iOS shows its status (on the Duo in the vertical bar) and only the bottom
        // edge, where the Windows taskbar sits under the home indicator, asks for a second swipe.
        .statusBarHidden(chrome.hidesSystemUI)
        .persistentSystemOverlays(chrome.hidesSystemUI ? .hidden : .automatic)
        .defersSystemGestures(on: chrome.hidesSystemUI ? .all : (vm.isVMRunning ? .bottom : []))
        .onOpenURL { JITSetup.shared.handleOpenURL($0) } // app-jit hook
        .clipboardSync(windows: !vm.isLinux) // clipboard hook
        .onAppear {
            WinIOSBridge.shared.updateScreenSize(UIScreen.main.bounds.size, scale: UIScreen.main.scale)
            chrome.updateSessionActive(sessionActive)
        }
        .onChange(of: sessionActive) { _, active in chrome.updateSessionActive(active) }
        .onReceive(DisplaySettings.shared.$immersiveSizing) { immersiveKeepsSize = $0 == .keepSize }
        .sheet(item: $vm.activeSafariURL) { item in
            SafariSheet(url: item.url).ignoresSafeArea()
        }
        .sheet(isPresented: $vm.showSettings) {
            SettingsSheet(vm: vm)
        }
        .confirmationDialog(L("电源", "Power"), isPresented: $showPowerConfirm, titleVisibility: .visible) {
            Button(L("关机（通知 Windows）", "Shut down (ask Windows)")) { WinIOSBridge.shared.pressPowerButton() }
            Button(L("强制关闭虚拟机", "Force stop the VM"), role: .destructive) {
                WinIOSBridge.shared.flushDisks()
                WinIOSBridge.shared.stopVM()
            }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("强制关闭相当于直接断电，未保存的内容会丢失。",
                   "Force stop is like pulling the plug: unsaved work is lost."))
        }
        .alert(L("Windows 里还没有装小助手", "The helper is not installed in Windows"), isPresented: $vm.guestHelperMissing) {
            Button(L("改用模拟键盘输入", "Type the command instead")) { vm.installClaudeCodeByTyping() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("自动运行脚本需要 WinKit 的后台小助手。在 Windows 里运行一次 WINKIT 盘上的 START.bat（或 cli_setup.ps1）就会装好，之后点这里不用再输入任何命令。刚开机的话请等十几秒再试。",
                   "Running scripts by themselves needs WinKit's background helper. Run START.bat (or cli_setup.ps1) from the WINKIT drive in Windows once; after that nothing has to be typed. Right after Windows starts, wait a few seconds and try again."))
        }
    }

    /// The whole screen in screen coordinates: the Windows screen, the laptop deck and the floating
    /// keyboard button are placed from the bars' safe area. A reader that ignores the safe area
    /// reports no insets, so one reader keeps to the safe area (status bar, toolbar, the vertical bar)
    /// and a second one inside it covers the whole screen; the insets are the difference.
    private var stage: some View {
        GeometryReader { safe in
            let safeFrame = safe.frame(in: .global)
            Color.clear.overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    stageBody(geo: geo, insets: StageLayout.insets(safe: safeFrame, full: geo.frame(in: .global)))
                }
                .ignoresSafeArea()
            }
        }
    }

    private func stageBody(geo: GeometryProxy, insets: EdgeInsets) -> some View {
        let full = geo.size
        let laptop = vm.isVMRunning && vm.isLaptopLayoutActive(for: full)
        let surface = ChromeSurface.of(laptop: laptop, size: full, hingeStatus: vm.hingeStatusRaw,
                                       foldable: vm.supportsLaptopPosture)
        let immersive = vm.isVMRunning && chrome.isImmersive(surface)
        let division = ReservedRegions.division(geo)
        // With the keyboard pan (KeyboardOptions.panInsteadOfShrink) the Windows screen keeps its size under
        // the on-screen keyboard and the picture moves up inside it (MetalCanvasUIView), so nothing is cut
        // off at the keyboard's top and the transparent key bar shows the picture behind it.
        let layout = StageLayout(full: full, insets: insets, laptop: laptop, immersive: immersive,
                                 fold: FoldLayout(full: full, division: division),
                                 keyboardTop: KeyboardOptions.panInsteadOfShrink ? nil : chrome.keyboardTop,
                                 windowedSize: immersiveKeepsSize ? chrome.windowedCanvasSize[surface] : nil,
                                 nativeScale: Self.nativeScale)
        let occlusions = ReservedRegions.occlusions(geo)

        return stageContent(layout: layout, laptop: laptop, occlusions: occlusions)
            .modifier(StageObservers(vm: vm, chrome: chrome, full: full, laptop: laptop, surface: surface,
                                     immersive: immersive, insets: insets, layout: layout, division: division,
                                     occlusions: occlusions))
    }

    /// One Windows screen for every posture (the same view, so Windows keeps its display and the
    /// keyboard focus). Its size is what Windows' resolution follows.
    /// Panel pixels per point of the screen the app is on (the Windows view's frame is snapped to them).
    private static var nativeScale: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.screen.nativeScale ?? 0
    }

    /// Near the top of the Windows screen, below the camera island when it reaches in (as ChromeHintView).
    private static func noticeTop(in area: CGRect, below occlusions: [CGRect]) -> CGFloat {
        var y = area.minY + 14
        let band = CGRect(x: area.minX, y: y, width: area.width, height: 44)
        for r in occlusions where r.intersects(band) { y = max(y, r.maxY + 8) }
        return y
    }

    private func stageContent(layout: StageLayout, laptop: Bool, occlusions: [CGRect]) -> some View {
        let canvas = layout.canvas
        return ZStack(alignment: .topLeading) {
            Color.black

            if laptop {
                LaptopDeckView(vm: vm, showPower: { showPowerConfirm = true })
                    .frame(width: layout.full.width, height: max(0, layout.full.height - layout.fold.deckTop))
                    .offset(y: layout.fold.deckTop)
                    .transition(.opacity)
            }

            MetalDisplayView(
                directTouch: laptop ? .constant(true) : $vm.directTouch, // the deck has the trackpad
                // Laptop forces direct touch: multi-touch only when Settings says Multi-touch (a saved
                // multi-touch flag under Trackpad must not turn on there)
                multiTouch: laptop ? vm.touchMode == .multiTouch : vm.multiTouch,
                keyboardVisible: laptop ? .constant(false) : $vm.systemKeyboardVisible,
                hardwareKeyboard: vm.hardwareKeyboard,
                focusAllowed: vm.isVMRunning && !vm.showSettings && vm.activeSafariURL == nil,
                onThreeFingerTap: {
                    // the alias of the four-finger tap: controls in or out
                    withAnimation(.snappy(duration: 0.22)) { chrome.toggleImmersive(reason: "three-finger tap") }
                },
                rightClickArmed: $vm.rightClickArmed,
                keyboardResizesView: !laptop
            )
            .frame(width: canvas.frame.width, height: canvas.frame.height)
            .scaleEffect(canvas.scale, anchor: .topLeading)
            .offset(x: canvas.origin.x, y: canvas.origin.y)
            .opacity(vm.isVMRunning ? 1 : 0)

            if vm.isVMRunning && !laptop && chrome.keyboardButtonShown && !vm.hardwareKeyboard && !vm.systemKeyboardVisible {
                KeyboardFloatingButton(chrome: chrome, area: canvas.visibleRect, occlusions: occlusions,
                                       framebuffer: CGSize(width: CGFloat(vm.fbWidth), height: CGFloat(vm.fbHeight)),
                                       reservesTaskbar: !vm.isLinux) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    vm.systemKeyboardVisible = true
                }
                .transition(.opacity)
            }

            if vm.isVMRunning, let hint = chrome.hint {
                ChromeHintView(text: hint, area: canvas.visibleRect, occlusions: occlusions)
            }

            if vm.isVMRunning {
                // "Windows is taking the new size" while a re-mode is slow or stuck (DisplaySettings.swift).
                DisplayReshapeNotice()
                    .frame(width: canvas.visibleRect.width)
                    .offset(x: canvas.visibleRect.minX,
                            y: Self.noticeTop(in: canvas.visibleRect, below: occlusions) + (chrome.hint != nil ? 48 : 0))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: layout.full.width, height: layout.full.height, alignment: .topLeading)
    }
}

/// Where the Windows screen goes, in screen coordinates.
struct StageLayout: Equatable {
    struct Canvas: Equatable {
        /// The view's own size (what Windows' resolution follows).
        var frame: CGSize
        /// Drawn larger than its size: immersive that keeps Windows' resolution.
        var scale: CGFloat
        var origin: CGPoint
        var visibleRect: CGRect { CGRect(origin: origin, size: CGSize(width: frame.width * scale, height: frame.height * scale)) }
    }

    /// The safe area's insets inside the whole screen (both frames in global coordinates).
    static func insets(safe: CGRect, full: CGRect) -> EdgeInsets {
        EdgeInsets(top: max(0, safe.minY - full.minY), leading: max(0, safe.minX - full.minX),
                   bottom: max(0, full.maxY - safe.maxY), trailing: max(0, full.maxX - safe.maxX))
    }

    let full: CGSize
    let fold: FoldLayout
    let canvas: Canvas
    /// The Windows screen with the controls shown (what immersive without a new resolution keeps).
    let windowed: CGSize

    init(full: CGSize, insets: EdgeInsets, laptop: Bool, immersive: Bool, fold: FoldLayout,
         keyboardTop: CGFloat?, windowedSize: CGSize?, nativeScale: CGFloat = 0) {
        self.full = full
        self.fold = fold
        // The bars' safe area: status bar and toolbar on top, the vertical bar or the camera at the
        // sides. The bottom (home indicator) stays Windows': its taskbar sits there, as on a tablet.
        let top = insets.top, lead = insets.leading, trail = insets.trailing
        let windowedRect: CGRect
        let immersiveRect: CGRect
        if laptop {
            // The lid: everything above the fold (P0-8: no bezel, no chin).
            windowedRect = CGRect(x: lead, y: top, width: full.width - lead - trail, height: fold.lidBottom - top)
            immersiveRect = CGRect(x: 0, y: 0, width: full.width, height: fold.lidBottom)
        } else {
            // While the on-screen keyboard is up, the Windows screen ends above it (as before).
            let bottom = min(full.height, keyboardTop ?? full.height)
            windowedRect = CGRect(x: lead, y: top, width: full.width - lead - trail, height: bottom - top)
            immersiveRect = CGRect(x: 0, y: 0, width: full.width, height: bottom)
        }
        windowed = CGSize(width: max(1, windowedRect.width), height: max(1, windowedRect.height))
        let r = immersive ? immersiveRect : windowedRect
        let area = CGRect(x: r.minX, y: r.minY, width: max(1, r.width), height: max(1, r.height))
        // On whole panel pixels (DisplayGeometry): the drawable is then exactly the view's pixels and the
        // compositor shows it with no resampling.
        let n = nativeScale
        if immersive, let keep = windowedSize, keep.width > 1, keep.height > 1 {
            // Windows keeps the size it had with the controls, drawn as large as fits.
            let s = min(area.width / keep.width, area.height / keep.height)
            let origin = CGPoint(x: area.minX + (area.width - keep.width * s) / 2,
                                 y: area.minY + (area.height - keep.height * s) / 2)
            canvas = Canvas(frame: keep, scale: s,
                            origin: n > 0 ? CGPoint(x: (origin.x * n).rounded() / n, y: (origin.y * n).rounded() / n) : origin)
        } else {
            let r = DisplayGeometry.snapped(area, nativeScale: n)
            canvas = Canvas(frame: CGSize(width: max(1, r.width), height: max(1, r.height)), scale: 1, origin: r.origin)
        }
    }
}

/// Keeps the view model and the chrome up to date with the layout, and logs what the system reports.
private struct StageObservers: ViewModifier {
    let vm: VMViewModel
    let chrome: ChromeModel
    let full: CGSize
    let laptop: Bool
    let surface: ChromeSurface
    /// Immersive is on screen: the display's reshape filter is told (DisplaySettings.immersive).
    let immersive: Bool
    let insets: EdgeInsets
    let layout: StageLayout
    let division: CGRect?
    let occlusions: [CGRect]

    func body(content: Content) -> some View {
        content
            .onAppear {
                vm.viewportSize = full
                chrome.setSurface(surface)
                chrome.reportInsets(insets)
                chrome.reportScreen(viewport: full)
                chrome.reportOcclusions(occlusions)
                rememberWindowed()
                DisplaySettings.shared.immersive = immersive
            }
            .onChange(of: immersive) { _, on in DisplaySettings.shared.immersive = on }
            // The display remembers immersive per screen and loads its own on a screen change: the
            // chrome's is what is on screen.
            .onReceive(DisplaySettings.shared.$surface.dropFirst()) { _ in
                DispatchQueue.main.async { DisplaySettings.shared.immersive = immersive }
            }
            .onChange(of: full) { _, newSize in
                vm.viewportSize = newSize
                chrome.reportScreen(viewport: newSize)
            }
            .onChange(of: surface) { _, s in chrome.setSurface(s) }
            .onChange(of: insets) { _, i in chrome.reportInsets(i) }
            .onChange(of: occlusions) { _, o in chrome.reportOcclusions(o) }
            .onChange(of: layout) { _, _ in rememberWindowed() }
            .onChange(of: laptop) { _, on in
                if on {
                    vm.systemKeyboardVisible = false // the deck is the keyboard
                    chrome.reportFold(source: layout.fold.sourceText, rect: division)
                } else {
                    vm.rightClickArmed = false
                }
            }
            .onChange(of: layout.fold) { _, f in
                if laptop { chrome.reportFold(source: f.sourceText, rect: division) }
            }
    }

    /// Immersive without a new resolution keeps the size the Windows screen has with the controls.
    private func rememberWindowed() {
        guard vm.isVMRunning, !chrome.isImmersive(surface),
              chrome.keyboardTop == nil || laptop || KeyboardOptions.panInsteadOfShrink else { return }
        chrome.rememberWindowedCanvas(layout.windowed, for: surface)
    }
}

/// Before Liquid Glass (iOS 26) the bar gets a black background; from iOS 26 the glass items float
/// over the black stage on their own.
private struct DarkBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            content
                .toolbarBackground(Color.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

// MARK: - Machine list (left column)

/// A machine's icon: a rounded tile in its colour with its mark (Arch: the Arch Linux logo).
struct MachineIcon: View {
    let id: String
    let symbol: String
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(id == "Arch" ? Color(red: 0.09, green: 0.58, blue: 0.82).gradient : Color.blue.gradient)
            .frame(width: size, height: size)
            .overlay {
                if id == "Arch" {
                    ArchLogoShape().fill(.white, style: FillStyle(eoFill: true)).padding(size * 0.18)
                } else {
                    Image(systemName: symbol).font(.system(size: size * 0.48)).foregroundStyle(.white)
                }
            }
    }
}

/// The Arch Linux logo mark (from archlinux.org/art, archlinux-logo-white-scalable.svg; Arch Linux
/// trademark policy applies), drawn as a shape: fill it with any colour, at any size, keeping its proportions.
struct ArchLogoShape: Shape {
    static let aspect: CGFloat = 0.99981 // width / height

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width / 166.156, rect.height / 166.188)
        let ox = rect.midX - 166.156 * s / 2, oy = rect.midY - 166.188 * s / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + (x - 22.750) * s, y: oy + (y - 16.625) * s) }
        var path = Path()
        path.move(to: p(105.812, 16.625))
        path.addCurve(to: p(85.719, 64.219), control1: p(98.416, 34.760), control2: p(93.954, 46.623))
        path.addCurve(to: p(107.031, 82.844), control1: p(90.768, 69.571), control2: p(96.966, 75.804))
        path.addCurve(to: p(83.312, 69.281), control1: p(96.210, 78.391), control2: p(88.829, 73.920))
        path.addCurve(to: p(22.750, 182.812), control1: p(72.773, 91.274), control2: p(56.260, 122.602))
        path.addCurve(to: p(88.531, 154.656), control1: p(49.088, 167.607), control2: p(69.504, 158.233))
        path.addCurve(to: p(87.281, 143.375), control1: p(87.714, 151.142), control2: p(87.250, 147.341))
        path.addLine(to: p(87.312, 142.531))
        path.addCurve(to: p(106.906, 113.562), control1: p(87.730, 125.657), control2: p(96.508, 112.681))
        path.addCurve(to: p(124.969, 145.719), control1: p(117.304, 114.444), control2: p(125.387, 128.845))
        path.addCurve(to: p(123.906, 154.781), control1: p(124.890, 148.894), control2: p(124.532, 151.948))
        path.addCurve(to: p(188.906, 182.812), control1: p(142.727, 158.463), control2: p(162.925, 167.813))
        path.addCurve(to: p(174.844, 156.781), control1: p(183.783, 173.381), control2: p(179.211, 164.879))
        path.addCurve(to: p(146.156, 137.000), control1: p(167.965, 151.450), control2: p(160.791, 144.511))
        path.addCurve(to: p(169.031, 146.000), control1: p(156.215, 139.614), control2: p(163.417, 142.629))
        path.addCurve(to: p(105.812, 16.625), control1: p(124.633, 63.338), control2: p(121.038, 52.354))
        path.closeSubpath()
        return path
    }
}


private struct MachineSidebar: View {
    @ObservedObject var vm: VMViewModel

    var body: some View {
        List(selection: Binding<String?>(
            get: { vm.machine },
            set: { if let m = $0, !vm.isUnpacking, vm.importStatus == nil, !vm.isVMRunning { vm.machine = m } }
        )) {
            Section(L("虚拟机", "Virtual machines")) {
                ForEach(VMViewModel.machines) { m in
                    HStack(spacing: 12) {
                        MachineIcon(id: m.id, symbol: m.symbol, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.headline)
                            Text(vm.machineSubtitle(m.id)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(m.id)
                }
            }
        }
        .navigationTitle("Apple VM")
    }
}

// MARK: - Launch page (Windows not running)

private struct LaunchPage: View {
    @ObservedObject var vm: VMViewModel

    @State private var showImporter = false
    @State private var pendingImport: [URL] = []
    @State private var confirmReplace = false
    @State private var confirmDelete = false
    @State private var deleteError: String? = nil

    private var ready: Bool { vm.isJITLive && vm.hasMachineFiles && !vm.isUnpacking && vm.importStatus == nil }

    var body: some View {
        // Like UTM: the machines on the left, the chosen one on the right (on a phone: the list, then the machine).
        NavigationSplitView {
            MachineSidebar(vm: vm)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var detail: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    MachineIcon(id: vm.machine, symbol: vm.isLinux ? "terminal.fill" : "square.grid.2x2.fill", size: 72)
                    Text(vm.machineTitle)
                        .font(.largeTitle.weight(.semibold))
                    Text(vm.vmStatusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 0) {
                    checkRow(
                        ok: vm.isJITLive,
                        title: "JIT",
                        detail: vm.isJITLive
                            ? L("已开启", "Enabled")
                            : L("请开启 JIT（StikDebug 或内置）", "Please enable JIT (StikDebug or built-in)") // builtin-jit hook
                    ) {
                        if !vm.isJITLive {
                            JITEnableButton() // builtin-jit hook: StikDebug or the built-in helper
                                .buttonStyle(.bordered)
                            JITPanel() // app-jit hook
                        }
                    }
                    Divider().padding(.leading, 52)
                    checkRow(
                        ok: vm.hasMachineFiles,
                        title: L("系统文件", "System files"),
                        detail: vm.hasMachineFiles
                            ? L("已就绪", "Ready")
                            : vm.isLinux
                            ? L("点“安装镜像”，选好系统盘大小，App 会从 Arch Linux ARM 官方源下载系统，并自动装好 KDE Plasma 桌面和 GPU 驱动（OpenGL：virgl，Vulkan：Venus）。需要 JIT 和网络，下载约 2.3 GB。",
                                "Tap Install, pick the system disk size, and the app downloads the system from the official Arch Linux ARM servers and sets up the KDE Plasma desktop with the GPU drivers (OpenGL: virgl, Vulkan: Venus). Needs JIT and a network; about 2.3 GB is downloaded.")
                            : L("需要以下文件，点“导入镜像”一次全部选中：\n• code.fd（UEFI 固件）\n• vars.fd（固件设置）\n• windows11.hvsparse 或 windows11.img（系统盘）\n驱动和修复脚本（WINKIT 盘）App 已自带，不用导入。",
                                "These files are needed; tap Import and select them all at once:\n• code.fd (UEFI firmware)\n• vars.fd (firmware settings)\n• windows11.hvsparse or windows11.img (system disk)\nThe drivers and setup scripts (the WINKIT drive) come with the app.")
                    ) {
                        if vm.isLinux {
                            // Arch is installed by the app itself, not imported
                            if !vm.hasMachineFiles && vm.archInstallStatus == nil {
                                Menu {
                                    ForEach(VMViewModel.archInstallSizes, id: \.self) { gb in
                                        Button(L("系统盘 ", "System disk ") + "\(gb) GB" + (gb == 32 ? L("（推荐）", " (recommended)") : "")) {
                                            vm.installArch(sizeGB: gb)
                                        }
                                    }
                                } label: {
                                    Label(L("安装镜像", "Install"), systemImage: "arrow.down.circle")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!vm.isJITLive || vm.isVMRunning)
                            }
                            if let err = vm.archInstallError {
                                Text(err).font(.footnote).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if let status = vm.importStatus {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                            }
                        } else if !vm.isUnpacking && !vm.hasMachineFiles { // once ready, nothing more to import
                            Button(L("导入镜像", "Import image"), systemImage: "square.and.arrow.down") { showImporter = true }
                                .buttonStyle(.bordered)
                        }
                        if let err = vm.importError {
                            Text(err).font(.footnote).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if vm.isLinux && vm.archInstallStatus != nil {
                        Divider().padding(.leading, 52)
                        ArchInstallRow(vm: vm)
                    }
                    if vm.isUnpacking {
                        Divider().padding(.leading, 52)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("正在解包 Windows 磁盘…", "Unpacking the Windows disk…"))
                                .font(.subheadline.weight(.medium))
                            ProgressView(value: vm.unpackProgress)
                            Text("\(Int(vm.unpackProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    vm.startOrRetry()
                } label: {
                    Text(L("启动 ", "Start ") + vm.machineTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!ready)

                Text(vm.jitStatusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

                if vm.hasAnyMachineFiles {
                    Button(L("删除", "Delete"), systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.bordered)
                        .disabled(vm.isVMRunning || vm.isUnpacking || vm.importStatus != nil)
                    if let deleteError {
                        Text(deleteError).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            // centred on the screen; scrolls only when it does not fit (small phones, landscape)
            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
        }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(vm.machineTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("设置", "Settings"), systemImage: "gearshape") { vm.showSettings = true }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let replacesDisk = urls.contains { VMViewModel.importTarget(for: $0).map(VMViewModel.isDiskTarget) ?? false }
            if replacesDisk && vm.hasWindowsDisk {
                pendingImport = urls
                confirmReplace = true
            } else {
                vm.importFiles(urls)
            }
        }
        .confirmationDialog(L("删除 \(vm.machineTitle)？", "Delete \(vm.machineTitle)?"),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("删除", "Delete"), role: .destructive) { deleteError = vm.deleteMachine() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("系统盘、固件和设置都会被删除（约 ", "The system disk, firmware and settings are deleted (about ")
                 + ByteCountFormatter.string(fromByteCount: Int64(vm.machineFilesBytes), countStyle: .file)
                 + L("），里面的所有数据都无法恢复。", "). Everything in it is lost and cannot be recovered."))
        }
        .confirmationDialog(L("替换现有的 Windows 磁盘？", "Replace the current Windows disk?"),
                            isPresented: $confirmReplace, titleVisibility: .visible) {
            Button(L("替换", "Replace"), role: .destructive) { vm.importFiles(pendingImport); pendingImport = [] }
            Button(L("取消", "Cancel"), role: .cancel) { pendingImport = [] }
        } message: {
            Text(L("现在这个 Windows 里的所有数据会被删除，无法恢复。", "Everything in the current Windows will be deleted. This cannot be undone."))
        }
    }

    private func checkRow<Trailing: View>(ok: Bool, title: String, detail: String,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(ok ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                trailing()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// MARK: - Settings

/// The settings' pages: a sidebar beside the page on wide screens (the Duo's inner screen, iPad), a
/// list that opens each page on narrow ones, like the system's Settings app.
private enum SettingsPage: String, CaseIterable, Identifiable {
    case display, input, network, system, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: return L("显示", "Display")
        case .input: return L("输入", "Input")
        case .network: return L("网络", "Network")
        case .system: return L("系统", "System")
        case .status: return L("状态", "Status")
        }
    }

    var icon: String {
        switch self {
        case .display: return "display"
        case .input: return "hand.point.up.left"
        case .network: return "network"
        case .system: return "gearshape"
        case .status: return "info.circle"
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var vm: VMViewModel
    @ObservedObject private var chrome = ChromeModel.shared
    @ObservedObject private var display = DisplaySettings.shared
    @AppStorage("winios.keyboard.autoShow") private var keyboardAutoShow = true
    @AppStorage("winios.keyboard.follow") private var keyboardFollow = true
    @AppStorage("winios.battery") private var batteryPassthrough = true // read by the bridge at start
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var page: SettingsPage? = nil
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(SettingsPage.allCases, selection: $page) { p in
                NavigationLink(value: p) {
                    Label(p.title, systemImage: p.icon)
                }
            }
            .navigationTitle(L("设置", "Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成", "Done")) {
                        vm.saveCPUName()
                        dismiss()
                    }
                }
            }
        } detail: {
            NavigationStack {
                pageView(page ?? .display)
                    .navigationTitle((page ?? .display).title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .id(page) // another page starts at its top, not inside the last one's Advanced
        }
        .navigationSplitViewStyle(.balanced)
        // DisplaySettingsSection and PortForwardingSection may read the model from the environment.
        .environmentObject(vm)
        .onAppear {
            // Wide: open on the first page beside the sidebar. Narrow: start at the list.
            if page == nil && horizontalSizeClass == .regular { page = .display }
        }
        .onDisappear { vm.saveCPUName() }
        .modifier(PageSizedSheet())
    }

    @ViewBuilder
    private func pageView(_ p: SettingsPage) -> some View {
        switch p {
        case .display: displayPage
        case .input: inputPage
        case .network: networkPage
        case .system: systemPage
        case .status: statusPage
        }
    }

    // MARK: Display

    private var displayPage: some View {
        Form {
            DisplaySettingsSection() // display size, sharpness: DisplaySettings.swift

            Section {
                if vm.isLinux {
                    LabeledContent("OpenGL", value: "virgl")
                    LabeledContent("Vulkan", value: "Venus")
                } else {
                    Toggle(L("3D 加速（DirectX 11）", "3D acceleration (DirectX 11)"), isOn: Binding(
                        get: { vm.gpu3DEnabled },
                        set: { vm.setGPU3D($0) }
                    ))
                }
                // Frame rate and Sharpness (the former HiDPI switch) are per screen in the Display section
                // above; the switch stays only for the former sizing, which has no Sharpness.
                if display.legacy {
                    Toggle(L("高分辨率（HiDPI）", "High resolution (HiDPI)"), isOn: Binding(
                        get: { vm.hiDPIDisplay },
                        set: { _ in vm.toggleHiDPIDisplay() }
                    ))
                }
            } header: {
                Text(L("图形", "Graphics"))
            } footer: {
                Text(vm.isLinux
                     ? L("Arch Linux 的 GPU 加速始终开启：OpenGL 走 virgl，Vulkan 走 Venus（驱动随系统装好）。高分辨率在下次启动时生效。",
                         "GPU acceleration is always on for Arch Linux: OpenGL through virgl, Vulkan through Venus (the drivers come with the system). High resolution applies at the next start.")
                     : L("3D 需要先在 Windows 里装好 3D 驱动（运行 WINKIT 盘里的 START.bat）。如果开启后黑屏，在这里关掉再重启 App。在下次启动 Windows 时生效。",
                         "3D needs the 3D driver installed in Windows first (run START.bat on the WINKIT disk). If the screen stays black after turning it on, turn it off here and restart the app. Applies the next time Windows starts."))
            }

            Section {
                ForEach(chromeSurfaces, id: \.self) { s in
                    Toggle(s.title, isOn: Binding(
                        get: { chrome.isImmersive(s) },
                        set: { on in chrome.setImmersive(on, for: s, reason: "Settings") }
                    ))
                }
            } header: {
                Text(L("沉浸全屏", "Immersive"))
            } footer: {
                Text(L("沉浸全屏时没有工具栏、状态栏和侧边栏，Windows 铺满屏幕。四指轻点（或三指轻点），或从左右边缘向内轻扫，控制按钮就回来。每种姿态分别记住。上面“沉浸全屏时”选改成整块屏幕：最清晰，切换时 Windows 改一次分辨率；选保持分辨率：放大显示，不闪。",
                       "Immersive hides the toolbar, the status bar and the side bar: Windows fills the screen. Tap with four fingers (or three), or swipe in from the left or right edge, to bring the controls back. Remembered for each posture. \"In immersive full screen\" above: the whole panel is sharpest, Windows changes resolution once; keeping the resolution draws Windows larger, with no flash."))
            }
        }
    }

    /// Immersive is remembered per surface: the cover and Laptop only on a foldable.
    private var chromeSurfaces: [ChromeSurface] {
        vm.supportsLaptopPosture ? [.studio, .laptop, .cover] : [.studio]
    }

    // MARK: Input

    private var inputPage: some View {
        Form {
            Section {
                Picker(L("触摸屏幕时", "Touching the screen"), selection: $vm.touchMode) {
                    Text(L("触控板", "Trackpad")).tag(TouchMode.trackpad)
                    Text(L("直接触摸", "Direct touch")).tag(TouchMode.direct)
                    Text(L("多点触控", "Multi-touch")).tag(TouchMode.multiTouch)
                }
                .pickerStyle(.segmented)
                if vm.touchMode == .multiTouch && vm.isVMRunning && !vm.usbTouchReady {
                    Label(L("Windows 的触摸屏还没就绪：先按直接触摸工作", "Windows' touch screen is not ready yet: works as Direct touch for now"),
                          systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("触控", "Touch"))
            } footer: {
                switch vm.touchMode {
                case .multiTouch:
                    Text(L("手指直接作为触摸交给 Windows（Windows 自带的触摸屏驱动，无需安装）：轻点、长按 = 右键、双指缩放、拖动滚动、Windows 的边缘和多指手势都由 Windows 处理。四指轻点 = 显示/隐藏控制按钮；沉浸全屏时从左右边缘向内轻扫也是。画面放大时三指拖动画面、三指轻点显示控制按钮。Windows 刚启动、还没认出触摸屏时，按直接触摸工作。",
                           "Your fingers go to Windows as touches (Windows' own touch screen driver, nothing to install): Windows handles taps, press and hold = right click, pinch, drag to scroll, and its edge and multi-finger gestures. Four-finger tap = show or hide the controls; in immersive, so does a swipe in from the left or right edge. While the picture is zoomed, three fingers drag it and a three-finger tap shows the controls. Until Windows has started its touch screen (while it starts up), it works as Direct touch."))
                case .direct:
                    Text(L("轻点 = 在手指位置左键 · 双指轻点或长按 = 右键 · 单指拖动 = 拖拽 · 双指滑动 = 滚动 · 四指（或三指）轻点 = 显示/隐藏控制按钮",
                           "Tap = left click where you touch · Two-finger tap or long press = right click · Drag = drag · Two-finger slide = scroll · Four-finger (or three-finger) tap = show or hide the controls"))
                case .trackpad:
                    Text(L("单指滑动 = 移动光标 · 单指轻点 = 左键 · 双指轻点 = 右键 · 双指滑动 = 滚动 · 轻点后立刻按住拖动（或长按后拖动）= 拖拽 · 四指（或三指）轻点 = 显示/隐藏控制按钮",
                           "Slide = move pointer · Tap = left click · Two-finger tap = right click · Two-finger slide = scroll · Tap then hold and move (or long press, then move) = drag · Four-finger (or three-finger) tap = show or hide the controls"))
                }
            }

            Section {
                Toggle(L("悬浮键盘按钮", "Floating keyboard button"), isOn: $chrome.keyboardButtonShown.animation(.snappy(duration: 0.2)))
                if chrome.keyboardButtonShown {
                    Picker(L("键盘按钮位置", "Keyboard button position"), selection: $chrome.keyboardButtonOnLeft) {
                        Text(L("右下角", "Bottom right")).tag(false)
                        Text(L("左下角", "Bottom left")).tag(true)
                    }
                }
                Toggle(L("在文本框里自动弹出键盘", "Keyboard comes up in text boxes"), isOn: $keyboardAutoShow)
                Toggle(L("画面跟随光标", "Follow the cursor"), isOn: $keyboardFollow)
                LabeledContent(L("外接键盘", "Hardware keyboard"),
                               value: vm.hardwareKeyboard ? L("已连接", "Connected") : L("未连接", "Not connected"))
            } header: {
                Text(L("键盘", "Keyboard"))
            } footer: {
                Text(L("也可以直接把键盘按钮拖到另一侧，长按它可以隐藏。隐藏后用控制栏里的“键盘”（沉浸全屏时四指或三指轻点显示控制栏）。连着外接键盘时不显示。自动弹出和跟随光标需要 WinKit 的焦点助手（运行 WINKIT 盘里的 START.bat）：Windows 里的文本框得到焦点时弹出 iPhone 键盘；键盘挡住光标时画面上移，不再缩小。",
                       "You can also drag the keyboard button to the other side, or long-press it to hide it. Without it, use Keyboard in the controls (in immersive full screen a four-finger or three-finger tap shows them). Hidden while a hardware keyboard is attached. Coming up by itself and following the cursor need WinKit's focus agent (run START.bat from the WINKIT drive): the iPhone keyboard comes up when a text box in Windows gets the focus, and the picture moves up instead of shrinking when the keyboard would cover the cursor."))
            }

            if !vm.isLinux { ClipboardSettingsSection() } // clipboard hook

            if vm.supportsLaptopPosture {
                Section {
                    Picker(L("姿态", "Posture"), selection: Binding(
                        get: { vm.postureMode },
                        set: { vm.setPostureMode($0, viewportSize: vm.viewportSize) }
                    )) {
                        ForEach(PostureMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    Text(L("折叠屏", "Foldable"))
                } footer: {
                    Text(L("笔记本：半折时折痕以上是 Windows，以下是键盘和触控板（上面直接触摸；“更多”里可以让下一次轻点变成右键，F12 回到全屏）。全屏：Windows 占满整个屏幕。自动：按折叠角度切换，没有角度读数时，竖着拿展开的内屏就是笔记本。Windows 的分辨率跟着画面大小变（需要 WinKit 的显卡驱动）。",
                           "Laptop: half folded, Windows is above the fold and a keyboard and trackpad below it (touch Windows directly; More can make the next tap a right click, F12 goes back to Studio). Studio: Windows fills the screen. Automatic follows the hinge; without a hinge reading, the unfolded inner screen held upright is Laptop. Windows' resolution follows the screen's shape (with the WinKit display driver)."))
                }
            }
        }
    }

    // MARK: Network

    private var networkPage: some View {
        Form {
            PortForwardingSection() // forwarded ports: PortForwarding.swift
        }
    }

    // MARK: System

    private var systemPage: some View {
        Form {
            Section {
                if !vm.isLinux {
                    HStack {
                        Text(L("CPU 名称", "CPU name"))
                        TextField(L("自动", "Automatic"), text: $vm.cpuName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .onSubmit { vm.saveCPUName() }
                    }
                }
                Toggle(L("JIT 就绪后自动启动 ", "Start ") + vm.machineTitle + L("", " automatically once JIT is on"), isOn: $vm.autoStart)
                if !vm.isLinux {
                    Toggle(L("Windows 里的登录链接用 Safari 打开", "Open sign-in links from Windows in Safari"), isOn: Binding(
                        get: { vm.useSafariForOAuth },
                        set: { _ in vm.toggleOAuthBrowserMode() }
                    ))
                }
            } footer: {
                if !vm.isLinux {
                    Text(L("CPU 名称是 Windows 里显示的处理器名字，下次启动生效。留空时用设备的芯片名（例如 Apple A20 Pro），不认识的设备显示 Apple Silicon。",
                           "The CPU name is what Windows shows for the processor; applies at the next start. Left empty, it is the device's chip (e.g. Apple A20 Pro), or Apple Silicon on a device the app does not know."))
                }
            }

            if !vm.isLinux {
                Section {
                    Toggle(L("在 Windows 里显示 iPhone 电池", "Show the iPhone battery in Windows"), isOn: $batteryPassthrough)
                } header: {
                    Text(L("电池", "Battery"))
                } footer: {
                    Text(L("Windows 看到 iPhone 的电量和是否在充电：插着电源时是“已接通电源”，拔掉后是“使用电池”。下次启动 Windows 时生效。为免 Windows 在电量低时自己调暗屏幕、睡眠、休眠或关机，在 Windows 里运行一次 WINKIT 盘上的 POWER.bat（START.bat 也会运行它）。",
                           "Windows sees the iPhone's charge and whether it is charging: plugged in, Windows is on AC power; unplugged, it is on battery. Applies the next time Windows starts. So that Windows never dims, sleeps, hibernates or shuts down by itself on a low battery, run POWER.bat from the WINKIT drive once in Windows (START.bat runs it too)."))
                }
            }

            Section {
                NavigationLink(L("高级设置", "Advanced")) { AdvancedSettings(vm: vm) }
            }
        }
    }

    // MARK: Status

    private var statusPage: some View {
        Form {
            Section {
                LabeledContent(L("虚拟机", "Machine"), value: vm.vmStatusText)
                LabeledContent("JIT", value: vm.isJITLive ? L("已开启", "On") : L("未开启", "Off"))
                ThermalStateRow() // app-jit hook
                LabeledContent(L("画面", "Screen"),
                               value: vm.fbWidth > 0 ? "\(vm.fbWidth) × \(vm.fbHeight)" : "-")
                LabeledContent(L("显卡", "Graphics"), value: vm.gpuStatusSummary)
                LabeledContent(L("外接键盘", "Hardware keyboard"),
                               value: vm.hardwareKeyboard ? L("已连接", "Connected") : L("未连接", "Not connected"))
                if vm.supportsLaptopPosture {
                    LabeledContent(L("铰链", "Hinge"), value: hingeText)
                }
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    LabeledContent(L("键盘", "Keyboard"), value: KeyboardDiagnostics.shared.statusLine)
                }
            }

            DisplayStatusSection() // what the display does and costs: DisplaySettings.swift

            // What iOS reported for the chrome, to check the layout on a device (also in winvm.log, "chrome:").
            Section {
                LabeledContent(L("当前屏幕", "Surface"), value: chrome.surface.title
                               + (chrome.isImmersive ? L("（沉浸）", " (immersive)") : ""))
                LabeledContent(L("显示区域", "Display area"), value: chrome.screenSummary)
                LabeledContent(L("安全区 上/前/下/后", "Safe area T/L/B/T"), value: chrome.safeAreaSummary)
                LabeledContent(L("竖栏", "Vertical bar"), value: chrome.verticalBarSide.title)
                LabeledContent(L("竖栏行为", "Vertical bar behaviour"), value: chrome.verticalBarPath)
                LabeledContent(L("折痕", "Fold"), value: chrome.foldSource)
                LabeledContent(L("遮挡区域", "Occluded regions"), value: chrome.occlusionSummary)
            } header: {
                Text(L("布局", "Layout"))
            }
        }
    }

    /// The hinge as UIHingeInteraction last reported it.
    private var hingeText: String {
        guard let deg = vm.hingeAngleDegrees else { return L("没有读数", "No reading") }
        let status: String
        switch vm.hingeStatusRaw {
        case 1: status = L("合上", "closed")
        case 2: status = L("半开", "partly open")
        case 3: status = L("展开", "open")
        default: status = L("未知", "unknown")
        }
        return String(format: "%.0f° · ", deg) + status
    }
}

/// iOS 18 and later: the settings sheet is page sized, wide enough for the sidebar where there is room.
private struct PageSizedSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}

/// Arch Linux without an image to import: the app installs it (download, desktop, GPU drivers), and shows how far it is.
private struct ArchInstallRow: View {
    @ObservedObject var vm: VMViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = vm.archInstallStatus {
                Text(L("正在安装 Arch Linux", "Installing Arch Linux")).font(.subheadline.weight(.medium))
                if status.hasPrefix("error") {
                    Text(status).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView(value: vm.archInstallPercent ?? 0)
                    Text(vm.archInstallMessage).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("全部自动完成，期间虚拟机会重启一次。可以随时打开虚拟机画面查看。总共下载约 2.3 GB。",
                       "Runs by itself; the machine restarts once on the way. Open the machine's screen any time to watch. About 2.3 GB is downloaded."))
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

/// The machine's system disk: its size, and growing it.
private struct DiskSizeSection: View {
    @ObservedObject var vm: VMViewModel
    @State private var pending: Int? = nil
    @State private var message: String? = nil

    var body: some View {
        Section {
            if let bytes = vm.diskSizeBytes {
                let gb = Double(bytes) / Double(1 << 30)
                LabeledContent(L("系统盘容量", "System disk"), value: String(format: "%.0f GB", gb))
                Menu {
                    ForEach(VMViewModel.diskSizeChoices.filter { Double($0) > gb + 0.5 }, id: \.self) { size in
                        Button("\(size) GB") { pending = size }
                    }
                } label: {
                    Text(L("扩容…", "Make it bigger…"))
                }
                .disabled(vm.isVMRunning)
            } else {
                LabeledContent(L("系统盘容量", "System disk"), value: L("无", "None"))
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        } footer: {
            Text(vm.isLinux
                 ? L("只能扩大。新增空间在写入前不占用设备存储。Arch 下次开机时会自动把根分区扩展到整个磁盘。虚拟机运行时不能改。",
                     "Can only grow. The new space takes no room on the device until it is written to. Arch grows its root partition to fill the disk by itself at the next boot. Not while the virtual machine runs.")
                 : L("只能扩大。新增空间在写入前不占用设备存储。扩容后在 Windows 的“磁盘管理”里对 C 盘选“扩展卷”（C 盘后面若有恢复分区，需先删掉它）。虚拟机运行时不能改。",
                     "Can only grow. The new space takes no room on the device until it is written to. Afterwards extend C: in Windows Disk Management (Extend Volume; a recovery partition right after C: has to go first). Not while the virtual machine runs."))
        }
        .confirmationDialog(L("把系统盘扩到 \(pending ?? 0) GB？", "Grow the system disk to \(pending ?? 0) GB?"),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button(L("扩容", "Grow")) {
                if let size = pending { message = vm.growDisk(toGB: size) ?? L("已扩到 \(size) GB。", "Now \(size) GB.") }
                pending = nil
            }
            Button(L("取消", "Cancel"), role: .cancel) { pending = nil }
        } message: {
            Text(L("扩容后不能再缩小。", "It cannot be made smaller again."))
        }
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var vm: VMViewModel

    var body: some View {
        Form {
            Section {
                Picker(L("内存", "Memory"), selection: $vm.ramLimitMB) {
                    Text(L("自动", "Automatic")).tag(0)
                    ForEach(VMViewModel.ramChoices, id: \.self) { mb in
                        Text("\(mb / 1024) GB").tag(mb)
                    }
                }
            } footer: {
                Text(L("给虚拟机的内存上限（Windows 和 Arch Linux 共用）。“自动”会用设备能给的最大值（最多 16 GB，并给系统留出约 2.5 GB）。设备给不了所选大小时会自动降一档。",
                       "The most memory the virtual machine gets (shared by Windows and Arch Linux). Automatic uses as much as the device allows (up to 16 GB, leaving about 2.5 GB for iOS). If the device cannot give the chosen size, the next smaller one is used."))
            }

            DiskSizeSection(vm: vm)

            Section {
                Picker(L("JIT 缓存", "JIT cache"), selection: $vm.jitCacheMB) {
                    ForEach(VMViewModel.jitCacheChoices, id: \.self) { mb in
                        Text(mb == 256 ? "256 MB (" + L("默认", "default") + ")" : "\(mb) MB").tag(mb == 256 ? 0 : mb)
                    }
                }
            } footer: {
                Text(L("翻译后代码的缓存。实测 256 MB 最顺：缓存更大时清空次数少，但系统改写代码时的停顿更长（768 MB 约 0.15 秒，256 MB 约 0.03 秒），开 JIT 也更慢。改动在下次启动 App 后生效。",
                       "Cache for translated code. 256 MB measured smoothest: a bigger cache is flushed less often, but the pause when the system rewrites code gets longer (about 0.15 s at 768 MB, 0.03 s at 256 MB) and enabling JIT takes longer. Takes effect the next time the app starts."))
            }

            Section {
                LabeledContent(L("当前", "Now"), value: vm.jitStatusText)
            } footer: {
                Text(L("这两项在开启 JIT 时就定下来了：修改后要完全关闭 App 再重新打开才生效。",
                       "Both are fixed when JIT is enabled: after a change, close the app completely and open it again."))
            }
        }
        .navigationTitle(L("高级设置", "Advanced"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
