// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from Henge (Leviidev/Henge, GPL-2.0-or-later) at 7b55730: ios/HengeJITHelper/HengeJITMessages.swift.
import Foundation

/// Codable messages shared by Apple VM and its JIT helper extension (WinJITHelper.appex). Compiled
/// into both targets. Each travels as JSON in an extension request's item (userInfo[itemKey]), to
/// the helper and back.
struct WinJITRequest: Codable, Sendable {
    static let itemKey = "applevm-jit-request"

    enum Operation: String, Codable, Sendable {
        /// Check LocalDevVPN and download, mount and verify the Developer Disk Image.
        case prepare
        /// Attach to `targetPID` and run the JIT script until it detaches.
        case enable
        case resetDDI
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let scriptBase64: String?
    /// The port the device is currently advertising for RemotePairing. iOS picks a new one when it
    /// boots; nil lets the helper look it up itself.
    let rsdPort: UInt16?

    static func prepare(pairingData: Data, rsdPort: UInt16? = nil) -> WinJITRequest {
        WinJITRequest(operation: .prepare, targetPID: nil,
                      pairingData: pairingData, scriptBase64: nil, rsdPort: rsdPort)
    }

    static func enable(targetPID: Int32, pairingData: Data,
                       scriptBase64: String, rsdPort: UInt16? = nil) -> WinJITRequest {
        WinJITRequest(operation: .enable, targetPID: targetPID,
                      pairingData: pairingData, scriptBase64: scriptBase64, rsdPort: rsdPort)
    }

    static var resetDDI: WinJITRequest {
        WinJITRequest(operation: .resetDDI, targetPID: nil,
                      pairingData: nil, scriptBase64: nil, rsdPort: nil)
    }

    struct Response: Codable, Sendable {
        static let itemKey = "applevm-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
    }
}
