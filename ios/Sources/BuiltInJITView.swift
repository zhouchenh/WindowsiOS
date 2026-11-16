// SPDX-License-Identifier: GPL-2.0-or-later
//
// The JIT method picker, the Enable button and Built-in JIT's setup (docs/builtin-jit.md): Developer
// Mode, pairing (on this iPhone with iOS 27, or a pairing file), the connection (LocalDevVPN or the
// user's own VPN), Prepare, Enable. After
// Henge's JITSetupView.swift (Leviidev/Henge, GPL-2.0-or-later, 7b55730), written for this app.
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The JIT row's button on the launch page: enables JIT with the method in use.
struct JITEnableButton: View {
    @ObservedObject private var jit = JITSetup.shared

    var body: some View {
        Button(jit.resolvedMethod == .builtIn ? L("用内置 JIT 开启", "Enable with built-in JIT")
                                              : L("用 StikDebug 开启", "Enable with StikDebug")) {
            jit.enable()
        }
        // Not while the setup's Prepare or Reset DDI runs either: the helper's disk image cache is shared.
        .disabled(jit.busy || jit.helperBusy)
    }
}

/// The method picker, and for the built-in method its pairing state and a way into its setup.
struct JITMethodRow: View {
    @ObservedObject private var jit = JITSetup.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("JIT 方式", "JIT method"), selection: $jit.method) {
                ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(jit.busy)
            Text(summary)
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if jit.method != .stikDebug {
                Button(L("内置 JIT 设置…", "Built-in JIT setup…"), systemImage: "gearshape") { jit.showBuiltInSetup = true }
                    .font(.footnote)
                    .disabled(jit.busy)
            }
        }
    }

    private var summary: String {
        switch jit.method {
        case .automatic:
            return jit.resolvedMethod == .builtIn
                ? L("已配对，会用 App 自带的调试器（内置 JIT）。", "Paired: the debugger inside the app (built-in JIT) is used.")
                : L("还没有配对内置 JIT，所以会用 StikDebug。", "Built-in JIT is not paired yet, so StikDebug is used.")
        case .stikDebug:
            return L("跳到 StikDebug App 开启 JIT（需要在 StikDebug 里导入本机配对文件）。",
                     "Switches to the StikDebug app for JIT (it needs this device's pairing file).")
        case .builtIn:
            if let reason = WinBuiltInJIT.unavailableReason { return reason }
            guard jit.hasPairing else { return L("还没有配对：打开设置完成一次性配对。", "Not paired yet: open the setup to pair once.") }
            return jit.connectionMode == .ownVPN
                ? L("App 自带的调试器通过你的 VPN 连到本机开启 JIT，不需要 StikDebug、LocalDevVPN 和电脑。",
                    "The debugger inside the app attaches through your own VPN: no StikDebug, no LocalDevVPN, no computer.")
                : L("App 自带的调试器通过 LocalDevVPN 连到本机开启 JIT，不需要 StikDebug 和电脑。",
                    "The debugger inside the app attaches through LocalDevVPN: no StikDebug, no computer.")
        }
    }
}

