import Foundation
import Observation
import MahoNotesKit

@Observable
@MainActor final class NoteClipboard {

    struct Entry {
        let relativePath: String
        let vaultName: String
    }

    /// Copied notes waiting to be pasted.
    var entries: [Entry]?

    weak var appState: AppState?

    nonisolated init() {}

    /// Copy the currently selected note(s) to the clipboard.
    func copySelectedNotes() {
        guard let appState, let vaultName = appState.selectedVaultName else { return }
        let paths: [String]
        if appState.selectedNotePaths.count > 1 {
            paths = Array(appState.selectedNotePaths)
        } else if let path = appState.selectedNotePath {
            paths = [path]
        } else {
            return
        }
        entries = paths.map { Entry(relativePath: $0, vaultName: vaultName) }
    }

    /// Paste copied notes into a target collection in the current vault.
    func pasteNotes(toCollection collectionId: String) {
        guard let appState else { return }
        guard let clipboard = entries, !clipboard.isEmpty else { return }
        guard let targetEntry = appState.selectedVault else { return }
        let store = appState.store
        let targetVaultPath = store.resolvedPath(for: targetEntry)
        let fm = FileManager.default

        let targetDir = (targetVaultPath as NSString).appendingPathComponent(collectionId)
        try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        var pastedFilenames: [String] = []

        for item in clipboard {
            // Resolve source vault path
            let sourceEntry = appState.vaults.first { $0.name == item.vaultName }
            let sourceVaultPath: String
            if let entry = sourceEntry {
                sourceVaultPath = store.resolvedPath(for: entry)
            } else {
                continue
            }

            let sourceAbs = (sourceVaultPath as NSString).appendingPathComponent(item.relativePath)
            guard fm.fileExists(atPath: sourceAbs) else { continue }

            let originalFilename = (item.relativePath as NSString).lastPathComponent
            let ext = (originalFilename as NSString).pathExtension
            let baseName = (originalFilename as NSString).deletingPathExtension

            // Determine target filename with (Copy) suffix
            var targetFilename: String
            var targetAbs: String
            var copySuffix: String

            let copyName = "\(baseName)(Copy).\(ext)"
            targetAbs = (targetDir as NSString).appendingPathComponent(copyName)

            if !fm.fileExists(atPath: targetAbs) {
                targetFilename = copyName
                copySuffix = "(Copy)"
            } else {
                var counter = 2
                repeat {
                    copySuffix = "(Copy \(counter))"
                    targetFilename = "\(baseName)\(copySuffix).\(ext)"
                    targetAbs = (targetDir as NSString).appendingPathComponent(targetFilename)
                    counter += 1
                } while fm.fileExists(atPath: targetAbs)
            }

            // Copy file and update frontmatter title
            do {
                try fm.copyItem(atPath: sourceAbs, toPath: targetAbs)

                // Update title in frontmatter to include (Copy) suffix
                if var content = try? String(contentsOfFile: targetAbs, encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n")
                    if let titleIdx = lines.firstIndex(where: { $0.hasPrefix("title:") }) {
                        var mutableLines = lines
                        let originalTitle = mutableLines[titleIdx]
                            .replacingOccurrences(of: "title:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        mutableLines[titleIdx] = "title: \(originalTitle) \(copySuffix)"
                        content = mutableLines.joined(separator: "\n")
                        try? content.write(toFile: targetAbs, atomically: true, encoding: .utf8)
                    }
                }

                pastedFilenames.append(targetFilename)
            } catch {
                // Skip failed copies
            }
        }

        // Append pasted files to target _index.md order
        if !pastedFilenames.isEmpty {
            let (existingOrder, _) = readDirectoryOrder(at: targetDir)
            var newOrder = existingOrder
            newOrder.append(contentsOf: pastedFilenames)
            try? writeDirectoryOrder(at: targetDir, notes: newOrder)
        }

        appState.reloadCurrentVault()

        // Trigger sync
        if let entry = appState.selectedVault {
            appState.syncCoordinator.notifyContentChanged(vault: entry)
        }
    }
}
