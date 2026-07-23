import Foundation

/// Non-secret VPN settings (shared via Application Support JSON).
public struct VPNConfig: Codable, Equatable, Sendable {
    public var username: String
    public var server: String
    public var openconnectPath: String
    public var protocolName: String

    public static let defaults = VPNConfig(
        username: "",
        server: "connectvpn.auckland.ac.nz/client",
        openconnectPath: Self.detectOpenconnectPath(),
        protocolName: "fortinet"
    )

    public init(
        username: String,
        server: String,
        openconnectPath: String,
        protocolName: String
    ) {
        self.username = username
        self.server = server
        self.openconnectPath = openconnectPath
        self.protocolName = protocolName
    }

    public static func load() -> VPNConfig {
        let url = AppPaths.configFileURL
        if let data = try? Data(contentsOf: url),
           var config = try? JSONDecoder().decode(VPNConfig.self, from: data) {
            config.server = Self.defaults.server
            config.protocolName = Self.defaults.protocolName
            return config
        }

        // One-time migration from early menu-bar-only UserDefaults.
        let defaults = UserDefaults.standard
        var config = VPNConfig.defaults
        if let username = defaults.string(forKey: "username") {
            config.username = username
        }
        if let path = defaults.string(forKey: "openconnectPath"), !path.isEmpty {
            config.openconnectPath = path
        }
        config.save()
        return config
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var normalized = self
        normalized.server = Self.defaults.server
        normalized.protocolName = Self.defaults.protocolName
        guard let data = try? encoder.encode(normalized) else { return }
        try? data.write(to: AppPaths.configFileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.configFileURL.path
        )
    }

    public static func detectOpenconnectPath() -> String {
        let candidates = [
            "/opt/homebrew/bin/openconnect",
            "/usr/local/bin/openconnect",
            "/usr/bin/openconnect"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return candidates[0]
    }
}
