import SwiftUI
import MahoNotesKit

// MARK: - Environment Keys for iPad inline controls

private struct SidebarToggleActionKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

private struct InlineActionButtonsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    /// Optional sidebar toggle action injected by iPad layout.
    var sidebarToggleAction: (() -> Void)? {
        get { self[SidebarToggleActionKey.self] }
        set { self[SidebarToggleActionKey.self] = newValue }
    }
    /// Optional inline action buttons injected by iPad layout (replaces nav bar).
    var inlineActionButtons: AnyView? {
        get { self[InlineActionButtonsKey.self] }
        set { self[InlineActionButtonsKey.self] = newValue }
    }
}

/// C -- Note content panel showing the selected note's title and body.
struct NoteContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.sidebarToggleAction) private var sidebarToggleAction
    @Environment(\.inlineActionButtons) private var inlineActionButtons
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14
    @FocusState private var editorFocused: Bool

    var body: some View {
        if let note = appState.selectedNote {
            noteContent(note)
        } else {
            emptyState
        }
    }

    // MARK: - Note Content

    private func noteContent(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Conflict banner
            if let conflict = appState.conflict(for: note.relativePath) {
                conflictBanner(conflict)
            } else if let conflictFile = appState.githubConflictFile(for: note.relativePath) {
                githubConflictBanner(conflictFile)
            }

            // Breadcrumb header (+ optional iPad inline controls)
            HStack(spacing: 8) {
                if let toggleAction = sidebarToggleAction {
                    Button(action: toggleAction) {
                        Image(systemName: "sidebar.left")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    breadcrumb(for: note)
                    if appState.hasUnsavedChanges {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                    }
                }
                .font(.subheadline)
                Spacer()
                if let actions = inlineActionButtons {
                    actions
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Content area with floating toolbar overlay
            ZStack(alignment: .bottomTrailing) {
                contentForMode(note)
                FloatingToolbarView()
            }
        }
    }

    // MARK: - Conflict Banner

    private func conflictBanner(_ conflict: iCloudSyncManager.ConflictInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("This note has a conflict version")
                .font(.subheadline)
            Spacer()
            Button("Keep Current") {
                appState.iCloudManager.resolveConflict(conflict, keeping: .keepCurrent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let otherVersion = conflict.versions.first {
                Button("Keep Other Version") {
                    appState.iCloudManager.resolveConflict(conflict, keeping: .keepOther(otherVersion))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.1))
    }

    private func githubConflictBanner(_ conflictPath: String) -> some View {
        let filename = URL(fileURLWithPath: conflictPath).lastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Conflict detected — local version saved as \(filename)")
                .font(.subheadline)
            Spacer()
            Button("Open Conflict File") {
                appState.selectedNotePath = conflictPath
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    @ViewBuilder
    private func contentForMode(_ note: Note) -> some View {
        if isCloudOnly(note) {
            downloadingPlaceholder(note)
        } else {
            switch appState.viewMode {
            case .preview:
                MarkdownWebView(markdown: "# \(note.title)\n\n\(note.body)")
            case .editor:
                editorView
                    .onAppear {
                        appState.startEditing()
                        editorFocused = true
                    }
            case .split:
                HStack(spacing: 0) {
                    editorView
                    Divider()
                    MarkdownWebView(markdown: "# \(note.title)\n\n\(appState.editingBody)")
                }
                .onAppear {
                    appState.startEditing()
                    editorFocused = true
                }
            }
        }
    }

    // MARK: - Breadcrumb

    /// Build a breadcrumb from the note's relative path.
    /// Shows up to 3 path segments + title. If the path has more than 3 segments,
    /// the leading ones are collapsed into "…".
    private func breadcrumb(for note: Note) -> some View {
        let segments = note.relativePath
            .components(separatedBy: "/")
            .dropLast() // remove filename

        // Show at most 3 directory segments; collapse earlier ones into "…"
        let maxSegments = 3
        let display: [String]
        if segments.count > maxSegments {
            display = ["…"] + Array(segments.suffix(maxSegments))
        } else {
            display = Array(segments)
        }

        return HStack(spacing: 4) {
            ForEach(Array(display.enumerated()), id: \.offset) { _, segment in
                Text(segment)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(note.title)
        }
    }

    /// Check if the note's file is a cloud-only placeholder (not downloaded yet).
    private func isCloudOnly(_ note: Note) -> Bool {
        guard let entry = appState.selectedVault, entry.type == .icloud else { return false }
        let vaultPath = appState.store.resolvedPath(for: entry)
        let dir = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent((note.relativePath as NSString).deletingLastPathComponent)
        let placeholder = dir.appendingPathComponent(".\(note.relativePath.components(separatedBy: "/").last ?? "").icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    private func downloadingPlaceholder(_ note: Note) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Downloading from iCloud...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard let entry = appState.selectedVault else { return }
            let vaultPath = appState.store.resolvedPath(for: entry)
            let fileURL = URL(fileURLWithPath: vaultPath).appendingPathComponent(note.relativePath)
            appState.iCloudManager.downloadFileIfNeeded(at: fileURL)
        }
    }

    private var editorView: some View {
        @Bindable var state = appState
        return TextEditor(text: $state.editingBody)
            .focused($editorFocused)
            .font(.system(size: editorFontSize, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .task(id: appState.editingBody) {
                // Debounced auto-save: 2s after last keystroke
                // Guard: only save when in editor/split mode with non-empty buffer
                guard appState.viewMode != .preview else { return }
                guard !appState.editingBody.isEmpty else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled && appState.viewMode != .preview {
                    appState.saveNote()
                }
            }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.page")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select a note")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
