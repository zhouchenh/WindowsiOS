// SPDX-License-Identifier: GPL-2.0-or-later
//
// Built-in JIT: a debugger shipped inside the app (PlugIns/WinJITHelper.appex, which runs StikJIT)
// attaches to the app over LocalDevVPN and runs henge-jit.js, so JIT turns on with no StikDebug app
// and no computer. Developer Mode, one pairing and LocalDevVPN are still needed (docs/builtin-jit.md).
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: ios/Henge/JIT/JITBuiltIn.swift (the
// helper launcher), JITSetup.swift (JITMethod, the pairing-file store, RemotePairingPortDiscovery) and
// JITNetworkAdvice.swift; Entitlements.swift (the SecTask check). Built-in StikJIT and its on-device
// pairing first appeared in Husk (Leviidev/Husk, GPL-2.0-or-later) at 29abb51, docs/06-built-in-jit.md.
import Foundation
import Network
import UIKit

// MARK: - Method

/// How the app gets a debugger attached for JIT. The choice is kept in UserDefaults.
enum JITMethod: String, CaseIterable, Identifiable {
    /// Built-in when it is available here and paired, StikDebug otherwise.
    case automatic
    /// The StikDebug app, asked through stikjit:// (JITSetup.swift).
    case stikDebug
    /// The helper extension inside this app (WinBuiltInJIT).
    case builtIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L("自动", "Automatic")
        case .stikDebug: return "StikDebug"
        case .builtIn: return L("内置", "Built-in")
        }
    }

    static let defaultsKey = "winios.jit.method"

    static var stored: JITMethod {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(JITMethod.init(rawValue:)) ?? .automatic
    }
}

// MARK: - The helper

/// The private NSExtension API (ExtensionFoundation) that starts an app extension of the app's own:
/// the same calls LiveContainer uses to start its LiveProcess.
@objc private protocol NSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

/// Starts the separate helper process (PlugIns/WinJITHelper.appex) that debugs the app.
///
/// The helper is found by the bundle identifier it has in this installation, read from its own
/// Info.plist: sideloaders that sign with the user's own Apple ID (SideStore, AltStore, ...) append
/// the team ID to the app's identifier and the helper's alike, and that lookup survives them.
///
/// One extension request per WinJITRequest. For `enable` the request lasts until the JIT script
/// detaches (winios_jit.c asks it to, once the JIT region and guest RAM are held).
@MainActor
enum WinBuiltInJIT {
    static let helperFile = "WinJITHelper.appex"

    /// Requests that have started and not finished, kept alive until they do.
    private static var running: [HelperRequest] = [] {
        didSet { winios_jit_set_helper_pending(enableOutstanding) }
    }

    /// An enable request has not finished yet. It can still attach, even after the app stopped
    /// waiting for it (JITSetup's 150 s), until its script detaches or attaching fails; it is not
    /// cancelled instead, since ending the helper while its debugger is attached could take the app
    /// down with it. JITSetup keeps watching for it, and winios_jit.c asks it to detach when JIT is
    /// already on by then.
    static var enableOutstanding: Bool { running.contains { $0.isEnable } }

