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
    @State private var showHelperInstall = false
    @State private var connectWhenHelperInstalled = false

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
                        Text("VPN helper required")
                            .font(.subheadline.weight(.medium))
                        Text("Install the restricted helper to configure the VPN connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Install VPN helper…") { showHelperInstall = true }
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
                    .disabled(busy)
                Spacer()
                Button(busy ? "Saving…" : (connectAfterSave ? "Save & Connect" : "Save")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .sheet(isPresented: $showHelperInstall, onDismiss: {
            if connectWhenHelperInstalled && vpn.sudoOK {
                connectWhenHelperInstalled = false
                dismiss()
                vpn.connect()
            } else {
                connectWhenHelperInstalled = false
            }
        }) {
            HelperInstallSheet().environmentObject(vpn)
        }
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

    private func save() async {
        busy = true
        defer { busy = false }
        errorText = nil
        vpn.config.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.isEmpty {
            vpn.password = password
        }
        if !totpSecret.isEmpty {
            vpn.totpSecret = totpSecret
        }
        guard await vpn.saveSettings() else {
            errorText = vpn.lastError ?? "Could not save settings. Try again."
            return
        }
        password = ""
        totpSecret = ""
        if !vpn.hasPassword || !vpn.hasTOTPSecret || vpn.config.username.isEmpty {
            errorText = "Still missing fields — check password / TOTP secret."
            return
        }
        if connectAfterSave {
            if !vpn.sudoOK {
                connectWhenHelperInstalled = true
                showHelperInstall = true
                return
            }
            dismiss()
            vpn.connect()
        } else {
            dismiss()
        }
    }
}
