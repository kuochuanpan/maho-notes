import Foundation
import Observation
import MahoNotesKit

@Observable
@MainActor final class EditorState {

    weak var appState: AppState?

    /// View mode for the content panel.
    enum ViewMode: String {
        case preview, editor, split

        /// SF Symbol for the view-mode toggle showing this mode.
        var systemImage: String {
            switch self {
            case .preview: return "eye"
            case .editor: return "pencil"
            case .split: return "rectangle.split.2x1"
            }
        }
    }

    /// Current view mode. Forced to `.preview` for read-only vaults.
    var viewMode: ViewMode = .preview {
        didSet {
            if isReadOnly && viewMode != .preview {
                viewMode = .preview
            }
        }
    }

    /// The current editing buffer (raw markdown body).
    var editingBody: String = ""

    /// Current cursor/selection range in the editor (kept in sync by MarkdownEditorView).
    var selectedRange: NSRange = NSRange(location: 0, length: 0)

    /// Set to a non-nil action to trigger formatting in the editor view.
    /// The editor view reads this, applies it, and clears it.
    var pendingToolbarAction: MarkdownToolbarAction?

    /// Set to a non-nil string to insert arbitrary markdown text at the cursor.
    /// The editor view reads this, inserts it, and clears it.
    var pendingInsertion: String?

    nonisolated init() {}

    /// Trigger a toolbar formatting action on the editor.
    func applyToolbarAction(_ action: MarkdownToolbarAction) {
        pendingToolbarAction = action
    }

    /// The note body on disk that the buffer was loaded from or last saved as.
    /// `nil` while no note is loaded into the buffer.
    private(set) var baseBody: String?

    /// Whether an input method is composing in the editor (uncommitted Zhuyin / Pinyin / Kana).
    /// The composing text is not part of `editingBody` yet.
    private(set) var isComposing = false

    /// Whether the editing buffer holds changes that are not on disk yet.
    var hasUnsavedChanges: Bool {
        guard appState?.selectedNote != nil, let baseBody else { return false }
        return editingBody != baseBody
    }

    /// Whether the current vault is read-only.
    var isReadOnly: Bool {
        appState?.selectedVault?.access == .readOnly
    }

    /// Copy the note body into the editing buffer, unless it already holds this note.
    func startEditing() {
        guard let note = appState?.selectedNote else { return }
        if baseBody == nil {
            loadBuffer(note.body)
        } else {
            reconcileWithDisk()
        }
    }

    /// Forget the buffer — the selection moved to another note (or to none).
    func resetBuffer() {
        editingBody = ""
        baseBody = nil
    }

    /// Fill the buffer with a note body that is known to match the file on disk.
    func loadBuffer(_ body: String) {
        editingBody = body
        baseBody = body
    }

    /// The editor's input method started or finished composing.
    func compositionChanged(_ composing: Bool) {
        isComposing = composing
        if !composing {
            // A reload that arrived mid-composition was held back.
            reconcileWithDisk()
        }
    }

    /// How the note's file on disk relates to the buffer and to the version the buffer
    /// started from.
    enum DiskChange: Equatable {
        /// The file is what the buffer was loaded from or last saved as.
        case none
        /// The file already has the buffer's text (our own save, read back).
        case sameAsBuffer
        /// The file changed and the buffer has no edits of its own: show the new text.
        case incoming
        /// The file changed and so did the buffer.
        case diverged
    }

    nonisolated static func diskChange(buffer: String, base: String, disk: String) -> DiskChange {
        if disk == base { return .none }
        if disk == buffer { return .sameAsBuffer }
        return buffer == base ? .incoming : .diverged
    }