    /// Why Built-in JIT cannot work in this installation, or nil when it can.
    static var unavailableReason: String? {
#if targetEnvironment(simulator)
        return L("内置 JIT 只能在真机上使用。", "Built-in JIT works only on a real device.")
#else
        guard #available(iOS 26.0, *) else {
            return L("内置 JIT 需要 iOS 26 或更高版本，请改用 StikDebug。",
                     "Built-in JIT needs iOS 26 or later. Use StikDebug instead.")
        }
        if getenv("LC_HOME_PATH") != nil {
            return L("在 LiveContainer 里运行时不能用内置 JIT（它启动不了 App 扩展），请改用 StikDebug，或用 SideStore/AltStore 直接安装 Apple VM。",
                     "Built-in JIT is unavailable inside LiveContainer (it cannot start app extensions). Use StikDebug, or install Apple VM directly with SideStore or AltStore.")
        }
        if helperIdentifier == nil {
            return L("这次安装里没有 JIT 助手（PlugIns/WinJITHelper.appex）。重新安装 Apple VM；如果签名工具问起，选择保留 App 扩展。",
                     "The JIT helper (PlugIns/WinJITHelper.appex) is missing from this installation. Reinstall Apple VM, and keep its app extensions if your signing tool asks.")
        }
        if TaskEntitlements.getTaskAllow == false {
            return L("这次安装的签名里没有 get-task-allow，调试器连不上 Apple VM。请用开发证书（SideStore、AltStore 或 Xcode）重新签名安装。",
                     "This installation is not signed with get-task-allow, so no debugger can attach to Apple VM. Re-sign it with a development certificate (SideStore, AltStore or Xcode).")
        }
        return nil
#endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// The helper's bundle identifier in this installation; nil when a sideloader left it out.
    static var helperIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFile) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func send(_ request: WinJITRequest,
                     started: @escaping () -> Void = {},
                     completion: @escaping (Result<WinJITRequest.Response, Error>) -> Void) {
        func fail(_ code: Int, _ message: String) {
            jitLog("helper: " + message)
            completion(.failure(HelperRequest.error(code, message)))
        }
        if let reason = unavailableReason {
            fail(1, reason)
            return
        }
        guard let identifier = helperIdentifier else {
            fail(2, L("找不到 JIT 助手。", "The JIT helper is missing."))
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            fail(3, L("iOS 没有提供 JIT 助手需要的扩展接口。", "iOS did not provide the extension API the JIT helper needs."))
            return
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionClassShim.self)
        let found: AnyObject
        do { found = try factory.extension(withIdentifier: identifier) }
        catch {
            fail(2, L("找不到 JIT 助手（\(identifier)）：", "The JIT helper (\(identifier)) could not be found: ")
                    + error.localizedDescription + L(" 请重新安装 Apple VM。", " Reinstall Apple VM."))
            return
        }
        guard let data = try? JSONEncoder().encode(request) else {
            fail(4, "The request for the JIT helper could not be encoded.")
            return
        }
        let helper = HelperRequest(extension: found, operation: request.operation.rawValue, completion: completion)
        running.append(helper)
        helper.begin(data: data, identifier: identifier, started: started)
    }

    fileprivate static func finished(_ helper: HelperRequest) {
        running.removeAll { $0 === helper }
    }
}

/// One request to the helper, from its start to its one result.
@MainActor
private final class HelperRequest {
    private let shim: NSExtensionShim
    private let `extension`: AnyObject   // the NSExtension, kept alive for the request
    private let operation: String
    private var completion: ((Result<WinJITRequest.Response, Error>) -> Void)?

    var isEnable: Bool { operation == WinJITRequest.Operation.enable.rawValue }

    init(extension found: AnyObject, operation: String,
         completion: @escaping (Result<WinJITRequest.Response, Error>) -> Void) {
        self.extension = found
        self.shim = unsafeBitCast(found, to: NSExtensionShim.self)
        self.operation = operation
        self.completion = completion
    }

    func begin(data: Data, identifier: String, started: @escaping () -> Void) {
        // The blocks can arrive on any queue; everything below runs on the main thread.
        shim.setRequestCompletionBlock { [weak self] _, items in
            let info = (items?.first as? NSExtensionItem)?.userInfo
            let payload = info?[WinJITRequest.Response.itemKey] as? Data
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.returned(payload) } }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let message = error?.localizedDescription ?? "the request was cancelled"
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(5, L("JIT 助手停止了：", "The JIT helper stopped: ") + message)))
            } }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(6, L("JIT 助手意外退出了，请重试。", "The JIT helper stopped unexpectedly. Try again."))))
            } }
        }
        let item = NSExtensionItem()
        item.userInfo = [WinJITRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] uuid in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                guard let uuid else {
                    self.end(.failure(Self.error(7, L("JIT 助手没能启动。请重新安装 Apple VM；如果签名工具问起，选择保留 App 扩展。",
                                                      "The JIT helper did not start. Reinstall Apple VM, and keep its app extensions if your signing tool asks."))))
                    return
                }
                jitLog("helper \(self.operation): started \(identifier) as pid \(self.shim.pid(forRequestIdentifier: uuid))")
                started()
            } }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload,
              let response = try? JSONDecoder().decode(WinJITRequest.Response.self, from: payload) else {
            end(.failure(Self.error(8, L("JIT 助手结束了，但没有回复。", "The JIT helper finished without an answer."))))
            return
        }
        jitLog("helper \(operation): finished success=\(response.success ? 1 : 0)")
        end(.success(response))
    }

    private func end(_ result: Result<WinJITRequest.Response, Error>) {
        guard let completion else { return }   // the first result counts
        self.completion = nil
        if case .failure(let error) = result {
            jitLog("helper \(operation): \(error.localizedDescription)")
        }
        WinBuiltInJIT.finished(self)
        completion(result)
    }

    nonisolated static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "WinBuiltInJIT", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Entitlements

