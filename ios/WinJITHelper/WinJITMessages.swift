// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: ios/HengeJITHelper/HengeJITMessages.swift.
import Foundation
import Darwin

/// Codable messages shared by Apple VM and its JIT helper extension (WinJITHelper.appex). Compiled
/// into both targets. Each travels as JSON in an extension request's item (userInfo[itemKey]), to
/// the helper and back.
struct WinJITRequest: Codable, Sendable {
    static let itemKey = "applevm-jit-request"

    enum Operation: String, Codable, Sendable {
        /// Check the connection (LocalDevVPN or the user's VPN) and download, mount and verify the
        /// Developer Disk Image.
        case prepare
        /// Attach to `targetPID` and run the JIT script until it detaches.
        case enable
        case resetDDI
        /// Connect to RemotePairing at the device address and, with a pairing file, check that it answers.
        case testConnection
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?
    /// The port the device is currently advertising for RemotePairing. iOS picks a new one when it
    /// boots; nil lets the helper look it up itself.
    let rsdPort: UInt16?
    /// Where the helper reaches this device: an address the user's own VPN routes back to it
    /// (JITDeviceAddress.normalized). nil: LocalDevVPN's 10.7.0.1, StikJIT's default. Absent from
    /// the JSON when nil, so a LocalDevVPN request is the same as before the setting existed.
    var deviceAddress: String? = nil

    static func prepare(pairingData: Data, rsdPort: UInt16? = nil, deviceAddress: String? = nil) -> WinJITRequest {
        WinJITRequest(operation: .prepare, targetPID: nil,
                      pairingData: pairingData, scriptBase64: nil, rsdPort: rsdPort,
                      deviceAddress: deviceAddress)
    }

    static func enable(targetPID: Int32, pairingData: Data,
                       scriptBase64: String, rsdPort: UInt16? = nil, deviceAddress: String? = nil) -> WinJITRequest {
        WinJITRequest(operation: .enable, targetPID: targetPID,
                      pairingData: pairingData, scriptBase64: scriptBase64, rsdPort: rsdPort,
                      deviceAddress: deviceAddress)
    }

    static var resetDDI: WinJITRequest {
        WinJITRequest(operation: .resetDDI, targetPID: nil,
                      pairingData: nil, scriptBase64: nil, rsdPort: nil)
    }

    /// `pairingData` nil: only the TCP connection is tried.
    static func testConnection(pairingData: Data?, rsdPort: UInt16?, deviceAddress: String?) -> WinJITRequest {
        WinJITRequest(operation: .testConnection, targetPID: nil,
                      pairingData: pairingData, scriptBase64: nil, rsdPort: rsdPort,
                      deviceAddress: deviceAddress)
    }

    /// How far the helper got with the device address, when it checked (the user's VPN, and Test).
    enum ConnectionCheck: String, Codable, Sendable {
        /// No TCP connection to RemotePairing's port at the address (or no open port was found there).
        case cannotConnect
        /// Connected, but RemotePairing never answered: iOS may not answer on the VPN's interface, or
        /// the port is another service.
        case noAnswer
        /// Connected and RemotePairing answered, but the session failed (pairing refused, the tunnel's
        /// second port not reachable through the VPN, ...): the message says how.
        case remotePairingFailed
        /// Connected; RemotePairing was not tried (no pairing file).
        case connected
        /// RemotePairing answered and a session over it worked.
        case ok
    }

    struct Response: Codable, Sendable {
        static let itemKey = "applevm-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
        /// Set when the helper checked the device address itself (see ConnectionCheck).
        var connection: ConnectionCheck? = nil
    }
}

/// The device address for the user's own VPN: a numeric IPv4 or IPv6 address, as typed (with or
/// without [brackets] and spaces around it) and in its canonical form (inet_ntop), which is what the
/// helper is sent. Compiled into the app and the helper.
enum JITDeviceAddress {
    /// LocalDevVPN routes this to the device; StikJIT's default.
    static let localDevVPN = "10.7.0.1"

    /// The canonical form of `text`, or nil when it is not an IPv4 or IPv6 address. No host names,
    /// no ports, no IPv6 scope (%en0).
    static func normalized(_ text: String) -> String? {
        var literal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if literal.hasPrefix("["), literal.hasSuffix("]") {
            literal = String(literal.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        // Darwin's inet_pton takes "fe80::1%en0" and folds the scope into the address bytes.
        guard !literal.isEmpty, !literal.contains("%") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
        return nil
    }

    /// "IPv4" or "IPv6", for logs: the helper logs the family, not the address.
    static func family(_ address: String) -> String {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return "IPv4" }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return "IPv6" }
        return "invalid"
    }
}
