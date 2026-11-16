// SPDX-License-Identifier: GPL-2.0-or-later
//
// PLACEHOLDER (feat/chrome): Settings > Network mounts PortForwardingSection(), which the port
// forwarding work defines. Until it is on this branch, this stand-in keeps the app building.
// DELETE THIS FILE when the real PortForwardingSection is merged (the type would be defined twice).
import SwiftUI

struct PortForwardingSection: View {
    var body: some View {
        Section {
            Text(L("端口转发的设置还没有装进这个版本。", "Port forwarding settings are not in this build yet."))
                .foregroundStyle(.secondary)
        } header: {
            Text(L("端口转发", "Port forwarding"))
        }
    }
}