/// What this install was actually signed with (SecTask SPI, as in StikJIT's INTEGRATION.md): the
/// entitlements file is only a request, and a signing tool can drop get-task-allow.
enum TaskEntitlements {
    private typealias CreateFromSelf = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CopyValue = @convention(c) (CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFTypeRef>?

    /// nil when the SecTask functions are not there to ask.
    static func value(_ name: String) -> Bool? {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let create = dlsym(handle, "SecTaskCreateFromSelf"),
              let copy = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return nil }
        guard let task = unsafeBitCast(create, to: CreateFromSelf.self)(nil)?.takeRetainedValue() else { return nil }
        let value = unsafeBitCast(copy, to: CopyValue.self)(task, name as CFString, nil)?.takeRetainedValue()
        return (value as? NSNumber)?.boolValue ?? false
    }

    static let getTaskAllow: Bool? = value("get-task-allow")
}

// MARK: - Pairing file

/// Where Built-in JIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by the app on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer, or from StikDebug's.
    case imported
}

/// The RPPairing file Built-in JIT authenticates with. Lives in Documents/StikJIT, so it can also be
/// dropped in through Finder file sharing. It is device-sensitive and only ever sent to the app's
/// own helper process.
enum JITPairingFileStore {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("pairingFile.plist") }
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private static let sourceKey = "winios.jit.pairingSource"

    static var source: JITPairingSource? {
        guard exists else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data { try Data(contentsOf: url) }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "WinBuiltInJIT", code: 10, userInfo: [NSLocalizedDescriptionKey:
                L("这不是 RemotePairing 配对文件（RPPairing）。请按 docs/builtin-jit.md 生成后再导入。",
                  "That is not a remote pairing (RPPairing) file. Make one as docs/builtin-jit.md describes and try again.")])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.removeObject(forKey: sourceKey)
    }
}

// MARK: - RemotePairing port

/// The device advertises RemotePairing on a port it picks at boot, while StikJIT defaults to the old
/// fixed 49152. Find the advertised port so Built-in JIT keeps working after the device restarts.
/// nil lets the helper look it up itself (RSDPortResolver, then a port scan).
enum RemotePairingPortDiscovery {
    private static let serviceType = "_remotepairing._tcp"
    /// Runs discover(), which blocks it until a port is found or the timeout passes.
    private static let queue = DispatchQueue(label: "applevm.remotepairing-discovery", qos: .utility)
    /// The browser's and the connection's handlers. Not `queue`: discover() blocks that one, and the
    /// handlers would only run after the wait had timed out.
    private static let eventQueue = DispatchQueue(label: "applevm.remotepairing-discovery.events", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPort: UInt16?
    nonisolated(unsafe) private static var lastFailure: Date?

    /// Forget the port, e.g. after a failure that may mean the device rebooted.
    static func invalidate() {
        lock.lock()
        cachedPort = nil
        lastFailure = nil
        lock.unlock()
    }

    /// Calls back on the main thread.
    static func resolve(timeout: TimeInterval = 3, completion: @escaping @MainActor (UInt16?) -> Void) {
        lock.lock()
        if let cachedPort {
            lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(cachedPort) } }
            return
        }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 30 {
            lock.unlock()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
            return
        }
        lock.unlock()

        queue.async {
            let port = discover(timeout: timeout)
            lock.lock()
            if let port {
                cachedPort = port
                lastFailure = nil
            } else {
                lastFailure = Date()
            }
            lock.unlock()
            jitLog("RemotePairing port " + (port.map { String($0) } ?? "not found; the helper looks it up"))
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(port) } }
        }
    }

    private static func discover(timeout: TimeInterval) -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var finished = false
        var resolvedPort: UInt16?
        var pendingConnection: NWConnection?

        func finish(_ port: UInt16?) {
            resultLock.lock()
            if !finished {
                finished = true
                resolvedPort = port
                semaphore.signal()
            }
            resultLock.unlock()
        }

        func hasFinished() -> Bool {
            resultLock.lock()
            defer { resultLock.unlock() }
            return finished
        }

        browser.browseResultsChangedHandler = { results, _ in
            guard !hasFinished() else { return }
            let preferred = results.first { result in
                result.interfaces.contains { $0.name == "lo0" }
            } ?? results.first
            guard let result = preferred, case .service = result.endpoint else { return }

            resultLock.lock()
            let alreadyConnecting = pendingConnection != nil
            if !alreadyConnecting {
                pendingConnection = NWConnection(to: result.endpoint, using: parameters)
            }
            let connection = pendingConnection
            resultLock.unlock()
            guard !alreadyConnecting, let connection else { return }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(_, let port) = remoteEndpoint {
                        finish(port.rawValue)
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: eventQueue)
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }

        browser.start(queue: eventQueue)
        _ = semaphore.wait(timeout: .now() + timeout)
        browser.cancel()
        resultLock.lock()
        let connectionToCancel = pendingConnection
        resultLock.unlock()
        connectionToCancel?.cancel()

        resultLock.lock()
        defer { resultLock.unlock() }
        return resolvedPort
    }
}

