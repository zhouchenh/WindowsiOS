// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import SafariServices
import GameController
import SwiftUI
import UIKit

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredBarTintColor = UIColor(red: 0.045, green: 0.058, blue: 0.096, alpha: 1.0)
        vc.preferredControlTintColor = UIColor(red: 0.82, green: 0.90, blue: 1.0, alpha: 1.0)
        vc.dismissButtonStyle = .done
        return vc
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

enum PostureMode: String, CaseIterable {
    case auto = "Auto"
    case laptop = "Laptop"
    case fullScreen = "Studio"

    var iconName: String {
        switch self {
        case .auto: return "sparkles"
        case .laptop: return "laptopcomputer"
        case .fullScreen: return "ipad.landscape"
        }
    }

    /// What the posture menus show.
    var title: String {
        switch self {
        case .auto: return L("自动（按折叠角度）", "Automatic (follow the hinge)")
        case .laptop: return L("笔记本", "Laptop")
        case .fullScreen: return L("全屏", "Studio")
        }
    }
}

enum DeckLayout: String, CaseIterable {
    case split = "Split"
    case trackpad = "Trackpad"
    case keyboard = "Keyboard"

    var iconName: String {
        switch self {
        case .split: return "laptopcomputer"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .keyboard: return "keyboard"
        }
    }

    var next: DeckLayout {
        switch self {
        case .split: return .trackpad
        case .trackpad: return .keyboard
        case .keyboard: return .split
        }
    }
}

@MainActor
final class VMViewModel: ObservableObject {
    @Published var isJITLive: Bool = false
    @Published var isDebuggerAttached: Bool = false
    @Published var isVMRunning: Bool = false
    @Published var isUnpacking: Bool = false
    @Published var unpackProgress: Double = 0
    @Published var jitStatusText: String = "Checking JIT..."
    @Published var vmStatusText: String = "Initializing..."
    @Published var fbWidth: UInt32 = 0
    @Published var fbHeight: UInt32 = 0
    @Published var presentedFrames: UInt64 = 0
    @Published var availableMemoryMB: UInt64 = 0

    @Published var usbKeyboardReady: Bool = false
    @Published var usbTabletReady: Bool = false
    @Published var usbEventsDelivered: UInt64 = 0

    // iOS 27.1 UIHinge state (0 = unknown, 1 = closed, 2 = partiallyOpen, 3 = fullyOpen)
    @Published var hingeStatusRaw: Int = 0
    @Published var hingeAngleDegrees: Double? = nil
    /// UIHingeInteraction has reported a hinge on this device at least once.
    @Published var hingeAvailable: Bool = false

