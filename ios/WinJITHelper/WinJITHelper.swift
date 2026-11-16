// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: ios/HengeJITHelper/HengeJITHelper.swift.
// The debugger itself is StikJIT 1.9.0 (MPL-2.0, StikDebug/StikJIT, with ios/patches/stikjit-high-address.patch
// and stikjit-ipv6-address.patch), linked from the app's Frameworks/StikJIT.framework.
import Foundation
import StikJIT

/// The debugger half of Built-in JIT (docs/builtin-jit.md).
///
/// A process cannot debug itself, so Apple VM starts this extension and sends it its PID, the
/// pairing file and henge-jit.js. StikJIT attaches over LocalDevVPN (or the user's own VPN, at the
/// address the request gives) and answers the script's trap requests (brk #0x69 for the JIT region
/// and guest RAM, brk #0xf00d with x16=0 to detach) until winios_jit.c asks it to let go.
private enum WinJITWork {
    /// One request at a time: enabling JIT holds this queue while the debugger is attached.
    static let queue = DispatchQueue(label: "applevm.jit-helper")

    static func handle(_ request: WinJITRequest) -> WinJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        var configuration = StikJIT.Configuration.default
        /// The user's own VPN instead of LocalDevVPN: the device is reached at an address that VPN routes
        /// back to it (docs/builtin-jit.md). Logged by family and stage, never the address or the pairing.
        let ownVPN = request.deviceAddress != nil && request.operation != .resetDDI
        if ownVPN, let address = request.deviceAddress {
            guard JITDeviceAddress.normalized(address) == address else {
                return .init(success: false, message: "The device address for your VPN is not an IPv4 or IPv6 address.",
                             txmPresent: StikJIT.isTXMPresent, connection: .cannotConnect)
            }
            configuration.deviceAddress = address
            // A round trip through the VPN's server, not a hairpin inside the device.
            configuration.connectionTimeout = 10
        }
        if request.operation != .resetDDI {
            NSLog("[WinJITHelper] %@: device address %@ (%@)", request.operation.rawValue,
                  JITDeviceAddress.family(configuration.deviceAddress), ownVPN ? "your VPN" : "LocalDevVPN")
        }
        /// Appended to the reply so the app's log shows how the port was chosen.
        var portNote = ""
        var needsScan = false
        if let rsdPort = request.rsdPort {
            configuration.rsdPort = rsdPort
        } else if request.operation != .resetDDI {
            // The app found no advertised port. StikJIT's 49152 is closed when the device picked another at boot.
            let lookup = RSDPortResolver.resolve()
            NSLog("[WinJITHelper] RemotePairing port: %@", lookup.detail)
            if let port = lookup.port { configuration.rsdPort = port } else { needsScan = true }
            portNote = " [helper port lookup: \(lookup.detail); using \(configuration.rsdPort)]"
        }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "Developer Disk Image cache reset.",
                             txmPresent: StikJIT.isTXMPresent)
            }

            if request.operation == .testConnection, request.pairingData?.isEmpty ?? true {
                return testWithoutPairing(configuration: configuration, needsScan: needsScan, ownVPN: ownVPN,
                                          portNote: portNote)
            }
            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "WinJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            removeStalePairingFiles(in: root)
            let pairingURL = root.appendingPathComponent(
                "\(pairingFilePrefix)\(getpid())-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            defer { try? manager.removeItem(at: pairingURL) }
            if needsScan {
                let found = findRSDPort(pairingFile: pairingURL, base: configuration, ownVPN: ownVPN)
                if let port = found.port {
                    configuration.rsdPort = port
                    portNote += " [port scan: using \(port)]"
                } else {
                    portNote += " [port scan: no RemotePairing port found]"
                    if ownVPN {
                        // No open port at all: the address does not lead back here. Open ports but none
                        // answered: they lead here, but RemotePairing did not answer on any of them.
                        return .init(success: false,
                                     message: (found.openPorts == 0
                                        ? "No port in 49152-65535 is open at the device address through your VPN."
                                        : "\(found.openPorts) port(s) are open at the device address, but none answered as RemotePairing.")
                                        + portNote,
                                     txmPresent: StikJIT.isTXMPresent,
                                     connection: found.openPorts == 0 ? .cannotConnect : .noAnswer)
                    }
                }
            }

            // Through the user's VPN, first make sure RemotePairing answers there at all: once the TCP
            // connection is up, idevice waits for its answer with no timeout of its own, so a device that
            // never answers would hold Prepare or Enable forever. Test connection is this check alone.
            if ownVPN || request.operation == .testConnection {
                let check = checkRemotePairing(pairingFile: pairingURL, configuration: configuration)
                if request.operation == .testConnection || check.result != .ok {
                    return .init(success: check.result == .ok, message: check.detail + portNote,
                                 txmPresent: StikJIT.isTXMPresent, connection: check.result)
                }
            }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths, configuration: configuration,
                    progress: { NSLog("[WinJITHelper] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    let route = ownVPN ? "This device answers through your VPN" : "LocalDevVPN is reachable"
                    return .init(success: true,
                                 message: route + " and the Developer Disk Image is ready." + portNote,
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason + portNote, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64, !scriptBase64.isEmpty else {
                    throw NSError(domain: "WinJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "The target process or Apple VM's JIT script was not provided."])
                }
                // henge-jit.js, forced: it answers the brk #0x69 / #0xf00d requests winios_jit.c makes.
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    configuration: configuration,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: { NSLog("[WinJITHelper] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[WinJITHelper] %@", $0) })
                return .init(success: true, message: "Apple VM detached cleanly from its built-in JIT helper." + portNote,
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI, .testConnection:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription + portNote,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }

    /// Each request's copy of the pairing file is "pairingFile-<helper pid>-<UUID>.plist".
    private static let pairingFilePrefix = "pairingFile-"

    /// A request removes its copy of the pairing file (it holds the device's pairing key) when it ends,
    /// but not when the helper dies first: Apple VM closed or crashed while the helper was attaching, or
    /// iOS reclaimed the suspended extension. Such leftovers are removed here: every copy from this
    /// process (requests in it run one at a time, so none is in use) or from one that has exited, and
    /// any without a pid (from before copies had one). Copies of a helper still running are kept.
    private static func removeStalePairingFiles(in root: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        let me = getpid()
        for name in names where name.hasPrefix(pairingFilePrefix) && name.hasSuffix(".plist") {
            let rest = name.dropFirst(pairingFilePrefix.count)
            if let dash = rest.firstIndex(of: "-"), let pid = pid_t(rest[..<dash]), pid != me,
               kill(pid, 0) == 0 || errno == EPERM {
                continue
            }
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private static let lastPortKey = "applevm.lastRSDPort"

    /// The last port that worked, then every open port in iOS's range, each probed with a real StikJIT call.
    /// The port changes at each reboot of the device, so a stale remembered one just falls through to the scan.
    /// Through the user's VPN a closed port answers only after a round trip to its server, so each batch
    /// of the scan waits longer, and each probe has a deadline (checkRemotePairing).
    private static func findRSDPort(pairingFile: URL, base: StikJIT.Configuration,
                                    ownVPN: Bool) -> (port: UInt16?, openPorts: Int) {
        func works(_ port: UInt16) -> Bool {
            var probe = base
            probe.rsdPort = port
            if ownVPN {
                return checkRemotePairing(pairingFile: pairingFile, configuration: probe, timeout: 8).result == .ok
            }
            probe.connectionTimeout = 2
            return (try? StikJIT.isDDIMounted(pairingFile: pairingFile, configuration: probe)) != nil
        }
        let last = UInt16(exactly: UserDefaults.standard.integer(forKey: lastPortKey)) ?? 0
        if last != 0, works(last) { return (last, 1) }
        let open = ownVPN ? RSDPortScanner.openPorts(host: base.deviceAddress, waitMs: 700)
                          : RSDPortScanner.openPorts(host: base.deviceAddress)
        NSLog("[WinJITHelper] open ports: %@", open.map(String.init).joined(separator: ","))
        guard let port = open.first(where: works) else { return (nil, open.count) }
        UserDefaults.standard.set(Int(port), forKey: lastPortKey)
        return (port, open.count)
    }

    // MARK: Checking the device address (the user's VPN, and Test connection)

    struct Check {
        var result: WinJITRequest.ConnectionCheck
        /// For the app's log and the setup's Test result.
        var detail: String
    }

    /// Stage by stage: a TCP connection to RemotePairing's port, then a RemotePairing session (StikJIT's
    /// Developer Disk Image query: pair-verify, the tunnel, RSD) with a deadline. A failure says which
    /// stage it was: cannot connect, connected but no answer, or answered and then failed.
    private static func checkRemotePairing(pairingFile: URL, configuration: StikJIT.Configuration,
                                           timeout: TimeInterval = 20) -> Check {
        let family = JITDeviceAddress.family(configuration.deviceAddress)
        let port = configuration.rsdPort
        NSLog("[WinJITHelper] stage: TCP connect (%@, port %u)", family, UInt32(port))
        let tcp = RSDPortScanner.connect(host: configuration.deviceAddress, port: port,
                                         timeoutMs: Int32(configuration.connectionTimeout * 1000))
        NSLog("[WinJITHelper] stage: TCP connect: %@", tcp.description)
        guard tcp == .open else {
            return Check(result: .cannotConnect,
                         detail: "Cannot connect to this device at its \(family) address, port \(port): \(tcp).")
        }
        NSLog("[WinJITHelper] stage: RemotePairing session (deadline %d s)", Int(timeout))
        switch StikJITCall.run(timeout: timeout, {
            try StikJIT.isDDIMounted(pairingFile: pairingFile, configuration: configuration)
        }) {
        case .returned(let mounted):
            NSLog("[WinJITHelper] stage: RemotePairing answered (DDI %@)", mounted ? "mounted" : "not mounted")
            return Check(result: .ok, detail: "Connected to port \(port) and RemotePairing answered"
                         + " (Developer Disk Image \(mounted ? "mounted" : "not mounted yet")).")
        case .threw(let message):
            NSLog("[WinJITHelper] stage: RemotePairing failed: %@", message)
            // idevice reports its own connects as InternalError("connect: ...") for RemotePairing's port
            // and ("TLS tunnel: ...") for the tunnel port RemotePairing opens once it has answered.
            if message.contains("TLS tunnel") {
                return Check(result: .remotePairingFailed,
                             detail: "Connected to port \(port) and RemotePairing answered, but the tunnel port it opened could not be reached at the same address: \(message)")
            }
            if message.contains("connect:") {
                return Check(result: .cannotConnect,
                             detail: "Cannot connect to this device at its \(family) address, port \(port): \(message)")
            }
            return Check(result: .remotePairingFailed,
                         detail: "Connected to port \(port), but the RemotePairing session failed: \(message)")
        case .timedOut:
            NSLog("[WinJITHelper] stage: RemotePairing did not answer within %d s", Int(timeout))
            return Check(result: .noAnswer,
                         detail: "Connected to port \(port), but RemotePairing did not answer within \(Int(timeout)) s.")
        }
    }

    /// Test connection without a pairing file: only the TCP connection (to any open port in iOS's range
    /// when the port is not known; which of them is RemotePairing takes the pairing to tell).
    private static func testWithoutPairing(configuration: StikJIT.Configuration, needsScan: Bool, ownVPN: Bool,
                                           portNote: String) -> WinJITRequest.Response {
        let family = JITDeviceAddress.family(configuration.deviceAddress)
        if needsScan {
            NSLog("[WinJITHelper] stage: scanning for open ports (%@)", family)
            let open = ownVPN ? RSDPortScanner.openPorts(host: configuration.deviceAddress, waitMs: 700)
                              : RSDPortScanner.openPorts(host: configuration.deviceAddress)
            NSLog("[WinJITHelper] stage: %d open port(s)", open.count)
            return .init(success: !open.isEmpty,
                         message: open.isEmpty
                            ? "No open port in 49152-65535 at this device's \(family) address." + portNote
                            : "\(open.count) open port(s) at this device's \(family) address; pair to check which is RemotePairing." + portNote,
                         txmPresent: StikJIT.isTXMPresent, connection: open.isEmpty ? .cannotConnect : .connected)
        }
        let port = configuration.rsdPort
        NSLog("[WinJITHelper] stage: TCP connect (%@, port %u)", family, UInt32(port))
        let tcp = RSDPortScanner.connect(host: configuration.deviceAddress, port: port,
                                         timeoutMs: Int32(configuration.connectionTimeout * 1000))
        NSLog("[WinJITHelper] stage: TCP connect: %@", tcp.description)
        return .init(success: tcp == .open,
                     message: tcp == .open
                        ? "Connected to port \(port) at this device's \(family) address; pair to check that RemotePairing answers." + portNote
                        : "Cannot connect to this device at its \(family) address, port \(port): \(tcp)." + portNote,
                     txmPresent: StikJIT.isTXMPresent, connection: tcp == .open ? .connected : .cannotConnect)
    }
}

/// A StikJIT call with a deadline. It runs on a thread of its own: when the deadline passes, that thread
/// is left behind, blocked in idevice until the connection drops, and the request goes on without it
/// (idevice's runtime serves callers on several threads at once).
private enum StikJITCall {
    enum Outcome<T> {
        case returned(T)
        case threw(String)
        case timedOut
    }

    private final class Box<T>: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stored: Outcome<T>?

        func finish(_ outcome: Outcome<T>) {
            lock.lock()
            stored = outcome
            lock.unlock()
            done.signal()
        }

        var outcome: Outcome<T>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    static func run<T>(timeout: TimeInterval, _ call: @escaping @Sendable () throws -> T) -> Outcome<T> {
        let box = Box<T>()
        let thread = Thread {
            do { box.finish(.returned(try call())) } catch { box.finish(.threw(error.localizedDescription)) }
        }
        thread.name = "applevm.jit-helper.check"
        thread.start()
        guard box.done.wait(timeout: .now() + timeout) == .success, let outcome = box.outcome else { return .timedOut }
        return outcome
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the first input item; the
/// response goes back as JSON in the item the request completes with. Enable completes only once
/// the JIT script has detached, so the request, and this process, last as long as the debugger does.
@objc(WinJITHelperHandler)
final class WinJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[WinJITRequest.itemKey] as? Data
        WinJITWork.queue.async {
            let response: WinJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(WinJITRequest.self, from: data) {
                response = WinJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Apple VM's JIT helper received no request.",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [WinJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
