import ArgumentParser
import Foundation
import MahoNotesKit
import Yams

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or set configuration"
    )

    @OptionGroup var vaultOption: VaultOption

    @Flag(name: .long, help: "Set a config value (usage: --set key value)")
    var set: Bool = false

    @Argument(help: "Key and value (when using --set)")
    var args: [String] = []

    func run() throws {
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
                printDict(deviceConfig, indent: 0)
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
