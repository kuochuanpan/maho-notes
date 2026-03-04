import ArgumentParser
import Foundation
import MahoNotesKit
import Yams

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or set configuration",
        subcommands: [AuthSubcommand.self]
    )

    @OptionGroup var vaultOption: VaultOption

    @Flag(name: .long, help: "Set a config value (usage: --set key value)")
    var set: Bool = false

    @Argument(help: "Key and value (when using --set)")
    var args: [String] = []

    func run() throws {
        try vaultOption.validateVaultExists()
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
        let config = Config(vaultPath: vaultPath)

        if set {
            guard args.count == 2 else {
                print("Usage: mn config --set <key> <value>")
                throw ExitCode.failure
            }
            try config.setValue(key: args[0], value: args[1])
            print("Set \(args[0]) = \(args[1])")
        } else {
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

            if vaultConfig.isEmpty && deviceConfig.isEmpty {
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
        try vaultOption.validateVaultExists()
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
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
