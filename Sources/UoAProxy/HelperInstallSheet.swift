import SwiftUI

struct HelperInstallSheet: View {
    @EnvironmentObject private var vpn: VPNManager
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install VPN helper").font(.title2.weight(.semibold))
            Text("The VPN needs administrator access to configure the network. UoA Proxy will install a restricted helper for this connection. Disconnect UoA Proxy before installing.")
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS will ask you to authorize the installation.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }.disabled(busy)
                Spacer()
                Button(busy ? "Installing…" : "Install") {
                    busy = true
                    error = nil
                    Task {
                        error = await vpn.installHelper()
                        busy = false
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
