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
    private static let deviceKeys: Set<String> = ["embed", "auth"]

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

    /// Valid leaf keys that can be set via `mn config --set`
    private static let validKeys: Set<String> = [
        "author.name", "author.url",
        "github.repo",
        "site.domain", "site.title", "site.theme",
        "embed.model",
        "auth.github_token",
    ]

    /// Section keys (groups, not leaf values)
    private static let sectionKeys: Set<String> = [
        "author", "github", "site", "embed", "auth",
    ]

    public func setValue(key: String, value: String) throws {
        // Block setting a section key directly (e.g., `mn config --set author maho`)
        if Self.sectionKeys.contains(key) {
            let children = Self.validKeys.filter { $0.hasPrefix("\(key).") }.sorted()
            throw ConfigError.sectionNotSettable(key: key, validChildren: children)
        }

        // Validate the key is known
        guard Self.validKeys.contains(key) else {
            throw ConfigError.unknownKey(key: key, validKeys: Self.validKeys.sorted())
        }

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

public enum ConfigError: Error, CustomStringConvertible {
    case sectionNotSettable(key: String, validChildren: [String])
    case unknownKey(key: String, validKeys: [String])

    public var description: String {
        switch self {
        case let .sectionNotSettable(key, children):
            let list = children.map { "  \($0)" }.joined(separator: "\n")
            return "'\(key)' is a section, not a value. Set its fields instead:\n\(list)"
        case let .unknownKey(key, validKeys):
            let list = validKeys.joined(separator: ", ")
            return "Unknown config key '\(key)'. Valid keys: \(list)"
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
