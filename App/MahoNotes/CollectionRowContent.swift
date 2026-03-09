import SwiftUI
import MahoNotesKit

/// Shared collection row label used across iPhone, iPad, and macOS B-column lists.
struct CollectionRowContent: View {
    let name: String
    let icon: String
    let noteCount: Int

    init(name: String, icon: String, noteCount: Int = 0) {
        self.name = name
        self.icon = icon
        self.noteCount = noteCount
    }

    var body: some View {
        HStack {
            Label(name, systemImage: icon)
                .font(.body)
            Spacer()
            if noteCount > 0 {
                Text("\(noteCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