    /// Laptop (folded: Windows on the top half, keyboard and trackpad on the bottom half) or Studio
    /// (Windows on the whole screen); Auto follows the hinge. Only foldable devices have a choice.
    @Published var postureMode: PostureMode = PostureMode(rawValue: UserDefaults.standard.string(forKey: "winios.posture") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(postureMode.rawValue, forKey: "winios.posture") }
    }
    @Published var deckLayout: DeckLayout = .split
    // chrome (feat/chrome): the session controls are standard toolbar items now, shown or hidden by
    // immersive mode per surface (ChromeModel in SessionChrome.swift), so controlBarVisible and
    // autoHideControlBar (winios.autoHideBar) are gone.
    @Published var trackpadMode: Bool = false
    @Published var rightClickArmed: Bool = false
    @Published var systemKeyboardVisible: Bool = false
    @Published var activeSafariURL: IdentifiableURL? = nil
    @Published var useSafariForOAuth: Bool = WinIOSBridge.shared.useSafariForGuestLinks
    /// Sharp (true) or Balanced on the current screen; kept in step by DisplaySettings.
    @Published var hiDPIDisplay: Bool = WinIOSBridge.shared.hiDPIDisplay
    /// Display Size, Sharpness, frame rate and immersive sizing per screen (DisplaySettings.swift). The session
    /// view sets display.immersive while Windows is shown edge to edge.
    let display = DisplaySettings.shared

    // MARK: Settings shown in the app
    /// false: the screen works like a trackpad. true: taps land where the finger is.
    @Published var directTouch: Bool = UserDefaults.standard.bool(forKey: "winios.directTouch") {
        didSet { UserDefaults.standard.set(directTouch, forKey: "winios.directTouch") }
    }
    @Published var showSettings: Bool = false
    /// Advanced: JIT code cache in MiB (0 = default, the largest) and the most guest RAM in MiB (0 = automatic).
    /// Both are fixed when JIT is acquired, so a change applies after the app is closed and opened again.
    /// Refresh rate of the machine's screen (all machines): 30, 60 (default) or 120 where the screen can.
    @Published var frameRate: Int = { let v = UserDefaults.standard.integer(forKey: "winios.fps"); return v > 0 ? v : 60 }() {
        didSet {
            UserDefaults.standard.set(frameRate, forKey: "winios.fps")
            WinIOSBridge.shared.setDisplayFrameRate(frameRate)
            DisplaySettings.shared.frameRateDidChange(frameRate) // remembered for the current screen
        }
    }
    static var frameRateChoices: [Int] { [30, 60, 120].filter { $0 <= UIScreen.main.maximumFramesPerSecond } }

    @Published var jitCacheMB: Int = UserDefaults.standard.integer(forKey: "winios.jitMB") {
        didSet { UserDefaults.standard.set(jitCacheMB, forKey: "winios.jitMB") }
    }
    @Published var ramLimitMB: Int = UserDefaults.standard.integer(forKey: "winios.ramMB") {
        didSet { UserDefaults.standard.set(ramLimitMB, forKey: "winios.ramMB") }
    }
    static let jitCacheChoices = [256, 384, 512, 640, 768]
    static let ramChoices = [2048, 3072, 4096, 6144, 8192, 10240, 12288, 14336, 16384]
    /// Start Windows as soon as JIT is on. Off by default: the app stays on its start page first, so
    /// settings can be changed before Windows boots.
    /// Command line only: Windows closes its desktop shell after logon and shows a console
    /// (needs the WinKit hook inside Windows); the on-screen keyboard opens by itself.
    /// The machine the launch page starts: "Win11" or "Arch" (Arch Linux ARM). Each has its own folder.
    @Published var machine: String = UserDefaults.standard.string(forKey: "winios.machine") ?? "Win11" {
        didSet { UserDefaults.standard.set(machine, forKey: "winios.machine") }
    }
    var isLinux: Bool { machine == "Arch" }
    var machineTitle: String { isLinux ? "Arch Linux" : "Windows 11" }

    @Published var autoStart: Bool = UserDefaults.standard.bool(forKey: "winios.autoStart") {
        didSet { UserDefaults.standard.set(autoStart, forKey: "winios.autoStart") }
    }
    /// A hardware keyboard is attached (Magic Keyboard, Bluetooth or USB).
    @Published var hardwareKeyboard: Bool = GCKeyboard.coalesced != nil
    private var keyboardObservers: [NSObjectProtocol] = []

    private func watchHardwareKeyboard() {
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, Notification.Name.GCKeyboardDidDisconnect] {
            keyboardObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.hardwareKeyboard = GCKeyboard.coalesced != nil
                    if self.hardwareKeyboard { self.systemKeyboardVisible = false } // typing goes straight through now
                }
            })
        }
    }
    @Published var gpu3DEnabled: Bool = VMViewModel.readGPU3DSwitch()
    @Published var cpuName: String = VMViewModel.readTextFile("cpu_name.txt")

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func readTextFile(_ name: String) -> String {
        let t = try? String(contentsOf: documentsURL.appendingPathComponent(name), encoding: .utf8)
        return (t ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Host 3D is on when Documents/gpu3d.on or Documents/Shared/gpu3d.on exists and does not say "off".
    static func readGPU3DSwitch() -> Bool {
        for name in ["gpu3d.on", "Shared/gpu3d.on"] {
            let url = documentsURL.appendingPathComponent(name)
            guard let t = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let v = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !v.hasPrefix("off") && !v.hasPrefix("0") { return true }
        }
        return false
    }

    /// Takes effect the next time Windows starts.
    func setGPU3D(_ on: Bool) {
        let docs = VMViewModel.documentsURL
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("Shared"), withIntermediateDirectories: true)
        try? (on ? "on" : "off").write(to: docs.appendingPathComponent("gpu3d.on"), atomically: true, encoding: .utf8)
        // the copy Windows can write: only ever turn it off from here, so "off" really is off
        let shared = docs.appendingPathComponent("Shared/gpu3d.on")
        if !on && FileManager.default.fileExists(atPath: shared.path) {
            try? "off".write(to: shared, atomically: true, encoding: .utf8)
        }
        gpu3DEnabled = on
    }

    func saveCPUName() {
        let name = cpuName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = VMViewModel.documentsURL.appendingPathComponent("cpu_name.txt")
        if name.isEmpty { try? FileManager.default.removeItem(at: url) }
        else { try? name.write(to: url, atomically: true, encoding: .utf8) }
    }

    var hasMachineFiles: Bool { WinIOSBridge.shared.hasProvisionedMachine() }

    // MARK: One-tap Claude Code

    /// Installs Claude Code inside Windows: publishes the installer in the shared folder
    /// (http://10.0.2.4/ai.ps1) and types the one line that runs it — into the Run box on the desktop,
    /// or straight into the console in command-line-only mode. The installer asks in Windows which API
    /// to use (Anthropic, DeepSeek or any Anthropic-compatible address) and for the key; the app never sees it.
    /// True when the toolbar asked for something the in-Windows helper is not there to do.
    @Published var guestHelperMissing: Bool = false

    private static let claudeInstallLine = "powershell -ep bypass -noexit -c \"irm http://10.0.2.4/ai.ps1 | iex; ai\""

    /// The WinKit helper inside Windows (cli_setup.ps1) reports in every few seconds.
    private var guestHelperAlive: Bool {
        let f = VMViewModel.documentsURL.appendingPathComponent("Shared/agent_alive.txt")
        guard let d = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(d) < 40
    }

    private func publishClaudeInstaller() {
        let shared = VMViewModel.documentsURL.appendingPathComponent("Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try? VMViewModel.claudeInstallerScript.replacingOccurrences(of: "\n", with: "\r\n")
            .write(to: shared.appendingPathComponent("ai.ps1"), atomically: true, encoding: .ascii)
    }

    /// Toolbar > Claude Code: the helper inside Windows opens the installer in its own console window.
    /// Nothing is typed into Windows. Without the helper the user is told how to get it.
    func installClaudeCode() {
        guard isVMRunning else { return }
        guard guestHelperAlive else { guestHelperMissing = true; return }
        publishClaudeInstaller()
        let job = UUID().uuidString + "\r\n" + VMViewModel.claudeInstallLine + "\r\n"
        try? job.write(to: VMViewModel.documentsURL.appendingPathComponent("Shared/agent_job.txt"), atomically: true, encoding: .ascii)
        if !hardwareKeyboard && !isLaptopLayoutActive { systemKeyboardVisible = true } // the API key is typed by hand
    }

    /// The fallback the user can choose when the helper is missing: the command typed by simulated keystrokes.
    func installClaudeCodeByTyping() {
        guard isVMRunning else { return }
        publishClaudeInstaller()
        try? ("!" + VMViewModel.claudeInstallLine)
            .write(to: VMViewModel.documentsURL.appendingPathComponent("type.request"), atomically: true, encoding: .utf8)
        if !hardwareKeyboard && !isLaptopLayoutActive { systemKeyboardVisible = true }
    }

    static let claudeInstallerScript = #"""
# WindowsiOS: installs Claude Code and sets the API it talks to.  Run:  ai      (again any time to change the API or key)
function ai {
    $ErrorActionPreference = 'Continue'
    function Say($t, $c = 'Cyan') { Write-Host ''; Write-Host $t -ForegroundColor $c }
    function AskKey($what) {
        $s = Read-Host "  Type or paste your $what, then Enter (Enter alone = keep what is saved)" -AsSecureString
        $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
    }
    $exe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    Say '=== Claude Code ===' 'Green'

    Say '[1/2] Install'
    if (Test-Path $exe) { Write-Host '  already installed' }
    else {
        Write-Host '  downloading from claude.ai (a few minutes: please wait)...'
        try { Invoke-Expression (Invoke-RestMethod 'https://claude.ai/install.ps1') } catch { Write-Host "  $_" -ForegroundColor Red }
        if (-not (Test-Path $exe)) { Write-Host '  the installer did not finish: check the network and tap the button again.' -ForegroundColor Red; return }
    }
    # "claude" from a folder every console already searches (a PATH change does not survive the app being swiped away)
    $apps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (Test-Path $apps) { ('@"%USERPROFILE%\.local\bin\claude.exe" %*') | Out-File -Encoding ascii (Join-Path $apps 'claude.cmd') }

    Say '[2/2] Which API?'
    Write-Host '  1  Anthropic        (key from https://console.anthropic.com)'
    Write-Host '  2  DeepSeek         (key from https://platform.deepseek.com)'
    Write-Host '  3  Another address  (any Anthropic-compatible API: you type the address and the model name)'
    Write-Host '  Enter alone = leave the settings as they are'
    $c = (Read-Host '  Choice').Trim()
    if ($c -in '1', '2', '3') {
        $base = ''; $model = ''
        if ($c -eq '2') {
            $base = 'https://api.deepseek.com/anthropic'
            $model = (Read-Host '  Model name (Enter = deepseek-chat)').Trim(); if (-not $model) { $model = 'deepseek-chat' }
        } elseif ($c -eq '3') {
            $base = (Read-Host '  API address, e.g. https://example.com/anthropic').Trim()
            $model = (Read-Host '  Model name').Trim()
            if (-not $base) { Write-Host '  no address: nothing changed.' -ForegroundColor Yellow; return }
        }
        $key = AskKey 'API key'
        $dir = Join-Path $env:USERPROFILE '.claude'; $file = Join-Path $dir 'settings.json'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $cfg = $null
        if (Test-Path $file) { try { $cfg = Get-Content $file -Raw | ConvertFrom-Json } catch {} }
        if (-not $cfg) { $cfg = New-Object PSObject }
        $old = @{}
        if ($cfg.PSObject.Properties['env']) { $cfg.env.PSObject.Properties | ForEach-Object { $old[$_.Name] = $_.Value } }
        $savedKey = if ($old['ANTHROPIC_AUTH_TOKEN']) { $old['ANTHROPIC_AUTH_TOKEN'] } else { $old['ANTHROPIC_API_KEY'] }
        if (-not $key) { $key = $savedKey }
        foreach ($n in 'ANTHROPIC_BASE_URL', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
                       'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC') { $old.Remove($n) }
        if ($base) {
            $old['ANTHROPIC_BASE_URL'] = $base
            if ($key) { $old['ANTHROPIC_AUTH_TOKEN'] = $key }
            if ($model) { foreach ($n in 'ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL') { $old[$n] = $model } }
            $old['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
        } elseif ($key) { $old['ANTHROPIC_API_KEY'] = $key }
        $envObj = New-Object PSObject
        foreach ($n in ($old.Keys | Sort-Object)) { $envObj | Add-Member -NotePropertyName $n -NotePropertyValue $old[$n] }
        if ($cfg.PSObject.Properties['env']) { $cfg.env = $envObj } else { $cfg | Add-Member -NotePropertyName 'env' -NotePropertyValue $envObj }
        [IO.File]::WriteAllText($file, ($cfg | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $key = $null
        Write-Host "  saved in $file" -ForegroundColor Green
        if (-not $old['ANTHROPIC_AUTH_TOKEN'] -and -not $old['ANTHROPIC_API_KEY']) { Write-Host '  no key saved yet: tap the button again to enter it.' -ForegroundColor Yellow }
    }
    Say '=== Done ===' 'Green'
    Write-Host 'Start it with:  claude        (in a new console window if this one says it cannot find it)'
    Write-Host 'Change the API or the key: tap the button again.'
}
"""#

    // MARK: Image import

    /// Non-nil while files are being copied in (shown on the launch page).
    @Published var importStatus: String? = nil
    @Published var importError: String? = nil

    /// Same folder the bridge boots from: Documents/Machines/Win11, or Documents itself for old layouts.
    private var machineDirectoryURL: URL { machineDirectory(for: machine) }

    func machineDirectory(for machine: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if machine == "Arch" {
            let alt = ProcessInfo.processInfo.environment["WINIOS_ARCH_DIR"] ?? ""  // testing: see winios_bridge.m
            let arch = docs.appendingPathComponent(alt.isEmpty ? "Machines/Arch" : alt, isDirectory: true)
            try? FileManager.default.createDirectory(at: arch, withIntermediateDirectories: true)
            return arch
        }
        let win11 = docs.appendingPathComponent("Machines/Win11", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: win11.appendingPathComponent("code.fd").path),
           fm.fileExists(atPath: docs.appendingPathComponent("code.fd").path) {
            return docs
        }
        try? fm.createDirectory(at: win11, withIntermediateDirectories: true)
        return win11
    }

    // MARK: The machine list

    struct MachineInfo: Identifiable {
        let id: String       // "Win11", "Arch"
        let title: String
        let symbol: String
    }
    static let machines = [MachineInfo(id: "Win11", title: "Windows 11", symbol: "square.grid.2x2.fill"),
                           MachineInfo(id: "Arch", title: "Arch Linux", symbol: "terminal.fill")]

    /// One line under a machine's name in the list: running, being installed, ready, or not set up.
    func machineSubtitle(_ id: String) -> String {
        if id == machine && isVMRunning { return L("运行中", "Running") }
        if id == "Arch" && id == machine, archInstallStatus != nil { return L("正在安装", "Installing") }
        let dir = machineDirectory(for: id)
        let fm = FileManager.default
        let disk = ["windows11.img", "windows11.hvsparse"].first { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        guard fm.fileExists(atPath: dir.appendingPathComponent("code.fd").path), let disk else {
            return L("未配置", "Not set up")
        }
        if let n = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(disk).path))?[.size] as? NSNumber,
           disk.hasSuffix(".img") {
            return L("已停止", "Stopped") + String(format: " · %.0f GB", n.doubleValue / Double(1 << 30))
        }
        return L("已停止", "Stopped")
    }

    // MARK: Deleting a machine

    static let machineFileNames = ["code.fd", "vars.fd", "windows11.img", "windows11.hvsparse", "drivers.img", "installer.img"]

    /// Bytes the chosen machine's files take on the device (sparse disks count only what is written).
    var machineFilesBytes: UInt64 {
        _ = diskSizeRevision
        let dir = machineDirectoryURL
        return VMViewModel.machineFileNames.reduce(0) { sum, name in
            let url = dir.appendingPathComponent(name)
            let used = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            return sum + UInt64(max(0, used))
        }
    }

    var hasAnyMachineFiles: Bool {
        _ = diskSizeRevision
        let dir = machineDirectoryURL
        return VMViewModel.machineFileNames.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Deletes the chosen machine: its firmware, settings and disks (only these files, by name: an old
    /// layout keeps Windows directly in Documents). Cannot be undone.
    func deleteMachine() -> String? {
        guard !isVMRunning, !isUnpacking, importStatus == nil else { return L("虚拟机正在运行或正在导入。", "The machine is running or importing.") }
        let dir = machineDirectoryURL
        var failed: [String] = []
        for name in VMViewModel.machineFileNames {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) } catch { failed.append(name) }
        }
        if isLinux {
            try? FileManager.default.removeItem(at: VMViewModel.documentsURL.appendingPathComponent("Shared/arch_install_status.txt"))
            archInstallStatus = nil
        }
        archInstallError = nil
        importError = nil
        diskSizeRevision += 1
        syncFromBridge()
        return failed.isEmpty ? nil : L("没能删除：", "Could not delete: ") + failed.joined(separator: ", ")
    }

    // MARK: System disk size

    static let diskSizeChoices = [16, 24, 32, 48, 64, 96, 128, 192, 256]
    /// Bumped after a resize so views showing the size read it again.
    @Published var diskSizeRevision = 0

    /// Size of the machine's disk image (windows11.img), nil while there is none (or only the packed .hvsparse).
    var diskSizeBytes: UInt64? {
        _ = diskSizeRevision
        let url = machineDirectoryURL.appendingPathComponent("windows11.img")
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return nil }
        return n.uint64Value
    }

    /// Makes the disk image bigger (never smaller). The new space is a hole in the file: it takes no room
    /// on the device until the guest writes there. The guest still has to grow its partition and file
    /// system (Arch does it by itself at the next boot, winios-growroot; Windows: Disk Management, Extend Volume).
    func growDisk(toGB gb: Int) -> String? {
        guard !isVMRunning else { return L("先关闭虚拟机再扩容。", "Shut the virtual machine down first.") }
        guard let cur = diskSizeBytes else { return L("没有找到系统盘。", "No system disk found.") }
        let target = UInt64(gb) << 30
        guard target > cur else { return L("只能扩大，不能缩小。", "A disk can only grow, not shrink.") }
        let path = machineDirectoryURL.appendingPathComponent("windows11.img").path
        if truncate(path, off_t(target)) != 0 {
            return L("扩容失败：", "Could not resize: ") + String(cString: strerror(errno))
        }
        diskSizeRevision += 1
        return nil
    }

    /// The name a picked file is stored under, or nil when it is not a file the VM uses.
    static func importTarget(for url: URL) -> String? {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".hvsparse") { return "windows11.hvsparse" }
        if n.hasSuffix(".fd") { return n.contains("vars") ? "vars.fd" : n.contains("code") ? "code.fd" : nil }
        if n.hasSuffix(".img") { return n.contains("driver") || n.contains("winkit") ? "drivers.img" : "windows11.img" }
        return nil
    }

    static func isDiskTarget(_ name: String) -> Bool { name == "windows11.hvsparse" || name == "windows11.img" }

    /// True when a Windows disk is already installed (importing another one replaces it).
    var hasWindowsDisk: Bool {
        let dir = machineDirectoryURL
        return ["windows11.img", "windows11.hvsparse"].contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    func importFiles(_ urls: [URL]) {
        guard importStatus == nil, !isVMRunning, !isUnpacking else { return }
        let jobs = urls.compactMap { u in VMViewModel.importTarget(for: u).map { (u, $0) } }
        guard !jobs.isEmpty else {
            importError = L("没有可导入的文件。支持：code.fd、vars.fd、*.hvsparse、*.img（名字含 driver 的作为驱动盘）。",
                            "Nothing to import. Supported: code.fd, vars.fd, *.hvsparse, *.img (names containing \"driver\" become the driver disk).")
            return
        }
        let dir = machineDirectoryURL
        importError = nil
        importStatus = L("正在导入…", "Importing…")
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var failure: String? = nil
            for (i, (src, name)) in jobs.enumerated() {
                DispatchQueue.main.async {
                    self.importStatus = L("正在导入 \(name)（\(i + 1)/\(jobs.count)）…", "Importing \(name) (\(i + 1)/\(jobs.count))…")
                }
                let scoped = src.startAccessingSecurityScopedResource()
                defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                let dst = dir.appendingPathComponent(name)
                let tmp = dir.appendingPathComponent(name + ".importing")
                do {
                    try? fm.removeItem(at: tmp)
                    if src.standardizedFileURL.path != dst.standardizedFileURL.path {
                        try fm.copyItem(at: src, to: tmp)
                        // The new disk replaces the old one in either format.
                        if VMViewModel.isDiskTarget(name) {
                            try? fm.removeItem(at: dir.appendingPathComponent("windows11.img"))
                            try? fm.removeItem(at: dir.appendingPathComponent("windows11.hvsparse"))
                        }
                        try? fm.removeItem(at: dst)
                        try fm.moveItem(at: tmp, to: dst)
                    }
                } catch {
                    try? fm.removeItem(at: tmp)
                    failure = "\(name): \(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async {
                self.importStatus = nil
                self.importError = failure
                self.objectWillChange.send()
            }
        }
    }

    /// What the running machine reports about the GPU (from the status file the app writes).
    var gpuStatusSummary: String {
        let t = (try? String(contentsOf: VMViewModel.documentsURL.appendingPathComponent("boot_status.txt"), encoding: .utf8)) ?? ""
        guard let line = t.split(separator: "\n").first(where: { $0.hasPrefix("gpu:") }) else { return "-" }
        if line.contains("3d=on") { return line.contains("metal") ? "3D (Metal)" : "3D" }
        if line.contains("driver_ok=1") { return "2D" }
        return "Basic"
    }

    func sendTaskManager() {
        WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe0), NSNumber(value: 0xe1)], key: 0x29)
    }

    private var didAutoLaunchAttempt = false
    private var oauthPollTimer: Timer? = nil

    init() {
        // before anything can acquire JIT: the sizes it will use
        winios_jit_configure(UInt32(max(0, UserDefaults.standard.integer(forKey: "winios.jitMB"))),
                             UInt32(max(0, UserDefaults.standard.integer(forKey: "winios.ramMB"))))
        winios_jit_configure_3d(VMViewModel.readGPU3DSwitch())
        let bridge = WinIOSBridge.shared
        bridge.installTrapGuard()
        bridge.setDisplayFrameRate(frameRate)
        display.attach(to: self) // per-screen display settings, pushed before Windows can start
        bridge.onStateChanged = { [weak self] in
            Task { @MainActor in
                self?.syncFromBridge()
            }
        }
        syncFromBridge()
        startOAuthPoller()
        watchHardwareKeyboard()
        Task { @MainActor [weak self] in
            self?.onAppBecameActive()
        }
    }

    private func startOAuthPoller() {
        oauthPollTimer?.invalidate()
        oauthPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let b = WinIOSBridge.shared
                if b.takeGuestOAuthDone() {
                    if self.activeSafariURL != nil {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.activeSafariURL = nil
                    }
                }
                if let urlStr = b.takeGuestOpenURL(), let u = URL(string: urlStr) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    self.activeSafariURL = IdentifiableURL(url: u)
                }
            }
        }
    }

    /// The former HiDPI switch: Sharp (on) or Balanced (off) for the current screen; changes now, Windows'
    /// scale with it. With HV_DISPLAY_LEGACY it is the old native-pixel switch.
    func toggleHiDPIDisplay() {
        hiDPIDisplay.toggle()
        if WinIOSBridge.shared.displayLegacy {
            WinIOSBridge.shared.hiDPIDisplay = hiDPIDisplay
        } else {
            display.sharpness = hiDPIDisplay ? .sharp : .balanced
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func toggleOAuthBrowserMode() {
        useSafariForOAuth.toggle()
        WinIOSBridge.shared.useSafariForGuestLinks = useSafariForOAuth
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Posture (foldable devices)

    /// The device's model identifier, e.g. "iPhone19,4".
    nonisolated static let modelIdentifier: String = {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    /// Foldable devices the app knows, for when the hinge does not report (yet).
    nonisolated static let isKnownFoldable: Bool = ["iPhone19,4"].contains(modelIdentifier)

    /// Laptop posture is offered on foldable devices only; everything else always shows Studio.
    var supportsLaptopPosture: Bool { hingeAvailable || VMViewModel.isKnownFoldable }

    /// The size of the whole screen, last reported by the session view (for the posture choice).
    @Published var viewportSize: CGSize = .zero

    var isLaptopLayoutActive: Bool { isLaptopLayoutActive(for: viewportSize) }

    func isLaptopLayoutActive(for size: CGSize) -> Bool {
        guard supportsLaptopPosture else { return false }
        switch postureMode {
        case .laptop:
            return true
        case .fullScreen:
            return false
        case .auto:
            // The hinge runs across the screen only while the inner screen is upright.
            guard size.height > size.width else { return false }
            switch hingeStatusRaw {
            case 2: return true          // partially open: a laptop
            case 1, 3: return false      // closed (the cover screen) or flat
            default: break
            }
            if let deg = hingeAngleDegrees {
                return deg >= 30.0 && deg <= 166.0
            }
            // No hinge reading: the unfolded inner screen held upright defaults to Laptop.
            return max(size.width, size.height) > 780 && min(size.width, size.height) > 580
        }
    }

    func updateHinge(statusRaw: Int, angleDegrees: Double?, viewportSize: CGSize) {
        let wasPartiallyOpen = (hingeStatusRaw == 2)
        hingeStatusRaw = statusRaw
        hingeAngleDegrees = angleDegrees
        if angleDegrees != nil && !hingeAvailable { hingeAvailable = true }
        if postureMode == .auto && statusRaw == 2 && !wasPartiallyOpen {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            SceneOrientationController.alignForLaptopPostureIfLandscape(size: viewportSize)
        }
    }

    func setPostureMode(_ mode: PostureMode, viewportSize: CGSize) {
        guard mode != postureMode else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        postureMode = mode
        if isLaptopLayoutActive(for: viewportSize) || mode == .laptop {
            systemKeyboardVisible = false // the deck has the keyboard
            SceneOrientationController.alignForLaptopPostureIfLandscape(size: viewportSize)
        }
    }

    func cyclePostureMode(viewportSize: CGSize) {
        switch postureMode {
        case .auto: setPostureMode(.laptop, viewportSize: viewportSize)
        case .laptop: setPostureMode(.fullScreen, viewportSize: viewportSize)
        case .fullScreen: setPostureMode(.auto, viewportSize: viewportSize)
        }
    }

    func launchGuestEdgeBrowser() {
        // Win+R -> "msedge" -> Enter
        WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            let msedgeHids: [UInt8] = [0x10, 0x16, 0x08, 0x07, 0x0a, 0x08, 0x28] // m s e d g e Enter
            for (idx, code) in msedgeHids.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.045) {
                    WinIOSBridge.shared.tapKeyHid(code)
                }
            }
        }
    }

    func launchGuestPaint() {
        // Win+R -> "mspaint" -> Enter
        WinIOSBridge.shared.sendKeyCombo(withModifiers: [NSNumber(value: 0xe3)], key: 0x15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            // m s p a i n t Enter
            let paintHids: [UInt8] = [0x10, 0x16, 0x13, 0x04, 0x0c, 0x11, 0x17, 0x28]
            for (idx, code) in paintHids.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.042) {
                    WinIOSBridge.shared.tapKeyHid(code)
                }
            }
        }
    }

    // MARK: Installing Arch Linux (the machine installs itself: winios_bridge.m, scripts/arch/installer)

    /// The running installation's last report ("<percent> <message>" or "error ..."), nil when none is under way.
    @Published var archInstallStatus: String? = nil
    @Published var archInstallError: String? = nil
    static let archInstallSizes = [16, 32, 64, 128]

    var archInstallPercent: Double? {
        guard let s = archInstallStatus, let n = Double(s.split(separator: " ").first ?? "") else { return nil }
        return min(1, max(0, n / 100))
    }
    var archInstallMessage: String {
        guard let s = archInstallStatus else { return "" }
        if s.hasPrefix("error") { return s }
        return s.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? s
    }

    /// A blank system disk of sizeGB, the firmware and the installer disk, then start: the installer
    /// downloads Arch Linux ARM (about 0.8 GB), the first boot the desktop and GPU drivers (about 1.5 GB).
    func installArch(sizeGB: Int) {
        archInstallError = nil
        if let e = WinIOSBridge.shared.prepareArchInstall(withSizeGB: UInt(sizeGB)) {
            archInstallError = e
            return
        }
        diskSizeRevision += 1
        syncFromBridge()
        startOrRetry()
    }

    func syncFromBridge() {
        let b = WinIOSBridge.shared
        isJITLive = b.isJITLive
        isDebuggerAttached = b.isDebuggerAttached
        let wasRunning = isVMRunning
        isVMRunning = b.isVMRunning
        if isLinux {
            archInstallStatus = b.archInstallPending() ? b.archInstallStatus() : nil
            // The installer powers the machine off once the base system is on the disk: start it again
            // for the first boot, which installs the desktop.
            if wasRunning && !isVMRunning, let p = archInstallPercent, p >= 0.75, p < 1,
               !(archInstallStatus ?? "").hasPrefix("error") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startOrRetry() }
            }
        }
        if isVMRunning && !wasRunning && isLinux && !hardwareKeyboard && !isLaptopLayoutActive { systemKeyboardVisible = true }
        isUnpacking = b.isUnpacking
        unpackProgress = b.unpackProgress
        jitStatusText = b.jitStatusText
        vmStatusText = b.vmStatusText
        fbWidth = b.framebufferWidth
        fbHeight = b.framebufferHeight
        presentedFrames = b.presentedFrames
        availableMemoryMB = b.availableMemoryMB
        usbKeyboardReady = b.usbKeyboardReady
        usbTabletReady = b.usbTabletReady
        usbEventsDelivered = b.usbEventsDelivered
    }

    func onAppBecameActive() {
        let b = WinIOSBridge.shared
        if !b.isJITLive && b.isDebuggerAttached {
            _ = b.tryAcquireJIT(true)
        }
        syncFromBridge()
        if autoStart && b.isJITLive && !b.isVMRunning && !b.isUnpacking && b.hasProvisionedMachine() && !didAutoLaunchAttempt {
            didAutoLaunchAttempt = true
            b.prepareAndStart(with: nil)
            syncFromBridge()
        }
        JITSetup.shared.appBecameActive { [weak self] in self?.onAppBecameActive() } // app-jit hook
    }

    func startOrRetry() {
        didAutoLaunchAttempt = true
        WinIOSBridge.shared.prepareAndStart(with: nil)
        syncFromBridge()
    }

    func requestStikDebugJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var urlStr = "stikjit://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())"
        if let scriptPath = Bundle.main.path(forResource: "henge-jit", ofType: "js"),
           let script = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           let data = script.data(using: .utf8) {
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            if let encoded = b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlStr += "&script-data=\(encoded)"
            }
        }
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
