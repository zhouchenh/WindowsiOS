// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Network
import SwiftUI
import UIKit

// Settings > Port forwarding: ports on this device that lead to a port in Windows (Remote Desktop, SSH, a web
// server). The rules live in the network code (host/net_slirp.c, saved per machine in port_forwards.json); this
// is their list, an editor, the addresses to connect to, and whether iOS allows the local network.
// docs/networking.md has the details.

/// One address family of a forward (hv_net_fwd_list_json's "ipv4" / "ipv6"): "listening", "error", "none" (the
/// scope has no address of that family now; message says why) or "off".
struct ForwardFamily: Decodable, Equatable {
    var state: String
    var message: String
}

/// One forward as hv_net_fwd_list_json describes it.
struct PortForward: Identifiable, Decodable, Equatable {
    var id: String
    var name: String
    var proto: String
    var hostPort: Int
    var guestPort: Int
    var scope: String
    var enabled: Bool
    var session: Bool
    var state: String
    var code: String
    var message: String
    var warning: String
    var listen: [String]
    /// Local network: also the network's global IPv6 addresses (missing from older engines: on).
    var ipv6Global: Bool?
    var ipv4: ForwardFamily?
    var ipv6: ForwardFamily?

    enum CodingKeys: String, CodingKey {
        case id, name, hostPort, guestPort, scope, enabled, session, state, code, message, warning, listen
        case ipv6Global, ipv4, ipv6
        case proto = "protocol"
    }

    /// The addresses it listens on, IPv4 first.
    var listen4: [String] { listen.filter { !$0.hasPrefix("[") } }
    var listen6: [String] { listen.filter { $0.hasPrefix("[") } }
}

private struct PortForwardList: Decodable {
    var running: Bool
    var rules: [PortForward]
}

struct DeviceAddress: Decodable, Hashable {
    var interface: String
    var address: String
    var family: Int
    /// A global IPv6 address (the internet may reach it where the router lets IPv6 in).
    var global: Bool?
    var isGlobal6: Bool { family == 6 && (global ?? false) }
}

private struct DeviceAddressList: Decodable {
    var lan: [DeviceAddress]
    var vpn: [DeviceAddress]
}

enum ForwardProtocol: Int, CaseIterable, Identifiable {
    case tcp = 1, udp = 2, both = 3
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .tcp: return "TCP"
        case .udp: return "UDP"
        case .both: return "TCP + UDP"
        }
    }
    init(json: String) {
        switch json {
        case "udp": self = .udp
        case "tcp+udp": self = .both
        default: self = .tcp
        }
    }
}

enum ForwardScope: Int, CaseIterable, Identifiable {
    case device = 0, localNetwork = 1, vpn = 2
    var id: Int { rawValue }
    init(json: String) {
        switch json {
        case "lan": self = .localNetwork
        case "vpn": self = .vpn
        default: self = .device
        }
    }
    var title: String {
        switch self {
        case .device: return L("仅限这台\(PortForwardText.device)", "This \(PortForwardText.device) only")
        case .localNetwork: return L("局域网", "Local network")
        case .vpn: return "VPN"
        }
    }
    var detail: String {
        switch self {
        case .device:
            return L("只有这台\(PortForwardText.device)上的 App 能连接（例如 iOS 上的远程桌面 App 连 localhost）。",
                     "Only apps on this \(PortForwardText.device) can connect (for example a Remote Desktop app here, to localhost).")
        case .localNetwork:
            return L("同一 Wi-Fi 或有线网络、或这台\(PortForwardText.device)个人热点上的设备能连接，IPv4 和 IPv6 都行。蜂窝网络连不进来。",
                     "Devices on the same Wi-Fi or wired network, or on this \(PortForwardText.device)'s Personal Hotspot, can connect, over IPv4 and IPv6. Not over cellular.")
        case .vpn:
            return L("只有 VPN（例如 WireGuard）里的设备能连接，IPv4 和 IPv6（VPN 的全部地址）都行；VPN 地址变了会自动跟上。",
                     "Only devices on your VPN (for example WireGuard) can connect, over IPv4 and IPv6 (every address the VPN gives this \(PortForwardText.device)). Follows the VPN's addresses when they change.")
        }
    }
}

