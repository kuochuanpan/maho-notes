import Foundation
import Observation

/// Monitors iCloud Drive changes for vaults stored in iCloud containers.
/// Uses NSMetadataQuery to detect file updates, downloads, and conflicts.
@Observable
final class iCloudSyncManager: @unchecked Sendable {

    // MARK: - Public State

    private(set) var isMonitoring = false
    private(set) var pendingDownloads: Int = 0
    private(set) var conflicts: [ConflictInfo] = []

    struct ConflictInfo: Identifiable {
        let id = UUID()
        let noteURL: URL
        let notePath: String
        let versions: [NSFileVersion]
    }

    enum ConflictResolution {
        case keepCurrent
        case keepOther(NSFileVersion)
    }

    // MARK: - Private

    private var metadataQuery: NSMetadataQuery?
    private var onFilesChanged: (() -> Void)?
    private var debounceTask: Task<Void, Never>?

    // MARK: - Container URL

    static func iCloudContainerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.pcca.mahonotes")
    }

    static func iCloudDocumentsURL() -> URL? {
        iCloudContainerURL()?.appendingPathComponent("Documents")
    }

    // MARK: - Monitoring

    func startMonitoring(containerURL: URL, onChange: @escaping () -> Void) {
        guard !isMonitoring else { return }

        onFilesChanged = onChange

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.handleQueryUpdate()
        }

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            self?.handleQueryUpdate()
        }

        query.start()
        metadataQuery = query
        isMonitoring = true
    }

    func stopMonitoring() {
        metadataQuery?.stop()
        metadataQuery = nil
        NotificationCenter.default.removeObserver(self)
        isMonitoring = false
        debounceTask?.cancel()
        debounceTask = nil
        onFilesChanged = nil
    }

    // MARK: - File Downloads

    /// Trigger download for a cloud-only (.icloud placeholder) file.
    func downloadFileIfNeeded(at url: URL) {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            // Download request failed — file may not be in iCloud
        }
    }

    /// Check if a file is a cloud-only placeholder (not yet downloaded).
    static func isCloudPlaceholder(at url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".icloud")
    }

    /// Get the actual file URL from a .icloud placeholder name.
    static func actualURL(from placeholderURL: URL) -> URL {
        var name = placeholderURL.lastPathComponent
        // .icloud placeholders are like ".filename.icloud"
        if name.hasPrefix(".") { name = String(name.dropFirst()) }
        if name.hasSuffix(".icloud") { name = String(name.dropLast(7)) }
        return placeholderURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    // MARK: - Conflicts

    func checkForConflicts(in directory: URL) {
        var found: [ConflictInfo] = []

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension == "md" else { continue }

            if NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL)?.isEmpty == false {
                let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL) ?? []
                let relativePath = fileURL.path.replacingOccurrences(
                    of: directory.path + "/", with: ""
                )
                found.append(ConflictInfo(
                    noteURL: fileURL,
                    notePath: relativePath,
                    versions: versions
                ))
            }
        }

        conflicts = found
    }

    func resolveConflict(_ conflict: ConflictInfo, keeping resolution: ConflictResolution) {
        switch resolution {
        case .keepCurrent:
            // Remove all conflict versions, keeping the current file
            if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: conflict.noteURL) {
                for version in versions {
                    version.isResolved = true
                }
                try? NSFileVersion.removeOtherVersionsOfItem(at: conflict.noteURL)
            }

        case .keepOther(let version):
            // Replace current with the conflict version
            do {
                try version.replaceItem(at: conflict.noteURL, options: [])
                if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: conflict.noteURL) {
                    for v in versions {
                        v.isResolved = true
                    }
                }
                try? NSFileVersion.removeOtherVersionsOfItem(at: conflict.noteURL)
            } catch {
                // Resolution failed
            }
        }

        // Refresh conflict list
        conflicts.removeAll { $0.noteURL == conflict.noteURL }
        onFilesChanged?()
    }

    // MARK: - Private

    private func handleQueryUpdate() {
        guard let query = metadataQuery else { return }

        query.disableUpdates()
        defer { query.enableUpdates() }

        // Count pending downloads
        var downloading = 0
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
               status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                downloading += 1
            }
        }
        pendingDownloads = downloading

        // Debounce the reload callback
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onFilesChanged?()
        }
    }
}
