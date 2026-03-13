import Foundation
import Observation
import MahoNotesKit

@Observable
@MainActor final class EditorState {

    weak var appState: AppState?

    /// View mode for the content panel.
    enum ViewMode: String { case preview, editor, split }

    /// Current view mode.
    var viewMode: ViewMode = .preview

    /// The current editing buffer (raw markdown body).
    var editingBody: String = ""

    nonisolated init() {}

    /// Whether the editing buffer differs from the saved note body.
    var hasUnsavedChanges: Bool {
        guard let note = appState?.selectedNote else { return false }
        return editingBody != note.body
    }

    /// Whether the current vault is read-only.
    var isReadOnly: Bool {
        appState?.selectedVault?.access == .readOnly
    }

    /// Copy the note body into the editing buffer.
    func startEditing() {
        guard let note = appState?.selectedNote else { return }
        if editingBody.isEmpty || !hasUnsavedChanges {
            editingBody = note.body
        }
    }

    /// Cycle view mode: preview -> editor -> split -> preview.
    /// When `compactWidth` is true (iPhone portrait), skip split: preview <-> editor.
    func cycleViewMode(compactWidth: Bool = false) {
        guard !isReadOnly else { return }
        switch viewMode {
        case .preview: viewMode = .editor; startEditing()
        case .editor:
            if compactWidth {
                // iPhone portrait: skip split, go back to preview
                if hasUnsavedChanges { saveNote() }
                viewMode = .preview
            } else {
                viewMode = .split; startEditing()
            }
        case .split:
            // Save before switching to preview (saveNote guards viewMode != .preview)
            if hasUnsavedChanges { saveNote() }
            viewMode = .preview
        }
    }

    /// Save the editing buffer back to the markdown file, preserving frontmatter.
    func saveNote() {
        // Only save when actively editing (not in preview mode with stale/empty buffer)
        guard viewMode != .preview else { return }
        guard let appState,
              let note = appState.selectedNote,
              let entry = appState.selectedVault,
              !isReadOnly else { return }
        guard hasUnsavedChanges else { return }
        guard !editingBody.isEmpty else { return }

        let store = appState.store
        let vaultPath = store.resolvedPath(for: entry)
        let filePath = (vaultPath as NSString).appendingPathComponent(note.relativePath)

        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            // Find frontmatter boundaries
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return }
            var closingIndex: Int?
            for i in 1..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    closingIndex = i
                    break
                }
            }
            guard let endIdx = closingIndex else { return }

            // Update the `updated` timestamp in frontmatter
            var frontmatterLines = Array(lines[0...endIdx])
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            let now = isoFormatter.string(from: Date())

            if let updatedIdx = frontmatterLines.firstIndex(where: { $0.hasPrefix("updated:") }) {
                frontmatterLines[updatedIdx] = "updated: \(now)"
            } else {
                frontmatterLines.insert("updated: \(now)", at: endIdx)
            }

            let newContent = frontmatterLines.joined(separator: "\n") + "\n" + editingBody
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
            appState.syncCoordinator.notifyContentChanged(vault: entry)

            // Reload the note in allNotes
            if let updated = try parseNote(at: filePath, relativeTo: vaultPath) {
                appState.updateNote(updated, replacing: note.relativePath)

                // Background: re-embed the updated note for vector search
                reembedNoteInBackground(updated, vaultPath: vaultPath)
            }
        } catch {
            // Silently fail for now — could add error reporting later
        }
    }

    /// Re-embed a single note's vector chunks in the background after save.
    /// Only runs if a vector index already exists for the vault (skip if never built).
    private func reembedNoteInBackground(_ note: Note, vaultPath: String) {
        guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else { return }

        let currentEmbeddingModel = appState?.searchManager.embeddingModel ?? "minilm"
        Task.detached {
            do {
                let model = EmbeddingModel(rawValue: currentEmbeddingModel) ?? .minilm
                let provider = SwiftEmbeddingsProvider(model: model)

                let vecIndex = try VectorIndex(vaultPath: vaultPath, dimensions: provider.dimensions, skipDimensionCheck: true)

                // Chunk the note and embed
                let chunks = Chunker.chunkNote(title: note.title, body: note.body)
                guard !chunks.isEmpty else {
                    try vecIndex.removeNote(path: note.relativePath)
                    return
                }

                let texts = chunks.map { $0.text }
                let vectors = try await provider.embedBatch(texts)

                let filePath = (vaultPath as NSString).appendingPathComponent(note.relativePath)
                let mtime = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.modificationDate]
                    .flatMap { ($0 as? Date)?.timeIntervalSince1970 } ?? Date().timeIntervalSince1970

                try vecIndex.indexNote(
                    path: note.relativePath,
                    chunks: chunks.map { (id: $0.id, text: $0.text) },
                    vectors: vectors,
                    model: model.rawValue,
                    mtime: mtime
                )
            } catch {
                // Silently fail — vector re-indexing is best-effort
            }
        }
    }

    /// Revert editing buffer and switch to preview.
    func cancelEditing() {
        if let note = appState?.selectedNote {
            editingBody = note.body
        }
        viewMode = .preview
    }
}
