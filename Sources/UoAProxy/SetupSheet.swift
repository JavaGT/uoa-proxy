import AppKit
import SwiftUI
import UoAProxyCore

/// First-run / incomplete-setup form shown when Connect is pressed without full config.
struct SetupSheet: View {
    @EnvironmentObject private var vpn: VPNManager
    @Environment(\.dismiss) private var dismiss

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var totpSecret: String = ""
    @State private var showPassword = false
    @State private var showSecret = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var connectAfterSave = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up UoA VPN")
                .font(.title2.weight(.semibold))
            Text("A few details are needed before connecting. Password and TOTP secret are stored for the daemon (owner-only file).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                labeled("Username") {
                    TextField("e.g. jgra818", text: $username)
                        .textFieldStyle(.roundedBorder)
                }

                labeled(vpn.hasPassword ? "Password (leave blank to keep)" : "Password") {
                    HStack {
                        if showPassword {
                            TextField("Uni password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Uni password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                labeled(vpn.hasTOTPSecret ? "TOTP secret (leave blank to keep)" : "TOTP Base32 secret") {
                    HStack {
                        if showSecret {
                            TextField("secret= from QR", text: $totpSecret)
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("secret= from QR", text: $totpSecret)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if !vpn.sudoOK {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Passwordless sudo required")
                            .font(.subheadline.weight(.medium))
                        Text("openconnect needs root. In Terminal (works over SSH):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("uoa-proxy install-sudo")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Button("Copy command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("uoa-proxy install-sudo", forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }

            Toggle("Connect after saving", isOn: $connectAfterSave)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(busy ? "Saving…" : (connectAfterSave ? "Save & Connect" : "Save")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            username = vpn.config.username
        }
    }

    private var canSave: Bool {
        let userOK = !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let passOK = vpn.hasPassword || !password.isEmpty
        let totpOK = vpn.hasTOTPSecret || !totpSecret.isEmpty
        return userOK && passOK && totpOK
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        busy = true
        errorText = nil
        vpn.config.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.isEmpty {
            vpn.password = password
        }
        if !totpSecret.isEmpty {
            vpn.totpSecret = totpSecret
        }
        vpn.saveSettings()
        // saveSettings is sync and updates has* flags
        busy = false
        if let err = vpn.lastError, !err.isEmpty, vpn.statusMessage != "Settings saved" {
            errorText = err
            return
        }
        // Refresh to confirm
        vpn.refreshFromDaemon()
        if !vpn.hasPassword || !vpn.hasTOTPSecret || vpn.config.username.isEmpty {
            errorText = "Still missing fields — check password / TOTP secret."
            return
        }
        if connectAfterSave {
            if !vpn.sudoOK {
                errorText = "Saved, but passwordless sudo is not configured yet.\nRun in Terminal: uoa-proxy install-sudo"
                // Don't dismiss so they see the message; still allow dismiss
                return
            }
            dismiss()
            vpn.connect()
        } else {
            dismiss()
        }
    }
}