enum PortForwardText {
    static var device: String { UIDevice.current.model } // "iPhone" or "iPad"
}

/// What the editor works on: a forward that exists, or a new one (perhaps from a preset).
struct PortForwardDraft: Identifiable {
    var id: String
    var isNew: Bool
    var name: String
    var proto: ForwardProtocol
    var hostPort: String
    var guestPort: String
    var scope: ForwardScope
    var enabled: Bool
    var session: Bool
    /// Local network: listen on the global IPv6 addresses too (on by default).
    var ipv6Global: Bool = true

    init(_ rule: PortForward) {
        id = rule.id
        isNew = false
        name = rule.name
        proto = ForwardProtocol(json: rule.proto)
        hostPort = String(rule.hostPort)
        guestPort = String(rule.guestPort)
        scope = ForwardScope(json: rule.scope)
        enabled = rule.enabled
        session = rule.session
        ipv6Global = rule.ipv6Global ?? true
    }

    init(name: String, proto: ForwardProtocol, hostPort: Int, guestPort: Int) {
        id = "fwd-" + UUID().uuidString.prefix(8).lowercased()
        isNew = true
        self.name = name
        self.proto = proto
        self.hostPort = hostPort > 0 ? String(hostPort) : ""
        self.guestPort = guestPort > 0 ? String(guestPort) : ""
        scope = .device
        enabled = true
        session = false
    }

