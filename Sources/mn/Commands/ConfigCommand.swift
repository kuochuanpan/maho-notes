import ArgumentParser
import Foundation
import MahoNotesKit
import Yams

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or set configuration",
        subcommands: [ConfigShowSubcommand.self, ConfigSetSubcommand.self, AuthSubcommand.self],
        defaultSubcommand: ConfigShowSubcommand.self
    )
}

// MARK: - mn config (show)

struct ConfigShowSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show all configuration"
    )

    @OptionGroup var vaultOption: VaultOption

    func run() throws {
        try vaultOption.validateVaultExists()
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
        let config = Config(vaultPath: vaultPath)

        let vaultConfig = try config.loadVaultConfig()
        let deviceConfig = try config.loadDeviceConfig()

        if !vaultConfig.isEmpty {
            print("# Vault config (maho.yaml)")
            printDict(vaultConfig, indent: 0)
        }

        if !deviceConfig.isEmpty {
            print("\n# Device config (.maho/config.yaml)")
            // Mask auth token in display
            var masked = deviceConfig
            if var auth = masked["auth"] as? [String: Any],
               let token = auth["github_token"] as? String, !token.isEmpty {
                let authToken = AuthToken(token: token, source: .stored)
                auth["github_token"] = authToken.masked
                masked["auth"] = auth
            }
            printDict(masked, indent: 0)
        }

        // Also show global auth if available
        let globalAuth = Auth()
        if let token = try? globalAuth.resolveToken() {
            if deviceConfig.isEmpty && vaultConfig.isEmpty {
                print("# No vault config found")
            }
            print("\n# Global auth (~/.maho/config.yaml)")
            print("  github_token: \(token.masked)")
        }

        if vaultConfig.isEmpty && deviceConfig.isEmpty {
            if (try? globalAuth.resolveToken()) == nil {
                print("No configuration found. Run `mn init` to create a vault.")
            }
        }
    }

    private func printDict(_ dict: [String: Any], indent: Int) {
        let prefix = String(repeating: "  ", count: indent)
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            if let nested = value as? [String: Any] {
                print("\(prefix)\(key):")
                printDict(nested, indent: indent + 1)
            } else {
                print("\(prefix)\(key): \(value)")
            }
        }
    }
}

// MARK: - mn config --set <key> <value>

struct ConfigSetSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a configuration value"
    )

    @OptionGroup var vaultOption: VaultOption

    @Argument(help: "Config key (e.g., author.name, github.repo)")
    var key: String

    @Argument(help: "Value to set")
    var value: String

    func run() throws {
        try vaultOption.validateVaultExists()
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
        let config = Config(vaultPath: vaultPath)
        try config.setValue(key: key, value: value)
        print("Set \(key) = \(value)")
    }
}

// MARK: - mn config auth

struct AuthSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Configure GitHub authentication"
    )

    @OptionGroup var vaultOption: VaultOption

    @Flag(name: .long, help: "Show current auth status")
    var status: Bool = false

    func run() throws {
        // Auth does NOT require a vault to exist — tokens are device-level (stored in ~/.maho/config.yaml)
        // If vault exists, also check vault's .maho/config.yaml as fallback
        let vaultPath: String? = {
            let expanded = (vaultOption.resolvedPath as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded) ? expanded : nil
        }()
        let auth = Auth(vaultPath: vaultPath)

        if status {
            showStatus(auth: auth)
        } else {
            resolveAndStore(auth: auth)
        }
    }

    private func showStatus(auth: Auth) {
        do {
            let token = try auth.resolveToken()
            print("GitHub auth: configured")
            print("  Source: \(token.source.rawValue)")
            print("  Token:  \(token.masked)")

            // Validate token
            do {
                try auth.validateToken(token.token)
                print("  Status: valid")
            } catch {
                print("  Status: invalid (\(error))")
            }
        } catch {
            print("GitHub auth: not configured")
            print("\(error)")
        }
    }

    private func resolveAndStore(auth: Auth) {
        do {
            let token = try auth.resolveToken()
            print("Found GitHub token from: \(token.source.rawValue)")
            print("Token: \(token.masked)")

            // Store it if not already stored
            if token.source != .stored {
                do {
                    try auth.storeToken(token.token)
                    print("Token stored in .maho/config.yaml")
                } catch {
                    print("Warning: Could not store token: \(error)")
                }
            }

            // Validate
            do {
                try auth.validateToken(token.token)
                print("Token validated successfully.")
            } catch {
                print("Warning: Token validation failed: \(error)")
                print("The token has been stored but may not work. Try re-authenticating.")
            }
        } catch {
            print("\(error)")
        }
    }
}
