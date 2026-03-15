import Foundation
import MahoNotesKit
import os

/// Installs the bundled getting-started tutorial vault on first launch.
@MainActor
enum GettingStartedBundler {

    private enum BundlerError: Error {
        case resourceNotFound
    }

    private static let hasInstalledKey = "hasInstalledGettingStarted"
    private static let vaultName = "getting-started"
    private static let logger = Logger(subsystem: "dev.pcca.maho-notes", category: "bundler")

    /// Copies the bundled tutorial vault to the vaults directory and registers it.
    /// No-op if already installed. Errors are logged but never thrown.
    static func installIfNeeded(store: VaultStore) async {
        let alreadyInstalled = UserDefaults.standard.bool(forKey: hasInstalledKey)
        logger.info("GettingStartedBundler: hasInstalled=\(alreadyInstalled)")
        guard !alreadyInstalled else { return }

        do {
            try await install(store: store)
            UserDefaults.standard.set(true, forKey: hasInstalledKey)
            logger.info("GettingStartedBundler: install succeeded ✅")
        } catch {
            logger.warning("Failed to install getting-started vault: \(error.localizedDescription)")
        }
    }

    private static func install(store: VaultStore) async throws {
        guard let bundleURL = Bundle.main.url(
            forResource: "GettingStarted",
            withExtension: "bundle"
        ) else {
            logger.warning("GettingStarted.bundle not found in app bundle — skipping (will retry next launch)")
            throw BundlerError.resourceNotFound
        }

        logger.info("GettingStartedBundler: bundle found at \(bundleURL.path)")

        // Resolve the destination: device-type vault stored in the config vaults dir
        let entry = VaultEntry(
            name: vaultName,
            type: .device,
            access: .readWrite,
            displayName: "Getting Started"
        )
        let destPath = store.resolvedPath(for: entry)
        let fm = FileManager.default

        logger.info("GettingStartedBundler: destPath=\(destPath)")

        // Skip if the vault directory already exists on disk
        if fm.fileExists(atPath: destPath) {
            logger.info("GettingStartedBundler: destPath already exists, registering only")
            // Directory exists but wasn't registered — still mark as installed
            try? await store.registerVault(entry)
            return
        }

        // Copy bundle contents to destination
        try fm.createDirectory(atPath: destPath, withIntermediateDirectories: true)
        logger.info("GettingStartedBundler: created directory")

        let contents = try fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
        logger.info("GettingStartedBundler: bundle has \(contents.count) items: \(contents.map(\.lastPathComponent))")
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
        logger.info("GettingStartedBundler: registering vault...")
        try await store.registerVault(entry)
        logger.info("GettingStartedBundler: registered ✅")
    }
}