// MARK: - Network advice and retries

/// The network path in use: the helper reaches this device through LocalDevVPN, but iOS may send
/// that connection over cellular instead; which network is in use decides the advice and the retries.
enum JITNetworkSituation: Equatable {
    case wifi
    case cellularOnly
    case wired
    case offline

    init(_ path: NWPath) {
        if path.status != .satisfied {
            self = .offline
        } else if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            self = .wired
        } else {
            // A satisfied path with no known interface type keeps the plain VPN advice.
            self = path.usesInterfaceType(.cellular) ? .cellularOnly : .wifi
        }
    }
}

/// Why the helper could not reach this device, read from its error text.
enum JITConnectionProblem: Equatable {
    /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing, or iOS sent the
    /// connection elsewhere.
    case unreachable
    /// The device closed the connection, usually because it no longer accepts this pairing (every
    /// new pairing for the same host replaces the last).
    case pairing

    init?(helperMessage: String) {
        let text = helperMessage.lowercased()
        let has = { (needles: [String]) in needles.contains(where: text.contains) }
        if has(["connectionreset", "connection reset", "device refused connection"]) {
            self = .pairing
        } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                       "networkunreachable", "network unreachable", "hostunreachable",
                       "host unreachable", "no route"]) {
            self = .unreachable
        } else {
            return nil
        }
    }

    /// What to tell the user for this problem on this network.
    func advice(_ situation: JITNetworkSituation) -> String {
        if self == .pairing {
            return L("本机断开了连接，通常是因为它不再接受 Apple VM 的配对。请重新配对，并确认 LocalDevVPN 已连接。",
                     "This device closed the connection, which usually means it no longer accepts Apple VM's pairing. Pair again, and check that LocalDevVPN is connected.")
        }
        guard situation == .cellularOnly else {
            return L("连不上本机。请连接 LocalDevVPN，然后重试。",
                     "Apple VM couldn't reach this device. Connect LocalDevVPN, then try again.")
        }
        return L("LocalDevVPN 显示已连接，但 iOS 仍可能把连接走蜂窝网络。在控制中心关掉蜂窝数据，等 2 秒再打开；或者连一次任意 Wi-Fi（个人热点也行）。保持 LocalDevVPN 连接，关掉 Tailscale 等其他 VPN，然后重试。",
                 "LocalDevVPN can show Connected while iOS still sends the connection over cellular. Turn Cellular Data off in Control Center, wait 2 seconds, then turn it back on. Or join any Wi-Fi once; a hotspot works. Keep LocalDevVPN connected, turn off other VPNs such as Tailscale, then try again.")
    }
}

/// On cellular, iOS tends to send the first connection to 10.7.0.1 out over the mobile network
/// instead of through LocalDevVPN, and later ones go through. So an unreachable error on cellular is
/// retried: at most 3 attempts in all, 4 seconds apart.
enum JITRetryPolicy {
    static let maxAttempts = 3

    /// Seconds to wait before the next attempt, or nil to give up.
    static func retryDelay(situation: JITNetworkSituation, problem: JITConnectionProblem, attempt: Int) -> TimeInterval? {
        guard situation == .cellularOnly, problem == .unreachable, attempt < maxAttempts else { return nil }
        return 4
    }

    static func statusText(nextAttempt: Int) -> String {
        L("正在通过 LocalDevVPN 重试（第 \(nextAttempt)/\(maxAttempts) 次）…",
          "Retrying over LocalDevVPN (\(nextAttempt) of \(maxAttempts))…")
    }
}
