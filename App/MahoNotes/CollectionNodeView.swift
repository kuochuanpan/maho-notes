import SwiftUI
import MahoNotesKit
import UniformTypeIdentifiers

// MARK: - Collection Node View (recursive)

/// Renders a collection (directory) node with expand/collapse, drag/drop, and nested children.
struct CollectionNodeView: View {
    let node: FileTreeNode
    let appState: AppState
    @ObservedObject var dragState: DragState
    @Environment(\.colorScheme) private var colorScheme
    let isTopLevel: Bool
    let parentId: String?          // nil for top-level
    let siblingDirIds: [String]    // sibling dir IDs for reorder detection
    let indentLevel: Int

    // Callbacks
    let onNewNote: (String) -> Void
    let onNewSubCollection: (String) -> Void
    let onReorderNotes: (String, [String]) -> Void
    let onMoveNote: (String, String) -> Void
    let onMoveNotes: ([String], String) -> Void    // batch move
    let onMoveCollection: (String, String) -> Void
    let onPromoteToTopLevel: (String) -> Void
    let onReorderTopLevel: ([String]) -> Void
    let onReorderSubCollections: (String, [String]) -> Void
    let onDeleteNote: (String, String) -> Void
    let onDeleteCollection: (String, String, Bool, Bool) -> Void
    let onRenameCollection: (String, String) -> Void   // (id, currentName)
    let onChangeIcon: (String, String) -> Void          // (id, currentIcon)
    let onRenameNote: (String, String) -> Void           // (path, currentTitle)

    @State private var isExpanded: Bool = false

    var body: some View {
        collectionRow
        if isExpanded {
            expandedChildren
        }
    }

    // MARK: - Collection Row

    private var collectionRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
                    .frame(width: 12)

