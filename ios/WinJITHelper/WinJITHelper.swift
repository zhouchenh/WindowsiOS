// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: ios/HengeJITHelper/HengeJITHelper.swift.
// The debugger itself is StikJIT 1.9.0 (MPL-2.0, StikDebug/StikJIT, with ios/patches/stikjit-high-address.patch),
// linked from the app's Frameworks/StikJIT.framework.
import Foundation
import StikJIT

/// The debugger half of Built-in JIT (docs/builtin-jit.md).
///
/// A process cannot debug itself, so Apple VM starts this extension and sends it its PID, the
/// pairing file and henge-jit.js. StikJIT attaches over LocalDevVPN and answers the script's trap
/// requests (brk #0x69 for the JIT region and guest RAM, brk #0xf00d with x16=0 to detach) until
/// winios_jit.c asks it to let go.
private enum WinJITWork {
    /// One request at a time: enabling JIT holds this queue while the debugger is attached.
    static let queue = DispatchQueue(label: "applevm.jit-helper")

    static func handle(_ request: WinJITRequest) -> WinJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        var configuration = StikJIT.Configuration.default
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
                if let port = findRSDPort(pairingFile: pairingURL, base: configuration) {
                    configuration.rsdPort = port
                    portNote += " [port scan: using \(port)]"
                } else {
                    portNote += " [port scan: no RemotePairing port found]"
                }
            }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths, configuration: configuration,
                    progress: { NSLog("[WinJITHelper] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready." + portNote,
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
            case .resetDDI:
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
    private static func findRSDPort(pairingFile: URL, base: StikJIT.Configuration) -> UInt16? {
        func works(_ port: UInt16) -> Bool {
            var probe = base
            probe.rsdPort = port
            probe.connectionTimeout = 2
            return (try? StikJIT.isDDIMounted(pairingFile: pairingFile, configuration: probe)) != nil
        }
        let last = UInt16(exactly: UserDefaults.standard.integer(forKey: lastPortKey)) ?? 0
        if last != 0, works(last) { return last }
        let open = RSDPortScanner.openPorts(host: base.deviceAddress)
        NSLog("[WinJITHelper] open ports: %@", open.map(String.init).joined(separator: ","))
        guard let port = open.first(where: works) else { return nil }
        UserDefaults.standard.set(Int(port), forKey: lastPortKey)
        return port
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