    /// Bring the buffer up to date after the vault was re-read from disk — a sync pulled
    /// changes, iCloud delivered a new version, another process edited the file.
    ///
    /// The buffer follows the disk only while it has no edits of its own and nothing is being
    /// composed; text the user is typing is never replaced. When both sides changed, the
    /// buffer is kept as it is and `saveNote()` settles it.
    func reconcileWithDisk() {
        guard let note = appState?.selectedNote, let baseBody else { return }
        switch Self.diskChange(buffer: editingBody, base: baseBody, disk: note.body) {
        case .none, .diverged:
            break
        case .sameAsBuffer:
            self.baseBody = note.body
        case .incoming:
            // Mid-composition the text view holds more than the buffer does; wait for
            // `compositionChanged(false)`.
            if !isComposing {
                loadBuffer(note.body)
            }
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
              let baseBody,
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

            // The file changed on disk since the buffer was loaded (a sync or iCloud delivered
            // another device's edit, the CLI wrote it) and the buffer was edited too. Writing
            // the buffer would silently undo that other edit. Same rule as sync conflicts:
            // the version on disk stays, this device's text goes to a conflict copy.
            // Read the body the way `parseNote` does, so this compares like with like.
            let diskBody = splitFrontmatter(content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content).body
            switch Self.diskChange(buffer: editingBody, base: baseBody, disk: diskBody) {
            case .none, .incoming:
                break
            case .sameAsBuffer:
                // Already on disk; nothing to write.
                self.baseBody = diskBody
                return
            case .diverged:
                // Replacing the editor's text would end a composition in progress; the
                // commit that follows comes back through here.
                guard !isComposing else { return }
                let conflictPath = Self.conflictCopyPath(for: note.relativePath, vaultPath: vaultPath)
                let conflictContent = lines[0...endIdx].joined(separator: "\n") + "\n" + editingBody
                try conflictContent.write(
                    toFile: (vaultPath as NSString).appendingPathComponent(conflictPath),
                    atomically: true, encoding: .utf8
                )
                loadBuffer(diskBody)
                appState.reloadCurrentVault()
                return
            }

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

            let savedBody = editingBody
            let newContent = frontmatterLines.joined(separator: "\n") + "\n" + savedBody
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
            self.baseBody = savedBody
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

    /// Path (relative to the vault) for a conflict copy of `relativePath`, in the same
    /// `note.conflict-{DeviceName}.md` form the sync engines' copies end up with.
    private static func conflictCopyPath(for relativePath: String, vaultPath: String) -> String {
        let directory = (relativePath as NSString).deletingLastPathComponent
        let filename = (relativePath as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        func path(_ suffix: String) -> String {
            let name = "\(base).conflict-\(DeviceInfo.filenameSafe)\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
            return directory.isEmpty ? name : "\(directory)/\(name)"
        }
        var candidate = path("")
        var counter = 2
        while FileManager.default.fileExists(atPath: (vaultPath as NSString).appendingPathComponent(candidate)) {
            candidate = path("-\(counter)")
            counter += 1
        }
        return candidate
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
                let vectors = try await provider.embedPassageBatch(texts)
                provider.unloadModel()  // Release CoreML memory immediately

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

    /// Toggle a task-list checkbox in the note body and save to disk.
    /// Works in any view mode (preview, editor, split).
    func toggleCheckbox(at index: Int, checked: Bool) {
        guard let appState,
              let note = appState.selectedNote,
              let entry = appState.selectedVault,
              !isReadOnly else { return }

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

            // Toggle checkbox in the body portion
            let body = lines[(endIdx + 1)...].joined(separator: "\n")
            let newBody = MarkdownHTMLRenderer.toggleCheckbox(at: index, checked: checked, in: body)
            guard newBody != body else { return } // nothing changed

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

            let newContent = frontmatterLines.joined(separator: "\n") + "\n" + newBody
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
            appState.syncCoordinator.notifyContentChanged(vault: entry)

            // Reload the note in allNotes
            if let updated = try parseNote(at: filePath, relativeTo: vaultPath) {
                appState.updateNote(updated, replacing: note.relativePath)

                // Always sync the editing buffer so startEditing() picks up the change
                loadBuffer(updated.body)

                // Re-embed for vector search
                reembedNoteInBackground(updated, vaultPath: vaultPath)
            }
        } catch {
            // Silently fail
        }
    }

    /// Revert editing buffer and switch to preview.
    func cancelEditing() {
        if let note = appState?.selectedNote {
            loadBuffer(note.body)
        }
        viewMode = .preview
    }
}
