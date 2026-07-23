import AppKit
import SwiftUI
import UoAProxyCore

struct MenuBarPanel: View {
    @EnvironmentObject private var vpn: VPNManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statusSection
            if vpn.needsSetup && vpn.state == .disconnected {
                setupBanner
            }
            if vpn.hasTOTPSecret {
                otpRow
            }
            connectButton
            if !vpn.daemonConnected {
                errorBox(vpn.lastError ?? "Daemon offline — run: uoa-proxy daemon start")
            } else if let error = vpn.lastError, !error.isEmpty {
                errorBox(error)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .sheet(isPresented: $vpn.showSetupSheet) {
            SetupSheet()
                .environmentObject(vpn)
        }
    }

    private var setupBanner: some View {
        Button {
            vpn.showSetupSheet = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup needed")
                        .font(.caption.weight(.semibold))
                    Text("Tap to enter username, password, and TOTP secret.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.title2)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("UoA VPN")
                    .font(.headline)
                Text(vpn.config.server.isEmpty ? "Not configured" : vpn.config.server)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                quitApp()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit menu bar app (VPN daemon keeps running)")
            .accessibilityLabel("Quit")
        }
    }

    private var statusSection: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(vpn.daemonConnected ? vpn.state.label : "Daemon offline")
                .font(.subheadline.weight(.medium))
            Spacer()
            if !vpn.config.username.isEmpty {
                Text(vpn.config.username)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var otpRow: some View {
        HStack {
            Text("2FA code")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(vpn.currentOTP)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            Text("\(vpn.otpSecondsRemaining)s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var connectButton: some View {
        Button {
            // Connect when idle; Disconnect/Cancel while connected or connecting.
            vpn.toggle()
        } label: {
            HStack {
                if vpn.state == .connecting || vpn.state == .disconnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(vpn.actionTitle)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(vpn.state == .connected || vpn.state == .connecting ? .red : .accentColor)
        // Keep Cancel enabled while connecting; only block during disconnect/save.
        .disabled(!vpn.canAct || vpn.state == .disconnecting)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Settings…") {
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderless)

                Spacer()

                Text("CLI: uoa-proxy")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button(role: .destructive) {
                quitApp()
            } label: {
                Text("Quit menu bar app")
                    .frame(maxWidth: .infinity)
            }
            .help("Stops this UI only. The VPN daemon keeps running — use uoa-proxy disconnect to drop the VPN.")
        }
        .font(.caption)
    }

    private func quitApp() {
        // Ensure termination works for LSUIElement / menu bar extras.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.caption2)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.red.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        if !vpn.daemonConnected { return .red }
        switch vpn.state {
        case .connected: return .green
        case .connecting, .disconnecting: return .orange
        case .disconnected: return .secondary
        }
    }
}
