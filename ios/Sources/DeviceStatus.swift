// SPDX-License-Identifier: GPL-2.0-or-later
//
// The device's thermal state (and Low Power Mode), for display. JIT translation plus virtio-gpu 3D is a
// sustained load, and when iOS throttles the chip Windows slows down with no other sign of why.
// After Henge (Leviidev/Henge, GPL-2.0-or-later), which shows ProcessInfo.thermalState in its session
// details: commit 4b1b239 (SonNX).
import Foundation
import SwiftUI

@MainActor
final class DeviceStatus: ObservableObject {
    static let shared = DeviceStatus()

    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            // Posted on whichever thread made the change.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in DeviceStatus.shared.refresh() }
            })
        }
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        if info.thermalState != thermalState {
            FileHandle.standardError.write(Data("[winios] thermal state: \(Self.name(info.thermalState))\n".utf8))
        }
        thermalState = info.thermalState
        lowPowerMode = info.isLowPowerModeEnabled
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    var thermalText: String {
        switch thermalState {
        case .nominal: return L("正常", "Nominal")
        case .fair: return L("偏热", "Fair")
        case .serious: return L("过热（已降频）", "Serious (throttled)")
        case .critical: return L("严重过热", "Critical")
        @unknown default: return L("未知", "Unknown")
        }
    }

    /// Serious and critical are when iOS slows the chip down noticeably.
    var isThrottling: Bool { thermalState == .serious || thermalState == .critical }
}

/// A row for the settings' Status section.
struct ThermalStateRow: View {
    @ObservedObject private var status = DeviceStatus.shared

    var body: some View {
        LabeledContent(L("设备温度", "Thermal state")) {
            Text(status.thermalText + (status.lowPowerMode ? L(" · 低电量模式", " · Low Power Mode") : ""))
                .foregroundStyle(status.isThrottling ? .orange : .secondary)
        }
    }
}