    var hostPortValue: Int? { Int(hostPort.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }
    var guestPortValue: Int? { Int(guestPort.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }
    var isValid: Bool { hostPortValue != nil && guestPortValue != nil }
}

/// Ready-made forwards for common Windows services. The port on the device is above 1024 where the Windows one
/// is below it, since iOS may not let an app listen on low ports.
struct PortForwardPreset: Identifiable {
    var id: String { name }
    var name: String
    var detail: String
    var proto: ForwardProtocol
    var hostPort: Int
    var guestPort: Int

    static var all: [PortForwardPreset] {
        [
            PortForwardPreset(name: L("远程桌面", "Remote Desktop"), detail: "TCP + UDP 3389",
                              proto: .both, hostPort: 3389, guestPort: 3389),
            PortForwardPreset(name: "SSH", detail: "2222 → 22", proto: .tcp, hostPort: 2222, guestPort: 22),
            PortForwardPreset(name: L("网页服务器", "Web server"), detail: "8080 → 80", proto: .tcp, hostPort: 8080, guestPort: 80),
            PortForwardPreset(name: L("文件共享（SMB）", "File sharing (SMB)"), detail: "4445 → 445",
                              proto: .tcp, hostPort: 4445, guestPort: 445),
        ]
    }
}

/// Learns whether iOS lets the app use the local network, by browsing for a Bonjour type of its own: the first
/// browse brings up iOS's Local Network prompt, and a refusal shows as a policy-denied DNS error.
final class LocalNetworkAccess {
    enum Status { case unknown, allowed, denied }
    /// On the main queue, when iOS answers.
    var onChange: ((Status) -> Void)?
    private var browser: NWBrowser?

    func check() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_applevm._tcp", domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] state in
            let denied: Bool?
            switch state {
            case .ready: denied = false
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ { denied = true } else { denied = nil }
            default: denied = nil
            }
            guard let denied else { return }
            NSLog("portfwd: local network access %@", denied ? "denied" : "allowed")
            self?.onChange?(denied ? .denied : .allowed)
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

@MainActor
final class PortForwardingModel: ObservableObject {
    @Published private(set) var rules: [PortForward] = []
    @Published private(set) var running = false
    @Published private(set) var lan: [DeviceAddress] = []
    @Published private(set) var vpn: [DeviceAddress] = []
    @Published private(set) var localNetworkDenied = false
    private let localNetwork = LocalNetworkAccess()
    private var monitor: NWPathMonitor?

    private var bridge: WinIOSBridge { WinIOSBridge.shared }

    func start() {
        localNetwork.onChange = { [weak self] status in
            Task { @MainActor in self?.localNetworkDenied = status == .denied }
        }
        reload()
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.bridge.refreshPortForwards() // a VPN came or went: follow its address
                self.reload()
            }
        }
        m.start(queue: .main)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        localNetwork.stop()
    }

    func reload() {
        let decoder = JSONDecoder()
        if let data = bridge.portForwardsJSON().data(using: .utf8),
           let list = try? decoder.decode(PortForwardList.self, from: data) {
            if list.rules != rules { rules = list.rules }
            if list.running != running { running = list.running }
        }
        if needsAddresses,
           let data = bridge.portForwardAddressesJSON().data(using: .utf8),
           let a = try? decoder.decode(DeviceAddressList.self, from: data) {
            if a.lan != lan { lan = a.lan }
            if a.vpn != vpn { vpn = a.vpn }
        }
        if rules.contains(where: { $0.enabled && $0.scope == "lan" }) { localNetwork.check() }
    }

    /// Addresses matter once something is open beyond this device.
    var needsAddresses: Bool { rules.contains { $0.enabled && $0.scope != "loopback" } }

    /// nil when saved, else why not.
    func save(_ d: PortForwardDraft) -> String? {
        guard let hp = d.hostPortValue, let gp = d.guestPortValue else {
            return L("端口要在 1 到 65535 之间。", "Ports go from 1 to 65535.")
        }
        let name = d.name.trimmingCharacters(in: .whitespaces)
        if let err = bridge.savePortForward(id: d.id, name: name, protocols: d.proto.rawValue, hostPort: hp,
                                            guestPort: gp, scope: d.scope.rawValue, enabled: d.enabled,
                                            ipv6Global: d.ipv6Global) {
            return L("没有保存：", "Not saved: ") + err
        }
        if d.scope == .localNetwork && d.enabled { localNetwork.check() }
        reload()
        return nil
    }

    func setEnabled(_ rule: PortForward, _ on: Bool) -> String? {
        var d = PortForwardDraft(rule)
        d.enabled = on
        return save(d)
    }

    func remove(_ id: String) {
        _ = bridge.removePortForward(id: id)
        reload()
    }
}

/// The settings section (mounted in the Settings sheet's Form).
struct PortForwardingSection: View {
    @StateObject private var model = PortForwardingModel()
    @State private var editing: PortForwardDraft?
    @State private var toggleError: String?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            if model.rules.isEmpty {
                Text(L("还没有端口转发。从下面的常用服务开始，或者自己添加。",
                       "No port forwards yet. Start from a common service below, or add your own."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rules) { rule in
                PortForwardRow(rule: rule, onToggle: { on in
                    toggleError = model.setEnabled(rule, on)
                }, onEdit: { editing = PortForwardDraft(rule) })
                .swipeActions {
                    Button(role: .destructive) { model.remove(rule.id) } label: {
                        Label(L("删除", "Delete"), systemImage: "trash")
                    }
                }
            }
            if let toggleError {
                Text(toggleError).font(.footnote).foregroundStyle(.red)
            }
            Menu {
                ForEach(PortForwardPreset.all) { p in
                    Button {
                        editing = PortForwardDraft(name: p.name, proto: p.proto, hostPort: p.hostPort, guestPort: p.guestPort)
                    } label: {
                        Text(p.name + " · " + p.detail)
                    }
                }
                Divider()
                Button(L("自定义…", "Custom…")) {
                    editing = PortForwardDraft(name: "", proto: .tcp, hostPort: 0, guestPort: 0)
                }
            } label: {
                Label(L("添加端口转发", "Add a port forward"), systemImage: "plus.circle")
            }
            if model.rules.contains(where: { $0.enabled && $0.scope == "lan" }) && model.localNetworkDenied {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("本地网络权限已关闭", "Local Network access is off"), systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                    Text(L("其他设备连不进来。去“设置 → 隐私与安全性 → 本地网络”打开本 App。",
                           "Other devices can't connect. Turn it on for this app in Settings > Privacy & Security > Local Network."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(L("打开设置", "Open Settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.footnote)
                }
            }
            if model.needsAddresses {
                let lanRules = model.rules.filter { $0.enabled && $0.scope == "lan" }
                AddressRows(lan: model.lan, vpn: model.vpn, showLAN: !lanRules.isEmpty,
                            showVPN: model.rules.contains { $0.enabled && $0.scope == "vpn" },
                            showGlobal6: lanRules.contains { $0.ipv6Global ?? true })
            }
        } header: {
            Text(L("端口转发", "Port forwarding"))
        } footer: {
            Text(L("把这台\(PortForwardText.device)上的端口转到 Windows 里，例如用其他设备远程桌面或 SSH 连进 Windows。每个转发都同时监听 IPv4 和 IPv6。App 在前台时才能连进来，除非打开了上面的服务器模式（关闭主机 3D 时，Windows 在后台继续运行）。在 Windows 里运行 WINKIT 盘上的 REMOTE-DESKTOP.bat 或 SSH-SETUP.bat，打开远程桌面或 SSH 并放行防火墙。",
                   "Lead a port on this \(PortForwardText.device) to a port in Windows, for example to use Remote Desktop or SSH from another device. Every forward listens over IPv4 and IPv6. Connections come in while the app is in the foreground, or in the background too with Server mode above (Windows keeps running there without host 3D). In Windows, run REMOTE-DESKTOP.bat or SSH-SETUP.bat on the WINKIT drive to turn on Remote Desktop or SSH and open the firewall."))
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onReceive(tick) { _ in model.reload() }
        .sheet(item: $editing) { draft in
            PortForwardEditor(draft: draft, model: model)
        }
    }
}

private struct PortForwardRow: View {
    let rule: PortForward
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onEdit) { details }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityHint(L("编辑这个转发", "Edits this forward"))
            Spacer(minLength: 0)
            Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { onToggle($0) }))
                .labelsHidden()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rule.name)
                .foregroundStyle(.primary)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(rule.state == "error" ? .red : .secondary)
            }
            if rule.state == "listening" {
                ForwardFamilyLines(rule: rule)
            }
            if rule.session {
                Text(L("由 Windows 打开，App 退出后消失。编辑后会保存下来。", "Opened by Windows, until the app quits. Edit it to keep it."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
    }

    private var summary: String {
        let proto = ForwardProtocol(json: rule.proto).title
        let port = rule.hostPort == rule.guestPort ? "\(rule.hostPort)" : "\(rule.hostPort) → Windows \(rule.guestPort)"
        return "\(proto) \(port) · \(ForwardScope(json: rule.scope).title)"
    }

    private var statusColor: Color {
        switch rule.state {
        case "listening": return .green
        case "error": return .red
        default: return .gray
        }
    }

    private var statusText: String {
        switch rule.state {
        case "listening":
            return L("正在监听", "Listening")
        case "waiting": return L("Windows 启动后打开", "Opens when Windows starts")
        case "off":
            switch rule.code {
            case "env_off": return L("已关闭（env.txt 里 HV_NET_FWD_RULES=0）", "Off (HV_NET_FWD_RULES=0 in env.txt)")
            case "blocked": return L("暂时关闭：端口 \(rule.hostPort) 已被另一个转发占用。仍保存为打开。",
                                     "Off for now: port \(rule.hostPort) is taken by another forward. Still saved as on.")
            default: return L("已关闭", "Off")
            }
        case "error":
            switch rule.code {
            case "in_use":
                return L("端口 \(rule.hostPort) 被这台\(PortForwardText.device)上的其他 App 占用，会自动重试",
                         "Port \(rule.hostPort) is in use by another app on this \(PortForwardText.device). Retrying.")
            case "denied":
                return L("iOS 不允许使用端口 \(rule.hostPort)，请换一个 1024 以上的端口",
                         "iOS doesn't let apps use port \(rule.hostPort). Pick one above 1024.")
            case "no_vpn":
                return L("没有连接 VPN，连上后自动打开", "No VPN is connected. Opens when one connects.")
            case "no_address":
                return L("地址已失效，会自动重试", "The address went away. Retrying.")
            default:
                return rule.message.isEmpty ? L("打不开", "Couldn't open") : rule.message
            }
        default: return rule.state
        }
    }
}

/// Each address family of a listening forward on its own line: where it listens, or why it does not.
struct ForwardFamilyLines: View {
    let rule: PortForward

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            line("IPv4", rule.ipv4, rule.listen4)
            line("IPv6", rule.ipv6, rule.listen6)
        }
    }

