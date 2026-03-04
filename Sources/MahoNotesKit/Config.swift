import Foundation
import Yams

/// Load and manage vault + device configuration
public struct Config: Sendable {
    public let vaultPath: String

    public init(vaultPath: String) {
        self.vaultPath = vaultPath
    }

    private var mahoYamlPath: String {
        (vaultPath as NSString).appendingPathComponent("maho.yaml")
    }

    private var deviceConfigPath: String {
        let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
        return (mahoDir as NSString).appendingPathComponent("config.yaml")
    }

    /// Device-level keys live under .maho/config.yaml
    private static let deviceKeys: Set<String> = ["embed"]

    public func loadVaultConfig() throws -> [String: Any] {
        let path = mahoYamlPath
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return (try Yams.load(yaml: content) as? [String: Any]) ?? [:]
    }

    public func loadDeviceConfig() throws -> [String: Any] {
        let path = deviceConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return (try Yams.load(yaml: content) as? [String: Any]) ?? [:]
    }

    public func setValue(key: String, value: String) throws {
        let topKey = key.split(separator: ".").first.map(String.init) ?? key
        let isDevice = Self.deviceKeys.contains(topKey)

        if isDevice {
            var config = try loadDeviceConfig()
            setNestedValue(&config, keyPath: key, value: value)
            let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
            try FileManager.default.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
            try Yams.dump(object: config).write(toFile: deviceConfigPath, atomically: true, encoding: .utf8)
        } else {
            var config = try loadVaultConfig()
            setNestedValue(&config, keyPath: key, value: value)
            try Yams.dump(object: config).write(toFile: mahoYamlPath, atomically: true, encoding: .utf8)
        }
    }
}

private func setNestedValue(_ dict: inout [String: Any], keyPath: String, value: String) {
    let parts = keyPath.split(separator: ".").map(String.init)
    if parts.count == 1 {
        dict[parts[0]] = value
    } else {
        var nested = dict[parts[0]] as? [String: Any] ?? [:]
        let subKey = parts.dropFirst().joined(separator: ".")
        setNestedValue(&nested, keyPath: subKey, value: value)
        dict[parts[0]] = nested
    }
}
