// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Chinese when the device language is Chinese, English otherwise.
func L(_ zh: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? zh : en
}

/// Where the laptop posture puts things: the top half of the screen is the lid (a thin bezel around
/// the Windows screen), the bottom half the keyboard and trackpad deck. The halves meet at the hinge.
private struct LaptopMetrics {
    static let chinHeight: CGFloat = 15
    static let sideBezel: CGFloat = 6

    let lidHeight: CGFloat
    let deckHeight: CGFloat
    let cameraBezel: CGFloat
    /// The Windows screen inside the lid, in screen coordinates.
    let screen: CGRect

    init(full: CGSize, safeTop: CGFloat) {
        lidHeight = (full.height * 0.5).rounded(.down)
        deckHeight = max(0, full.height - lidHeight)
        cameraBezel = max(safeTop > 20 ? safeTop - 8 : 9, 9)
        screen = CGRect(x: Self.sideBezel, y: cameraBezel,
                        width: max(1, full.width - Self.sideBezel * 2),
                        height: max(1, lidHeight - cameraBezel - Self.chinHeight))
    }
}

/// The whole app: the Windows screen with one small floating toolbar (Studio), or on a half-folded
/// foldable the Windows screen on the top half and a keyboard and trackpad on the bottom half (Laptop);
/// a launch page while Windows is not running, and a settings sheet.
struct SessionView: View {
    @ObservedObject var vm: VMViewModel
    @State private var showPowerConfirm = false
    /// When the toolbar last appeared (it does not hide itself in its first moment).
    @State private var controlBarShownAt = Date()