    @ViewBuilder
    private func line(_ family: String, _ f: ForwardFamily?, _ at: [String]) -> some View {
        let state = f?.state ?? (at.isEmpty ? "none" : "listening")
        let message = f?.message ?? ""
        let text: String = {
            switch state {
            case "listening":
                return family + " · " + at.joined(separator: ", ") + (message.isEmpty ? "" : " · " + message)
            case "error":
                return family + " · " + L("打不开：", "not open: ") + message
            case "none":
                return family + " · " + (at.isEmpty ? "" : at.joined(separator: ", ") + " · ") + (message.isEmpty ? L("没有地址", "no address") : message)
            default:
                return family + " · " + (message.isEmpty ? L("未打开", "not open") : message)
            }
        }()
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(state == "error" || (state == "listening" && !message.isEmpty) ? .orange : .secondary)
            .textSelection(.enabled)
    }
}

/// Where to connect to: the device's local network and VPN addresses (both families, with the port when one is
/// given), and with showLoopback this device itself (127.0.0.1 and [::1], for an app on it).
struct AddressRows: View {
    let lan: [DeviceAddress]
    let vpn: [DeviceAddress]
    let showLAN: Bool
    var showVPN: Bool = true
    /// The local network's global IPv6 addresses (some local network forward listens on them).
    var showGlobal6: Bool = true
    var port: Int? = nil
    var showLoopback: Bool = false
    var title: String = L("从其他设备连接到", "From another device, connect to")

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if showLoopback {
                row(L("这台\(PortForwardText.device)", "This \(PortForwardText.device)"),
                    DeviceAddress(interface: "lo0", address: "127.0.0.1", family: 4, global: false))
                row(L("这台\(PortForwardText.device)", "This \(PortForwardText.device)"),
                    DeviceAddress(interface: "lo0", address: "::1", family: 6, global: false))
            }
            if showLAN {
                let shown = lan.filter { showGlobal6 || !$0.isGlobal6 }
                if shown.isEmpty {
                    Text(L("没有连接 Wi-Fi", "Not on Wi-Fi")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { a in row(label(for: a), a) }
            }
            if showVPN {
                if vpn.isEmpty {
                    Text(L("没有连接 VPN", "No VPN connected")).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(vpn, id: \.self) { a in row("VPN (\(a.interface))", a) }
                }
            }
        }
    }