/// Built-in JIT's setup, step by step.
struct BuiltInJITSetupView: View {
    @ObservedObject private var jit = JITSetup.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var confirmRemove = false
    @State private var vpnConnected = LocalDevVPN.isConnected
    @State private var ownVPNConnected = OwnVPN.isConnected
    @FocusState private var addressFocused: Bool
    private let vpnTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                developerModeSection
                pairingSection
                vpnSection
                prepareSection
                enableSection
                notesSection
            }
            .navigationTitle(L("内置 JIT", "Built-in JIT"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("完成", "Done")) { dismiss() } }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.propertyList, UTType(filenameExtension: "mobiledevicepairing") ?? .data, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { jit.importPairingFile(url) }
            }
            .confirmationDialog(L("删除配对文件？", "Remove the pairing file?"), isPresented: $confirmRemove, titleVisibility: .visible) {
                Button(L("删除", "Remove"), role: .destructive) { jit.removePairing() }
            }
            .onReceive(vpnTimer) { _ in
                vpnConnected = LocalDevVPN.isConnected
                ownVPNConnected = OwnVPN.isConnected
            }
            .onAppear {
                jit.refreshPairingStatus()
                vpnConnected = LocalDevVPN.isConnected
                ownVPNConnected = OwnVPN.isConnected
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            if let reason = WinBuiltInJIT.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            if WinIOSBridge.shared.isJITLive {
                Label(L("JIT 已开启", "JIT is on"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            LabeledContent("TXM", value: jit.txmPresent.map { $0 ? L("有（需要调试器）", "Present (a debugger is needed)") : L("没有", "Not present") }
                                         ?? L("助手运行后可知", "Known once the helper has run"))
            if jit.busy, let status = jit.status {
                HStack(spacing: 8) { ProgressView(); Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            if let error = jit.error {
                Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L("状态", "Status"))
        } footer: {
            Text(L("内置 JIT 把调试器（StikJIT）作为 App 扩展装在 Apple VM 里，通过 LocalDevVPN（或你自己的 VPN）连到本机，给 Apple VM 开启 JIT。不需要 StikDebug，也不需要电脑。",
                   "Built-in JIT ships a debugger (StikJIT) inside Apple VM as an app extension. It reaches this device through LocalDevVPN (or your own VPN) and turns on JIT for Apple VM: no StikDebug app and no computer."))
        }
    }

    private var developerModeSection: some View {
        Section {
            Text(L("设置 › 隐私与安全性 › 开发者模式：打开并重启。只需一次。",
                   "Settings › Privacy & Security › Developer Mode: turn it on and restart. Once."))
                .font(.footnote)
        } header: {
            Text(L("1. 开发者模式", "1. Developer Mode"))
        }
    }

    private var pairingSection: some View {
        Section {
            HStack {
                Image(systemName: jit.hasPairing ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(jit.hasPairing ? .green : .secondary)
                Text(pairingStatus).font(.footnote)
            }
            if OnDevicePairing.isSupported {
                pairOnDevice
            }
            Button(L("导入配对文件…", "Import pairing file…"), systemImage: "doc.badge.plus") { importing = true }
                .disabled(pairing.active)
            if jit.hasPairing {
                Button(L("删除配对文件", "Remove pairing file"), systemImage: "trash", role: .destructive) { confirmRemove = true }
                    .disabled(pairing.active || jit.busy)
            }
        } header: {
            Text(L("2. 配对（一次）", "2. Pair (once)"))
        } footer: {
            Text(OnDevicePairing.isSupported
                 ? L("已经在用 StikDebug？直接导入它的配对文件：浏览 › 我的 iPhone › StikDebug › pairingFile.plist。iOS 27 也可以直接在本机配对：点“在本机配对”，然后去 设置 › 隐私与安全性 › 开发者模式，点“与 Apple VM 配对”，输入这里显示的配对码。需要 Wi-Fi 和“本地网络”权限。也可以导入在电脑上生成的配对文件（RPPairing plist），或通过“文件”App放到 Apple VM/StikJIT/pairingFile.plist。",
                     "Already use StikDebug? Import its pairing file: Browse › On My iPhone › StikDebug › pairingFile.plist. iOS 27 can also pair on the device itself: tap Pair on this iPhone, then in Settings › Privacy & Security › Developer Mode tap Pair with Apple VM and type the code shown here. Needs Wi-Fi and Local Network access. You can also import a pairing file (RPPairing plist) made on a computer, or put it in Apple VM/StikJIT/pairingFile.plist with the Files app.")
                 : L("已经在用 StikDebug？直接导入它的配对文件：浏览 › 我的 iPhone › StikDebug › pairingFile.plist。这个 iOS 版本不能在本机配对（需要 iOS 27）。请在电脑上生成配对文件（RPPairing plist）后导入，或通过“文件”App放到 Apple VM/StikJIT/pairingFile.plist。",
                     "Already use StikDebug? Import its pairing file: Browse › On My iPhone › StikDebug › pairingFile.plist. This iOS cannot pair on the device (that needs iOS 27). Make a pairing file (RPPairing plist) on a computer and import it, or put it in Apple VM/StikJIT/pairingFile.plist with the Files app."))
        }
    }

    @ViewBuilder private var pairOnDevice: some View {
        switch pairing.phase {
        case .idle, .paired, .failed:
            Button(L("在本机配对", "Pair on this \(OnDevicePairing.deviceKind)"), systemImage: "link") {
                pairing.reset()
                pairing.start()
            }
            .disabled(jit.busy)
            if case .failed(let message) = pairing.phase {
                Text(message).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L("等待配对：打开 设置 › 隐私与安全性 › 开发者模式，点“与 Apple VM 配对”。",
                           "Waiting: open Settings › Privacy & Security › Developer Mode and tap Pair with Apple VM."))
                        .font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
                if pairing.backgroundLimited {
                    Text(L("iOS 只允许 Apple VM 在后台等很短时间：切到设置后请马上配对。",
                           "iOS lets Apple VM wait only briefly in the background: pair in Settings straight away."))
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(L("打开设置", "Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Spacer()
                    Button(L("取消", "Cancel"), role: .cancel) { pairing.cancel() }
                }
                .buttonStyle(.borderless)
            }
        case .pin(let pin):
            VStack(alignment: .leading, spacing: 6) {
                Text(L("在设置里输入这个配对码：", "Type this code in Settings:")).font(.footnote)
                Text(pin)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .center)
                Button(L("取消", "Cancel"), role: .cancel) { pairing.cancel() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var pairingStatus: String {
        switch jit.pairingSource {
        case .onDevice: return L("已在本机配对", "Paired on this device")
        case .imported: return L("已导入配对文件", "Pairing file imported")
        case nil: return L("还没有配对", "Not paired")
        }
    }

    private var vpnSection: some View {
        Section {
            Picker(L("JIT 连接", "JIT connection"), selection: $jit.connectionMode) {
                ForEach(JITConnectionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(jit.busy || jit.helperBusy)
            if jit.connectionMode == .localDevVPN {
                HStack(spacing: 6) {
                    Image(systemName: vpnConnected ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundStyle(vpnConnected ? .green : .secondary)
                    Text(vpnConnected ? L("LocalDevVPN 已连接", "LocalDevVPN connected")
                                      : L("LocalDevVPN 未连接", "LocalDevVPN not connected"))
                        .font(.footnote)
                    Spacer()
                    if !vpnConnected {
                        Button(LocalDevVPN.isInstalled ? L("连接", "Connect") : L("获取", "Get")) { LocalDevVPN.open() }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                ownVPNRows
            }
        } header: {
            Text(L("3. 连接", "3. Connection"))
        } footer: {
            if jit.connectionMode == .localDevVPN {
                Text(L("免费的 App Store App。调试器通过它连到本机（10.7.0.1）。只有蜂窝网络时，如果连不上，请关掉再打开蜂窝数据，或连一次 Wi-Fi。",
                       "A free App Store app. The debugger reaches this device (10.7.0.1) through it. On cellular only, if it cannot connect, turn Cellular Data off and on again, or join a Wi-Fi once."))
            } else {
                Text(L("iOS 同时只能连一个 VPN。如果你的 VPN 服务器把某个地址转回本机（“反射”，例如把第二个 IPv6 地址 NAT64 到本机的 IPv4 隧道地址），调试器就能通过它连到本机，不需要 LocalDevVPN。填 IPv4 或 IPv6 地址，方括号可有可无。服务器的设置见 docs/builtin-jit.md。",
                       "iOS runs one VPN at a time. If your VPN's server routes an address back to this device (a reflector, for example NAT64 from a second IPv6 address to this device's IPv4 tunnel address), the debugger reaches this device through it instead of LocalDevVPN. Enter an IPv4 or IPv6 address, with or without brackets. docs/builtin-jit.md shows server setups."))
            }
        }
    }

    /// The user's own VPN: the device address, whether a VPN is up, and Test connection.
    @ViewBuilder private var ownVPNRows: some View {
        TextField(L("VPN 转回本机的地址", "Address your VPN routes back here"), text: $jit.vpnAddressText)
            .font(.body.monospaced())
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($addressFocused)
            .disabled(jit.busy || jit.helperBusy)
            .onSubmit(normalizeAddress)
            .onChange(of: addressFocused) { _, focused in if !focused { normalizeAddress() } }
        if !jit.vpnAddressText.trimmingCharacters(in: .whitespaces).isEmpty && jit.vpnDeviceAddress == nil {
            Text(L("不是有效的 IPv4 或 IPv6 地址（只填地址，不要端口或主机名）。",
                   "Not a valid IPv4 or IPv6 address (the address only: no port, no host name)."))
                .font(.footnote).foregroundStyle(.red)
        }
        HStack(spacing: 6) {
            Image(systemName: ownVPNConnected ? "checkmark.shield.fill" : "shield.slash")
                .foregroundStyle(ownVPNConnected ? .green : .secondary)
            Text(ownVPNConnected ? L("有 VPN 已连接", "A VPN is connected")
                                 : L("没有连接 VPN", "No VPN connected"))
                .font(.footnote)
        }
        if vpnConnected {
            Text(L("LocalDevVPN 正连着：iOS 同时只能连一个 VPN，请改连你自己的 VPN。",
                   "LocalDevVPN is connected: iOS runs one VPN at a time, so connect your own VPN instead."))
                .font(.footnote).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button(L("测试连接", "Test connection"), systemImage: "network") {
            normalizeAddress()
            jit.testConnection()
        }
        .disabled(jit.vpnDeviceAddress == nil || jit.helperBusy || jit.busy || !WinBuiltInJIT.isAvailable)
        if jit.testingConnection {
            HStack(spacing: 8) {
                ProgressView()
                Text(jit.connectionTestNote ?? "").font(.footnote).foregroundStyle(.secondary)
            }
        } else if let note = jit.connectionTestNote {
            Label(note, systemImage: jit.connectionTestPassed == true ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(jit.connectionTestPassed == true ? .green : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The address as the helper gets it: no brackets, canonical form. Left as typed while invalid.
    private func normalizeAddress() {
        if let address = jit.vpnDeviceAddress, address != jit.vpnAddressText { jit.vpnAddressText = address }
    }

    private var prepareSection: some View {
        Section {
            Button(L("准备（检查并挂载开发者磁盘映像）", "Prepare (check and mount the Developer Disk Image)"), systemImage: "externaldrive.badge.checkmark") {
                jit.prepareBuiltIn()
            }
            .disabled(!jit.hasPairing || jit.helperBusy || jit.busy || !WinBuiltInJIT.isAvailable)
            if jit.helperBusy && !jit.testingConnection {
                HStack(spacing: 8) { ProgressView(); Text(jit.helperNote ?? "").font(.footnote).foregroundStyle(.secondary) }
            } else if let note = jit.helperNote {
                Label(note, systemImage: jit.prepared ? "checkmark.circle.fill" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(jit.prepared ? .green : .secondary)
            }
            Button(L("重置开发者磁盘映像缓存", "Reset Developer Disk Image cache"), systemImage: "arrow.counterclockwise") {
                jit.resetDDI()
            }
            .font(.footnote)
            .disabled(jit.helperBusy || jit.busy || !WinBuiltInJIT.isAvailable)
        } header: {
            Text(L("4. 准备", "4. Prepare"))
        } footer: {
            Text(L("第一次会下载开发者磁盘映像。设备每次重启后需要重新挂载（开启 JIT 时也会自动做）。",
                   "The first time downloads the Developer Disk Image. After each restart of the device it is mounted again (Enable does this by itself too)."))
        }
    }

    private var enableSection: some View {
        Section {
            Button {
                jit.method = jit.method == .stikDebug ? .builtIn : jit.method
                jit.enable()
            } label: {
                Label(L("开启 JIT", "Enable JIT"), systemImage: "bolt.fill").font(.headline)
            }
            .disabled(!jit.hasPairing || jit.busy || jit.helperBusy || !WinBuiltInJIT.isAvailable || WinIOSBridge.shared.isJITLive)
            Toggle(L("打开 App 时自动开启 JIT", "Turn on JIT when the app opens"), isOn: $jit.enableAtLaunch)
                .font(.footnote)
        } header: {
            Text(L("5. 开启", "5. Enable"))
        } footer: {
            Text(L("JIT 开启后调试器会自动断开，不会留在后台。每次启动 Apple VM 都要开启一次。",
                   "Once JIT is on the debugger detaches by itself and nothing keeps running. JIT is needed once per launch of Apple VM."))
        }
    }

    private var notesSection: some View {
        Section {
            Text(L("• 在 LiveContainer 里运行时不能用内置 JIT，请用 StikDebug。\n• 用 SideStore、AltStore 等安装时要保留 App 扩展（PlugIns/WinJITHelper.appex）；免费 Apple ID 会多占一个 App ID。\n• 每次在本机配对都会替换之前给 Apple VM 的配对。",
                   "• Built-in JIT does not work inside LiveContainer: use StikDebug there.\n• SideStore, AltStore and other signing tools must keep the app extension (PlugIns/WinJITHelper.appex); with a free Apple ID it takes one more App ID.\n• Each pairing on the device replaces Apple VM's previous one."))
                .font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text(L("注意", "Notes"))
        }
    }
}