    var body: some View {
        GeometryReader { geo in
            // The whole screen, whatever the safe areas (and the on-screen keyboard) leave.
            let full = CGSize(width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                              height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            let laptop = vm.isVMRunning && vm.isLaptopLayoutActive(for: full)
            session(full: full, laptop: laptop, lid: LaptopMetrics(full: full, safeTop: geo.safeAreaInsets.top))
                .onAppear { vm.viewportSize = full }
                .onChange(of: full) { _, newSize in vm.viewportSize = newSize }
                .onChange(of: laptop) { _, on in
                    if on {
                        vm.systemKeyboardVisible = false // the deck is the keyboard
                    } else {
                        vm.rightClickArmed = false
                    }
                }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onOpenURL { JITSetup.shared.handleOpenURL($0) } // app-jit hook
        .onAppear {
            WinIOSBridge.shared.updateScreenSize(UIScreen.main.bounds.size, scale: UIScreen.main.scale)
        }
        .onChange(of: vm.controlBarVisible) { _, visible in
            if visible { controlBarShownAt = Date() }
        }
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

    /// One Windows screen for both postures (the same view, so Windows keeps its display and the
    /// keyboard focus): full screen under the toolbar, or the lid's screen above the deck. Its size
    /// is what Windows' resolution follows, so in Laptop Windows gets the lid's shape.
    private func session(full: CGSize, laptop: Bool, lid: LaptopMetrics) -> some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            // Invisible: UIHingeInteraction (iOS 27.1) reports the fold.
            HingeSensorView { statusRaw, angleDeg in
                DispatchQueue.main.async {
                    vm.updateHinge(statusRaw: statusRaw, angleDegrees: angleDeg, viewportSize: vm.viewportSize)
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            if laptop {
                VStack(spacing: 0) {
                    laptopLid(width: full.width, lid: lid)
                        .frame(width: full.width, height: lid.lidHeight)
                    LaptopDeckView(vm: vm)
                        .frame(width: full.width, height: lid.deckHeight)
                }
                .frame(width: full.width, height: full.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
                .transition(.opacity)
            }

            MetalDisplayView(
                directTouch: laptop ? .constant(true) : $vm.directTouch, // the deck has the trackpad
                keyboardVisible: laptop ? .constant(false) : $vm.systemKeyboardVisible,
                hardwareKeyboard: vm.hardwareKeyboard,
                focusAllowed: vm.isVMRunning && !vm.showSettings && vm.activeSafariURL == nil,
                onThreeFingerTap: {
                    if laptop {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            vm.setPostureMode(.fullScreen, viewportSize: full)
                        }
                    } else {
                        withAnimation(.snappy(duration: 0.2)) { vm.controlBarVisible.toggle() }
                    }
                },
                rightClickArmed: $vm.rightClickArmed,
                keyboardResizesView: !laptop,
                onUserInteraction: {
                    guard !laptop, vm.autoHideControlBar, vm.controlBarVisible,
                          Date().timeIntervalSince(controlBarShownAt) > 1.0 else { return }
                    withAnimation(.snappy(duration: 0.2)) { vm.controlBarVisible = false }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: laptop ? 5.5 : 0, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: laptop ? 5.5 : 0, style: .continuous)
                    .strokeBorder(Color.white.opacity(laptop ? 0.07 : 0), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .frame(width: laptop ? lid.screen.width : nil, height: laptop ? lid.screen.height : nil)
            .padding(.leading, laptop ? lid.screen.minX : 0)
            .padding(.top, laptop ? lid.screen.minY : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(laptop ? .all : .container, edges: laptop ? .all : [.bottom, .horizontal])
            .opacity(vm.isVMRunning ? 1 : 0)

            if vm.isVMRunning {
                if !laptop {
                    toolbar
                        .padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            } else {
                LaunchPage(vm: vm)
            }
        }
    }

    // MARK: - Laptop lid

    /// The lid around the Windows screen (which is drawn on top of it): a camera bezel, and a chin
    /// with the sign-in browser switch and the posture switch.
    private func laptopLid(width: CGFloat, lid: LaptopMetrics) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.038, green: 0.046, blue: 0.072),
                                              Color(red: 0.020, green: 0.024, blue: 0.038)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Color(red: 0.64, green: 0.75, blue: 0.96).opacity(0.28),
                                                              Color(red: 0.45, green: 0.56, blue: 0.78).opacity(0.10),
                                                              Color.black.opacity(0.60)],
                                                     startPoint: .top, endPoint: .bottom),
                                      lineWidth: 0.85)
                )

            VStack(spacing: 0) {
                // Camera bezel: the camera, and a status light (orange without JIT)
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 0.10, green: 0.12, blue: 0.18)).frame(width: 3.5, height: 3.5)
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.05, green: 0.07, blue: 0.12))
                            .frame(width: 5.5, height: 5.5)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.4))
                        Circle()
                            .fill(Color(red: 0.45, green: 0.65, blue: 1.0).opacity(0.55))
                            .frame(width: 1.6, height: 1.6)
                            .offset(x: -0.8, y: -0.8)
                    }
                    Circle()
                        .fill(vm.isJITLive ? Color.white.opacity(0.32) : Color.orange.opacity(0.6))
                        .frame(width: 2.4, height: 2.4)
                }
                .frame(height: lid.cameraBezel)

                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(Color.black)
                    .padding(.horizontal, LaptopMetrics.sideBezel)
                    .frame(height: lid.screen.height)

                ZStack {
                    HStack(spacing: 5) {
                        WindowsLogoMark(size: 7.5, color: Color.white.opacity(0.22))
                        Text("SURFACE")
                            .font(.system(size: 7.5, weight: .semibold))
                            .tracking(2.2)
                            .foregroundStyle(Color.white.opacity(0.22))
                    }
                    HStack {
                        if !vm.isLinux {
                            chinButton(vm.useSafariForOAuth ? "OAUTH: SAFARI" : "OAUTH: EDGE",
                                       accessibility: vm.useSafariForOAuth
                                           ? L("登录链接用 Safari 打开", "Sign-in links open in Safari")
                                           : L("登录链接用 Edge 打开", "Sign-in links open in Edge")) {
                                vm.toggleOAuthBrowserMode()
                            }
                        }
                        Spacer()
                        chinButton(vm.hingeAngleDegrees.map { String(format: "%.0f°", $0) } ?? vm.postureMode.rawValue.uppercased(),
                                   accessibility: L("姿态：", "Posture: ") + vm.postureMode.title) {
                            vm.cyclePostureMode(viewportSize: vm.viewportSize)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: LaptopMetrics.chinHeight)
            }
        }
        .frame(width: width)
    }

    private func chinButton(_ text: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 8.0, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.28))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    // MARK: - Floating toolbar (Studio)

    @ViewBuilder
    private var toolbar: some View {
        if vm.controlBarVisible {
            // On a narrow screen the row scrolls instead of being cut off.
            ViewThatFits(in: .horizontal) {
                toolbarRow
                ScrollView(.horizontal, showsIndicators: false) {
                    toolbarRow.padding(.horizontal, 8).padding(.vertical, 12)
                }
                .padding(.vertical, -12)
            }
        } else {
            // A small handle so the toolbar can always be brought back (a three-finger tap does it too).
            Button {
                withAnimation(.snappy(duration: 0.2)) { vm.controlBarVisible = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 18)
                    .background(.ultraThinMaterial, in: Capsule())
                    .contentShape(Rectangle().inset(by: -10))
            }
            .accessibilityLabel(L("显示工具栏", "Show toolbar"))
            .opacity(0.7)
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 2) {
            if vm.supportsLaptopPosture { // a foldable: Laptop or Studio
                Menu {
                    Picker(L("姿态", "Posture"), selection: Binding(
                        get: { vm.postureMode },
                        set: { mode in
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                vm.setPostureMode(mode, viewportSize: vm.viewportSize)
                            }
                        }
                    )) {
                        ForEach(PostureMode.allCases, id: \.self) { mode in
                            Label(mode.title, systemImage: mode.iconName).tag(mode)
                        }
                    }
                } label: {
                    barIcon("laptopcomputer", active: false)
                }
                .accessibilityLabel(L("姿态", "Posture"))
            }
            if !vm.hardwareKeyboard { // with a hardware keyboard attached there is nothing to bring up
                barButton(vm.systemKeyboardVisible ? "keyboard.fill" : "keyboard", L("键盘", "Keyboard"),
                          active: vm.systemKeyboardVisible) {
                    vm.systemKeyboardVisible.toggle()
                }
            }
            barButton(vm.directTouch ? "hand.point.up.left.fill" : "rectangle.and.hand.point.up.left",
                      vm.directTouch ? L("直接触摸", "Direct touch") : L("触控板", "Trackpad"),
                      active: vm.directTouch) {
                vm.directTouch.toggle()
            }
            barButton("square.grid.2x2.fill", L("Win 键", "Windows key")) {
                WinIOSBridge.shared.sendWindowsKey()
            }
            if !vm.isLinux { // these run inside Windows
                Menu {
                    Button("Claude Code", systemImage: "terminal") { vm.installClaudeCode() }
                    Button("Paint", systemImage: "paintbrush.pointed") { vm.launchGuestPaint() }
                    Button("Edge", systemImage: "globe") { vm.launchGuestEdgeBrowser() }
                } label: {
                    barIcon("sparkles", active: false)
                }
                .accessibilityLabel(L("应用", "Apps"))
                barButton(vm.useSafariForOAuth ? "safari" : "network",
                          vm.useSafariForOAuth ? L("登录链接用 Safari 打开", "Sign-in links open in Safari")
                                               : L("登录链接用 Edge 打开", "Sign-in links open in Edge"),
                          active: vm.useSafariForOAuth) {
                    vm.toggleOAuthBrowserMode()
                }
            }
            Menu {
                Section(L("快捷键", "Shortcuts")) {
                    Button("Ctrl + Alt + Del", systemImage: "lock") { WinIOSBridge.shared.sendCtrlAltDel() }
                    Button(L("任务管理器", "Task Manager"), systemImage: "waveform.path.ecg") { vm.sendTaskManager() }
                    Button("Alt + Tab", systemImage: "rectangle.on.rectangle") { WinIOSBridge.shared.sendAltTab() }
                    Button("Esc", systemImage: "escape") { WinIOSBridge.shared.sendEscape() }
                }
                Section {
                    Button(L("设置", "Settings"), systemImage: "gearshape") { vm.showSettings = true }
                    Button(L("电源…", "Power…"), systemImage: "power") { showPowerConfirm = true }
                }
            } label: {
                barIcon("ellipsis.circle", active: false)
            }
            .accessibilityLabel(L("更多", "More"))
            Divider().frame(height: 20).padding(.horizontal, 2)
            barButton("chevron.up", L("收起工具栏", "Hide toolbar")) {
                withAnimation(.snappy(duration: 0.2)) { vm.controlBarVisible = false }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
    }

    private func barIcon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(active ? Color.accentColor : .white)
            .frame(width: 42, height: 36)
            .contentShape(Rectangle())
    }

    private func barButton(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            barIcon(symbol, active: active)
        }
        .accessibilityLabel(label)
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

