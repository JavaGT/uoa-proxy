import AppKit
import SwiftUI
import UoAProxyCore

struct SettingsView: View {
    @EnvironmentObject private var vpn: VPNManager
    @State private var showSecret = false
    @State private var showPassword = false
    @State private var savedFlash = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Circle()
                        .fill(vpn.daemonConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(vpn.daemonConnected ? "Daemon connected" : "Daemon offline")
                    Spacer()
                    Button("Refresh") { vpn.refreshFromDaemon() }
                        .buttonStyle(.borderless)
                }
                LabeledContent("passwordless sudo") {
                    Text(vpn.sudoOK ? "OK" : "not configured")
                        .foregroundStyle(vpn.sudoOK ? Color.secondary : Color.orange)
                }
            } header: {
                Text("Daemon")
            } footer: {
                Text("The always-on daemon owns the VPN. Manage it with: uoa-proxy daemon status|start|stop")
            }

            Section {
                TextField("Username", text: $vpn.config.username)
                    .textContentType(.username)
                HStack {
                    if showPassword {
                        TextField(vpn.hasPassword ? "New password (leave blank to keep)" : "Password", text: $vpn.password)
                            .textContentType(.password)
                    } else {
                        SecureField(vpn.hasPassword ? "New password (leave blank to keep)" : "Password", text: $vpn.password)
                            .textContentType(.password)
                    }
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                if vpn.hasPassword {
                    Text("A password is already stored (on disk, owner-only).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            }

            Section {
                HStack {
                    if showSecret {
                        TextField(vpn.hasTOTPSecret ? "New TOTP secret (leave blank to keep)" : "TOTP secret (Base32)", text: $vpn.totpSecret)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField(vpn.hasTOTPSecret ? "New TOTP secret (leave blank to keep)" : "TOTP secret (Base32)", text: $vpn.totpSecret)
                    }
                    Button {
                        showSecret.toggle()
                    } label: {
                        Image(systemName: showSecret ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                if vpn.hasTOTPSecret {
                    LabeledContent("Current code") {
                        HStack(spacing: 8) {
                            Text(vpn.currentOTP)
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                            Text("\(vpn.otpSecondsRemaining)s")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(vpn.currentOTP, forType: .string)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("Two-factor authentication")
            } footer: {
                Text("Paste the Base32 secret from the authenticator QR (secret=…), not the 6-digit codes.")
            }

            Section {
                LabeledContent("Server", value: VPNConfig.defaults.server)
                LabeledContent("Protocol", value: VPNConfig.defaults.protocolName)
                Text("OpenConnect and its routing script are packaged with UoA Proxy and installed into a root-owned runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Connection")
            }

            Section {
                Button("Save Settings") {
                    vpn.saveSettings()
                    savedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        savedFlash = false
                    }
                }
                .keyboardShortcut(.defaultAction)

                if savedFlash {
                    Label("Saved via daemon", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                if let error = vpn.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Install passwordless sudo…") {
                    vpn.installPasswordlessSudo()
                }
            } header: {
                Text("Privileges")
            } footer: {
                Text(
                    """
                    Required for connect over SSH (no GUI password dialog). In Terminal run:
                    uoa-proxy install-sudo
                    Remove later with: sudo rm /etc/sudoers.d/uoa-proxy
                    """
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 620)
        .onAppear {
            vpn.refreshFromDaemon()
        }
    }
}
