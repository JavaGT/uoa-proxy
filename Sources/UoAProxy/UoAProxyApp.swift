import SwiftUI
import UoAProxyCore

@main
struct UoAProxyApp: App {
    @StateObject private var vpn = VPNManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(vpn)
        } label: {
            Label {
                Text("UoA VPN")
            } icon: {
                Image(systemName: statusIcon)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(vpn)
        }
    }

    private var statusIcon: String {
        if !vpn.daemonConnected {
            return "lock.slash"
        }
        switch vpn.state {
        case .connected:
            return "lock.shield.fill"
        case .connecting, .disconnecting:
            return "ellipsis.bubble"
        case .disconnected:
            return "lock.shield"
        }
    }
}