private struct SettingsSheet: View {
    @ObservedObject var vm: VMViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
                    Picker(L("刷新率", "Refresh rate"), selection: $vm.frameRate) {
                        ForEach(VMViewModel.frameRateChoices, id: \.self) { hz in
                            Text("\(hz) Hz").tag(hz)
                        }
                    }
                    Toggle(L("高分辨率（HiDPI）", "High resolution (HiDPI)"), isOn: Binding(
                        get: { vm.hiDPIDisplay },
                        set: { _ in vm.toggleHiDPIDisplay() }
                    ))
                } header: {
                    Text(L("显示", "Display"))
                } footer: {
                    Text(vm.isLinux
                         ? L("Arch Linux 的 GPU 加速始终开启：OpenGL 走 virgl，Vulkan 走 Venus（驱动随系统装好）。高分辨率在下次启动时生效。刷新率是全局设置，虚拟机下次启动时生效。",
                             "GPU acceleration is always on for Arch Linux: OpenGL through virgl, Vulkan through Venus (the drivers come with the system). High resolution applies at the next start. The refresh rate is global and applies when the machine next starts.")
                         : L("3D 需要先在 Windows 里装好 3D 驱动（运行 WINKIT 盘里的 START.bat）。如果开启后黑屏，在这里关掉再重启 App。这两项在下次启动 Windows 时生效。刷新率只影响 iPad 上的画面刷新：Windows 的显卡驱动只支持 60 Hz，Windows 里始终是 60 Hz。",
                             "3D needs the 3D driver installed in Windows first (run START.bat on the WINKIT disk). If the screen stays black after turning it on, turn it off here and restart the app. Both apply the next time Windows starts. The refresh rate only changes how often the iPad draws the screen: the Windows display driver only takes 60 Hz, so Windows itself stays at 60 Hz."))
                }

                Section {
                    Picker(L("触摸屏幕时", "Touching the screen"), selection: $vm.directTouch) {
                        Text(L("触控板", "Trackpad")).tag(false)
                        Text(L("直接触摸", "Direct touch")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle(L("使用 Windows 时自动收起工具栏", "Hide the toolbar while using Windows"), isOn: $vm.autoHideControlBar)
                } header: {
                    Text(L("触控", "Touch"))
                } footer: {
                    Text(vm.directTouch
                        ? L("轻点 = 在手指位置左键 · 双指轻点或长按 = 右键 · 单指拖动 = 拖拽 · 双指滑动 = 滚动 · 三指轻点 = 显示/隐藏工具栏",
                            "Tap = left click where you touch · Two-finger tap or long press = right click · Drag = drag · Two-finger slide = scroll · Three-finger tap = toolbar")
                        : L("单指滑动 = 移动光标 · 单指轻点 = 左键 · 双指轻点 = 右键 · 双指滑动 = 滚动 · 轻点后立刻按住拖动（或长按后拖动）= 拖拽 · 三指轻点 = 显示/隐藏工具栏",
                            "Slide = move pointer · Tap = left click · Two-finger tap = right click · Two-finger slide = scroll · Tap then hold and move (or long press, then move) = drag · Three-finger tap = toolbar"))
                }

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
                        Text(L("笔记本：半折时上半屏是 Windows，下半屏是键盘和触控板（上半屏直接触摸；F8 让下一次轻点变成右键，F12 或三指轻点回到全屏）。全屏：Windows 占满整个屏幕。自动：按折叠角度切换，没有角度读数时，竖着拿展开的内屏就是笔记本。Windows 的分辨率跟着画面大小变（需要 WinKit 的显卡驱动）。",
                               "Laptop: half folded, Windows is on the top half and a keyboard and trackpad on the bottom half (touch the top half directly; F8 makes the next tap a right click, F12 or a three-finger tap goes back to Studio). Studio: Windows fills the screen. Automatic follows the hinge; without a hinge reading, the unfolded inner screen held upright is Laptop. Windows' resolution follows the screen's shape (with the WinKit display driver)."))
                    }
                }

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
                } header: {
                    Text(L("系统", "System"))
                } footer: {
                    if !vm.isLinux {
                        Text(L("CPU 名称是 Windows 里显示的处理器名字，下次启动生效。留空时用设备的芯片名（例如 Apple A20 Pro），不认识的设备显示 Apple Silicon。",
                               "The CPU name is what Windows shows for the processor; applies at the next start. Left empty, it is the device's chip (e.g. Apple A20 Pro), or Apple Silicon on a device the app does not know."))
                    }
                }

                Section {
                    NavigationLink(L("高级设置", "Advanced")) { AdvancedSettings(vm: vm) }
                }

                Section(L("状态", "Status")) {
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
                }
            }
            .navigationTitle(vm.machineTitle + L(" 设置", " Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成", "Done")) {
                        vm.saveCPUName()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { vm.saveCPUName() }
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
