import SwiftUI
import MahoNotesKit

/// C -- Note content panel showing the selected note's title and body.
struct NoteContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14

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
            // Breadcrumb header
            HStack(spacing: 4) {
                Text(note.collection)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(note.title)
                if appState.hasUnsavedChanges {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                }
                Spacer()
            }
            .font(.subheadline)
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

    @ViewBuilder
    private func contentForMode(_ note: Note) -> some View {
        switch appState.viewMode {
        case .preview:
            MarkdownWebView(markdown: "# \(note.title)\n\n\(note.body)")
        case .editor:
            editorView
                .onAppear { appState.startEditing() }
        case .split:
            HStack(spacing: 0) {
                editorView
                Divider()
                MarkdownWebView(markdown: "# \(note.title)\n\n\(appState.editingBody)")
            }
            .onAppear { appState.startEditing() }
        }
    }

    private var editorView: some View {
        @Bindable var state = appState
        return TextEditor(text: $state.editingBody)
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
