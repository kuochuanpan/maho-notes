import SwiftUI
import MahoNotesKit

/// C — Note content panel showing the selected note's title and body.
struct NoteContentView: View {
    @Environment(AppState.self) private var appState

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
                Spacer()
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Note body
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(note.title)
                        .font(.title)
                        .fontWeight(.bold)
                        .textSelection(.enabled)

                    Text(note.body)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
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