    private func label(for a: DeviceAddress) -> String {
        let base: String
        if a.interface.hasPrefix("bridge") { base = L("个人热点", "Personal Hotspot") }
        else if a.interface == "en0" { base = "Wi-Fi" }
        else { base = a.interface }
        return a.isGlobal6 ? base + L("（全局）", " (global)") : base
    }

    private func text(_ a: DeviceAddress) -> String {
        let host = a.family == 6 ? "[\(a.address)]" : a.address
        if let port { return "\(host):\(port)" }
        return host
    }

    private func row(_ label: String, _ a: DeviceAddress) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout)
            Spacer(minLength: 8)
            Text(text(a))
                .font(.callout.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
        }
        .contextMenu {
            Button(L("拷贝", "Copy")) { UIPasteboard.general.string = text(a) }
            if port != nil { Button(L("只拷贝地址", "Copy the address only")) { UIPasteboard.general.string = a.address } }
        }
    }
}

private struct PortForwardEditor: View {
    @State var draft: PortForwardDraft
    @ObservedObject var model: PortForwardingModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("名称", "Name"), text: $draft.name)
                    Picker(L("协议", "Protocol"), selection: $draft.proto) {
                        ForEach(ForwardProtocol.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent(L("\(PortForwardText.device) 上的端口", "Port on this \(PortForwardText.device)")) {
                        TextField("3389", text: $draft.hostPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(L("Windows 里的端口", "Port in Windows")) {
                        TextField("3389", text: $draft.guestPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    if (!draft.hostPort.isEmpty && draft.hostPortValue == nil) || (!draft.guestPort.isEmpty && draft.guestPortValue == nil) {
                        Text(L("端口要在 1 到 65535 之间。", "Ports go from 1 to 65535.")).foregroundStyle(.red)
                    } else if let hp = draft.hostPortValue, hp < 1024 {
                        Text(L("iOS 可能不允许 App 使用 1024 以下的端口；打不开时换一个更大的。",
                               "iOS may not let apps use ports below 1024. If it won't open, pick a higher one."))
                    }
                }

                Section {
                    Picker(L("谁能连接", "Who can connect"), selection: $draft.scope) {
                        ForEach(ForwardScope.allCases) { s in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title)
                                Text(s.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if draft.scope == .localNetwork {
                        Toggle(L("IPv6 全局地址", "IPv6 global addresses"), isOn: $draft.ipv6Global)
                        Label {
                            Text(draft.ipv6Global
                                 ? L("也在 Wi-Fi 的 IPv6 全局地址上监听。路由器放行入站 IPv6 时（很多家用路由器默认挡住，但不是全部），互联网上的设备也可能连到这个端口。只想让局域网连，就关掉它：IPv4 和 IPv6 本地地址（fd00::/8）照样能用。",
                                     "Also listens on the Wi-Fi's global IPv6 addresses. Where the router lets incoming IPv6 through (many home routers block it, not all), devices on the internet may reach this port too. Turn it off to keep it to the local network: IPv4 and the local IPv6 addresses (fd00::/8) still work.")
                                 : L("只在 IPv4 和 IPv6 本地地址（fd00::/8）上监听。很多家庭网络只有 IPv6 全局地址：那时局域网里的设备只能用 IPv4 连。",
                                     "Listens on IPv4 and the local IPv6 addresses (fd00::/8) only. Many home networks only have global IPv6 addresses: devices there then connect over IPv4."))
                                .font(.footnote)
                        } icon: {
                            Image(systemName: draft.ipv6Global ? "globe" : "house").foregroundStyle(draft.ipv6Global ? .orange : .secondary)
                        }
                    }
                    if draft.scope != .device {
                        Label {
                            Text(L("谁能连上这个端口，谁就能尝试登录 Windows。请给 Windows 账户设一个强密码，用完就关掉这个转发。只在你信任的网络上使用。",
                                   "Anyone who can reach this port can try to sign in to Windows. Give your Windows account a strong password, turn the forward off when you're done, and use it only on networks you trust."))
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text(L("谁能连接", "Who can connect"))
                }

                Section {
                    Toggle(L("开启", "On"), isOn: $draft.enabled)
                } footer: {
                    Text(L("保存在这台虚拟机里，下次启动 Windows 时自动打开。", "Kept with this machine and opened each time Windows starts."))
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if !draft.isNew {
                    Section {
                        Button(L("删除这个转发", "Delete This Forward"), role: .destructive) {
                            model.remove(draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(draft.isNew ? L("添加端口转发", "Add Port Forward") : L("编辑端口转发", "Edit Port Forward"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存", "Save")) {
                        if let e = model.save(draft) { error = e } else { dismiss() }
                    }
                    .disabled(!draft.isValid)
                }
            }
        }
    }
}
