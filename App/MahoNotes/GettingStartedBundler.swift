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
    /// No-op if already installed or if iCloud already has vaults from another device.
    /// Errors are logged but never thrown.
    ///
    /// Returns `true` if iCloud vaults were adopted (caller should reload with cloud mode).
    static func installIfNeeded(store: VaultStore) async -> Bool {
        let alreadyInstalled = UserDefaults.standard.bool(forKey: hasInstalledKey)
        logger.info("GettingStartedBundler: hasInstalled=\(alreadyInstalled)")
        guard !alreadyInstalled else { return false }

        // Check if iCloud already has vaults from another device.
        // If so, skip the tutorial vault and adopt the iCloud registry directly.
        switch await store.checkCloudRegistryExists() {
        case .cloudRegistryExists(let cloudRegistry) where !cloudRegistry.vaults.isEmpty:
            logger.info("GettingStartedBundler: iCloud registry found with \(cloudRegistry.vaults.count) vault(s) — adopting instead of installing tutorial")
            if await adoptICloudRegistry(cloudRegistry.vaults, store: store) { return true }
        case .cloudRegistryUnavailable:
            // Another device's registry is in iCloud but hasn't downloaded yet. Installing the
            // tutorial now would save a one-vault registry over it and hide every vault on
            // every device. Adopt instead; the registry loads once iCloud delivers it.
            logger.info("GettingStartedBundler: iCloud registry not readable yet — adopting instead of installing tutorial")
            if await adoptICloudRegistry([], store: store) { return true }
            // Couldn't switch to iCloud mode: retry on next launch rather than risk the install
            return false
        default:
            break
        }

        do {
            try await install(store: store)
            UserDefaults.standard.set(true, forKey: hasInstalledKey)
            logger.info("GettingStartedBundler: install succeeded ✅")
        } catch {
            logger.warning("Failed to install getting-started vault: \(error.localizedDescription)")
        }
        return false
    }

    /// Turns Cloud Sync on so `loadRegistry()` reads the iCloud registry, and asks iCloud to
    /// download the given vaults. Returns `false` if the mode couldn't be saved.
    private static func adoptICloudRegistry(_ vaults: [VaultEntry], store: VaultStore) async -> Bool {
        do {
            try await store.setCloudSyncMode(.icloud)
            let fm = FileManager.default
            for entry in vaults where entry.type == .icloud {
                let path = store.resolvedPath(for: entry)
                try? fm.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: path))
            }
            UserDefaults.standard.set(true, forKey: hasInstalledKey)
            logger.info("GettingStartedBundler: iCloud adoption complete ✅")
            return true
        } catch {
            logger.warning("GettingStartedBundler: failed to adopt iCloud registry: \(error.localizedDescription)")
            return false
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

        // With Cloud Sync on, the registry is shared by every device, so the tutorial must
        // live in iCloud too. A `.device` entry there points at a folder only this device
        // has, and every other device shows an empty Getting Started vault.
        let type: VaultType = await store.cloudSyncMode() == .icloud ? .icloud : .device
        let entry = VaultEntry(
            name: vaultName,
            type: type,
            access: .readWrite,
            displayName: "Getting Started"
        )
        let destPath = store.resolvedPath(for: entry)
        let fm = FileManager.default

        logger.info("GettingStartedBundler: destPath=\(destPath)")

        // Skip if the vault directory already exists on disk
        if fm.fileExists(atPath: destPath) {
            logger.info("GettingStartedBundler: destPath already exists, registering only")
            try await register(entry, store: store)
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
        try await register(entry, store: store)
        logger.info("GettingStartedBundler: registered ✅")
    }

    /// Registers the tutorial vault; an existing entry (e.g. added by another device) counts
    /// as success. Any other failure, such as an unreadable iCloud registry, is rethrown so
    /// the install is retried next launch instead of being marked done.
    private static func register(_ entry: VaultEntry, store: VaultStore) async throws {
        do {
            try await store.registerVault(entry)
        } catch VaultRegistryError.duplicateName {
            logger.info("GettingStartedBundler: already registered")
        }
    }
}
