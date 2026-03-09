import SwiftUI
import MahoNotesKit

/// Shared ViewModifier providing context menu and swipe actions for note rows.
/// Works on iOS (long press + swipe) and macOS (right-click context menu).
/// macOS ignores `.swipeActions` automatically.
struct NoteRowActionsModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    let notePath: String
    let noteTitle: String

    // Callbacks for actions that need UI (alerts/sheets) managed by the parent
    var onRename: ((String, String) -> Void)?   // (path, currentTitle)
    var onDelete: ((String, String) -> Void)?   // (path, title)
    var onMove: ((String) -> Void)?             // (path) — show move picker

    func body(content: Content) -> some View {
        content
            .contextMenu {
                contextMenuContent
            }
            #if os(iOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    onDelete?(notePath, noteTitle)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    onRename?(notePath, noteTitle)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
            #endif
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            appState.selectedNotePath = notePath
            appState.copySelectedNotes()
        } label: {
            Label("Copy Note", systemImage: "doc.on.doc")
        }

        if let onRename {
            Button {
                onRename(notePath, noteTitle)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }

        if let onMove {
            Button {
                onMove(notePath)
            } label: {
                Label("Move to…", systemImage: "folder")
            }
        }

        if appState.conflict(for: notePath) != nil {
            Button {
                if let conflict = appState.conflict(for: notePath) {
                    appState.iCloudManager.resolveConflict(conflict, keeping: .keepCurrent)
                }
            } label: {
                Label("Keep Current Version", systemImage: "checkmark.circle")
            }
        }

        Divider()

        if let onDelete {
            Button(role: .destructive) {
                onDelete(notePath, noteTitle)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

extension View {
    /// Attach note row context menu and swipe actions.
    func noteRowActions(
        notePath: String,
        noteTitle: String,
        onRename: ((String, String) -> Void)? = nil,
        onDelete: ((String, String) -> Void)? = nil,
        onMove: ((String) -> Void)? = nil
    ) -> some View {
        modifier(NoteRowActionsModifier(
            notePath: notePath,
            noteTitle: noteTitle,
            onRename: onRename,
            onDelete: onDelete,
            onMove: onMove
        ))
    }
}
