// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

@main
struct WindowsiOSApp: App {
    // the background test's lifecycle observers must be registered before anything else's (the bridge, made by
    // VMViewModel's stored properties, and Picture in Picture): NotificationCenter calls them in that order
    init() { _ = BackgroundTest.shared }
    @StateObject private var viewModel = VMViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SessionView(vm: viewModel)
                .preferredColorScheme(.dark)
                .onAppear {
                    viewModel.onAppBecameActive()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        viewModel.onAppBecameActive()
                    } else if newPhase == .background {
                        WinIOSBridge.shared.flushDisks()
                    }
                }
        }
    }
}
