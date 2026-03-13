import SwiftUI
import MahoNotesKit

/// Shared note row content used across iPhone, iPad, and macOS B-column lists.
/// Displays title, date, and conflict badge. Platform-specific navigation
/// wrapping (NavigationLink vs tag-based selection) is handled by the caller.
struct NoteRowContent: View {
    let note: Note
    let hasConflict: Bool
    let hasGitHubConflict: Bool

    init(note: Note, hasConflict: Bool = false, hasGitHubConflict: Bool = false) {
        self.note = note
        self.hasConflict = hasConflict
        self.hasGitHubConflict = hasGitHubConflict
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .lineLimit(1)
                Text(note.updated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if hasConflict || hasGitHubConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .frame(minHeight: 44)
    }
}
