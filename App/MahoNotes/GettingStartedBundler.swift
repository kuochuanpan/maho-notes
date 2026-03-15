import Foundation
import MahoNotesKit
import os

/// Installs the bundled getting-started tutorial vault on first launch.
@MainActor
enum GettingStartedBundler {

    private static let hasInstalledKey = "hasInstalledGettingStarted"
    private static let vaultName = "getting-started"
    private static let logger = Logger(subsystem: "dev.pcca.maho-notes", category: "bundler")

    /// Copies the bundled tutorial vault to the vaults directory and registers it.
    /// No-op if already installed. Errors are logged but never thrown.
    static func installIfNeeded(store: VaultStore) async {
        guard !UserDefaults.standard.bool(forKey: hasInstalledKey) else { return }

        do {
            try await install(store: store)
            UserDefaults.standard.set(true, forKey: hasInstalledKey)
        } catch {
            logger.warning("Failed to install getting-started vault: \(error.localizedDescription)")
        }
    }

    private static func install(store: VaultStore) async throws {
        guard let bundleURL = Bundle.main.url(
            forResource: "GettingStarted",
            withExtension: nil,
            subdirectory: nil
        ) else {
            logger.warning("GettingStarted bundle resource not found")
            return
        }

        // Resolve the destination: device-type vault stored in the config vaults dir
        let entry = VaultEntry(
            name: vaultName,
            type: .device,
            access: .readOnly,
            displayName: "Getting Started"
        )
        let destPath = store.resolvedPath(for: entry)
        let fm = FileManager.default

        // Skip if the vault directory already exists on disk
        if fm.fileExists(atPath: destPath) {
            // Directory exists but wasn't registered — still mark as installed
            try? await store.registerVault(entry)
            return
        }

        // Copy bundle contents to destination
        try fm.createDirectory(atPath: destPath, withIntermediateDirectories: true)

        let contents = try fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
        for item in contents {
            let destItem = URL(fileURLWithPath: destPath).appendingPathComponent(item.lastPathComponent)
            try fm.copyItem(at: item, to: destItem)
        }

        // Create .maho/ directory
        let mahoDir = (destPath as NSString).appendingPathComponent(".maho")
        if !fm.fileExists(atPath: mahoDir) {
            try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
        }

        // Create .gitignore
        let gitignorePath = (destPath as NSString).appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: gitignorePath) {
            try ".maho/\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        }

        // Register in the vault registry
        try await store.registerVault(entry)
    }
}