                Image(systemName: node.icon)
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(indentLevel) * 14)
        .listRowBackground(
            dragState.dropTargetId == node.id
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .contextMenu {
            if appState.selectedVault?.access != .readOnly {
                Button {
                    onNewNote(node.id)
                } label: {
                    Label("New Note", systemImage: "doc.badge.plus")
                }
                Button {
                    onNewSubCollection(node.id)
                } label: {
                    Label("New Sub-Collection", systemImage: "folder.badge.plus")
                }

                Divider()

                Button {
                    appState.clipboard.pasteNotes(toCollection: node.id)
                } label: {
                    if let entries = appState.clipboard.entries, entries.count > 1 {
                        Label("Paste \(entries.count) Notes", systemImage: "doc.on.clipboard")
                    } else {
                        Label("Paste Note", systemImage: "doc.on.clipboard")
                    }
                }
                .disabled(appState.clipboard.entries == nil)

                Divider()

                Button {
                    onRenameCollection(node.id, node.name)
                } label: {
                    Label("Rename Collection", systemImage: "pencil")
                }

                if isTopLevel {
                    Button {
                        onChangeIcon(node.id, node.icon)
                    } label: {
                        Label("Change Icon", systemImage: "photo")
                    }
                }

                if !isTopLevel {
                    Divider()
                    Button {
                        onPromoteToTopLevel(node.id)
                    } label: {
                        Label("Move to Top Level", systemImage: "arrow.up.to.line")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    let hasContents = !node.children.isEmpty
                    onDeleteCollection(node.id, node.name, isTopLevel, hasContents)
                } label: {
                    Label("Delete Collection", systemImage: "trash")
                }
            }
        }
        .onDrag {
            dragState.draggedItemId = "collection:" + node.id
            return NSItemProvider(object: ("collection:" + node.id) as NSString)
        }
        .onDrop(of: [UTType.text], delegate: DirectoryDropDelegate(
            node: node,
            parentId: parentId,
            siblingDirIds: siblingDirIds,
            dragState: dragState,
            onMoveNote: onMoveNote,
            onMoveNotes: onMoveNotes,
            onMoveCollection: onMoveCollection,
            onReorderTopLevel: onReorderTopLevel,
            onReorderSubCollections: onReorderSubCollections
        ))
    }

    // MARK: - Expanded Children

    @ViewBuilder
    private var expandedChildren: some View {
        let dirChildren = node.children.filter(\.isDirectory)
        let noteChildren = node.children.filter { !$0.isDirectory }

        // Sub-collections first
        ForEach(dirChildren, id: \.id) { child in
            CollectionNodeView(
                node: child,
                appState: appState,
                dragState: dragState,
                isTopLevel: false,
                parentId: node.id,
                siblingDirIds: dirChildren.map(\.id),
                indentLevel: indentLevel + 1,
                onNewNote: onNewNote,
                onNewSubCollection: onNewSubCollection,
                onReorderNotes: onReorderNotes,
                onMoveNote: onMoveNote,
                onMoveNotes: onMoveNotes,
                onMoveCollection: onMoveCollection,
                onPromoteToTopLevel: onPromoteToTopLevel,
                onReorderTopLevel: onReorderTopLevel,
                onReorderSubCollections: onReorderSubCollections,
                onDeleteNote: onDeleteNote,
                onDeleteCollection: onDeleteCollection,
                onRenameCollection: onRenameCollection,
                onChangeIcon: onChangeIcon,
                onRenameNote: onRenameNote
            )
        }

        // "+ Add Note" button — rejects all drops
        if appState.selectedVault?.access != .readOnly {
            Button {
                onNewNote(node.id)
            } label: {
                Label {
                    Text("Add Note")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(indentLevel + 1) * 14 + 16)
            .onDrop(of: [UTType.text], delegate: RejectDropDelegate())
        }

        // Notes
        ForEach(noteChildren, id: \.id) { child in
            noteRow(child, noteChildren: noteChildren)
        }
    }

    // MARK: - Note Row

    private func noteRow(_ child: FileTreeNode, noteChildren: [FileTreeNode]) -> some View {
        let path = child.note?.relativePath ?? child.id

        return Label {
            HStack(spacing: 4) {
                Text(child.name)
                    .lineLimit(1)
                if let note = child.note,
                   appState.conflict(for: note.relativePath) != nil
                   || (child.note.map { appState.githubConflictFile(for: $0.relativePath) != nil } ?? false) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                // Show count badge when this is the active note in a multi-selection
                if appState.selectedNotePath == path && appState.selectedNotePaths.count > 1 {
                    Text("\(appState.selectedNotePaths.count)")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
        }
        .tag(path)
        .padding(.leading, CGFloat(indentLevel + 1) * 14)
        .contentShape(Rectangle())
        .listRowBackground(
            MahoTheme.accent(for: colorScheme)
                .opacity(appState.navigatorSelection.contains(path) ? 0.25 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        )
        #if os(macOS)
        .onTapGesture {
            // Explicit tap handler needed because .onDrag intercepts mouse-down,
            // preventing List(selection:) from receiving the click.
            if NSEvent.modifierFlags.contains(.command) {
                // Cmd+Click: toggle in multi-selection
                if appState.navigatorSelection.contains(path) {
                    appState.navigatorSelection.remove(path)
                } else {
                    appState.navigatorSelection.insert(path)
                }
            } else {
                // Normal click: single select
                appState.navigatorSelection = [path]
            }
        }
        #else
        .onTapGesture {
            appState.navigatorSelection = [path]
        }
        #endif
        .contextMenu {
            Button {
                if appState.selectedNotePaths.count > 1 && appState.selectedNotePaths.contains(path) {
                    appState.clipboard.copySelectedNotes()
                } else {
                    // Single note: temporarily set selection, copy, restore
                    let prevPaths = appState.selectedNotePaths
                    let prevPath = appState.selectedNotePath
                    appState.selectedNotePaths = []
                    appState.selectedNotePath = path
                    appState.clipboard.copySelectedNotes()
                    appState.selectedNotePaths = prevPaths
                    appState.selectedNotePath = prevPath
                }
            } label: {
                if appState.selectedNotePaths.count > 1 && appState.selectedNotePaths.contains(path) {
                    Label("Copy \(appState.selectedNotePaths.count) Notes", systemImage: "doc.on.doc")
                } else {
                    Label("Copy Note", systemImage: "doc.on.doc")
                }
            }

            if appState.selectedVault?.access != .readOnly {
                Button {
                    onRenameNote(path, child.name)
                } label: {
                    Label("Rename Note", systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    onDeleteNote(path, child.name)
                } label: {
                    Label("Delete Note", systemImage: "trash")
                }
            }
        }
        .onDrag {
            // If this note is part of a multi-selection, drag all selected notes
            if appState.selectedNotePaths.count > 1 && appState.selectedNotePaths.contains(path) {
                let allPaths = Array(appState.selectedNotePaths)
                let payload = "notes:" + allPaths.joined(separator: "\t")
                dragState.draggedItemId = payload
                return NSItemProvider(object: payload as NSString)
            } else {
                let payload = "note:" + path
                dragState.draggedItemId = payload
                return NSItemProvider(object: payload as NSString)
            }
        }
        .onDrop(of: [UTType.text], delegate: NoteDropDelegate(
            noteNode: child,
            parentId: node.id,
            allNoteChildren: noteChildren,
            dragState: dragState,
            onReorderNotes: onReorderNotes,
            onMoveNote: onMoveNote
        ))
        .overlay(alignment: .top) {
            if dragState.dropTargetId == child.id {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
            }
        }
    }
}
