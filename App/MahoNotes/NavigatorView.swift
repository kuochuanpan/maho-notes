import SwiftUI
import MahoNotesKit
import UniformTypeIdentifiers

// MARK: - Drag State

/// Tracks the currently dragged item(s) for visual feedback and synchronous payload reading.
class DragState: ObservableObject {
    @Published var draggedItemId: String?   // "note:<path>" or "collection:<id>" or "notes:<path1>\t<path2>..."
    @Published var dropTargetId: String?    // id of the node being hovered

    /// Extract all note paths from the drag payload (supports single and multi).
    var draggedNotePaths: [String] {
        guard let payload = draggedItemId else { return [] }
        if payload.hasPrefix("notes:") {
            return String(payload.dropFirst(6)).components(separatedBy: "\t")
        } else if payload.hasPrefix("note:") {
            return [String(payload.dropFirst(5))]
        }
        return []
    }

    /// Whether the current drag is a note drag (single or multi).
    var isDraggingNotes: Bool {
        guard let payload = draggedItemId else { return false }
        return payload.hasPrefix("note:") || payload.hasPrefix("notes:")
    }
}

// MARK: - Directory Drop Delegate

/// Handles drops onto collection (directory) rows.
/// Reads `DragState.draggedItemId` synchronously — never uses NSItemProvider async loading.
private struct DirectoryDropDelegate: DropDelegate {
    let node: FileTreeNode
    let parentId: String?              // nil for top-level
    let siblingDirIds: [String]        // sibling directory IDs under the same parent
    let dragState: DragState
    let onMoveNote: (String, String) -> Void
    let onMoveNotes: ([String], String) -> Void   // batch move
    let onMoveCollection: (String, String) -> Void
    let onReorderTopLevel: ([String]) -> Void
    let onReorderSubCollections: (String, [String]) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        dragState.dropTargetId = node.id
    }

    func dropExited(info: DropInfo) {
        if dragState.dropTargetId == node.id {
            dragState.dropTargetId = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId else { return false }
        if payload.hasPrefix("collection:") {
            let collId = String(payload.dropFirst(11))
            return collId != node.id && !node.id.hasPrefix(collId + "/")
        }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId else { return false }
        defer {
            dragState.dropTargetId = nil
            dragState.draggedItemId = nil
        }

        // Handle note drops (single or multi)
        if dragState.isDraggingNotes {
            let paths = dragState.draggedNotePaths
            // Filter out notes already in this collection
            let toMove = paths.filter { (($0 as NSString).deletingLastPathComponent) != node.id }
            guard !toMove.isEmpty else { return false }
            if toMove.count == 1 {
                onMoveNote(toMove[0], node.id)
            } else {
                onMoveNotes(toMove, node.id)
            }
            return true
        }

        if payload.hasPrefix("collection:") {
            let collId = String(payload.dropFirst(11))
            guard collId != node.id, !node.id.hasPrefix(collId + "/") else { return false }

            // Same parent → reorder among siblings
            if siblingDirIds.contains(collId) {
                var ids = siblingDirIds
                guard let fromIdx = ids.firstIndex(of: collId),
                      let toIdx = ids.firstIndex(of: node.id) else { return false }
                ids.remove(at: fromIdx)
                ids.insert(collId, at: toIdx)

                if let parentId {
                    onReorderSubCollections(parentId, ids)
                } else {
                    onReorderTopLevel(ids)
                }
                return true
            }

            // Different parent → nest into this collection
            onMoveCollection(collId, node.id)
            return true
        }

        return false
    }
}

// MARK: - Note Drop Delegate

/// Handles drops onto note rows — reorder within same collection or move from another.
private struct NoteDropDelegate: DropDelegate {
    let noteNode: FileTreeNode
    let parentId: String
    let allNoteChildren: [FileTreeNode]
    let dragState: DragState
    let onReorderNotes: (String, [String]) -> Void
    let onMoveNote: (String, String) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        dragState.dropTargetId = noteNode.id
    }

    func dropExited(info: DropInfo) {
        if dragState.dropTargetId == noteNode.id {
            dragState.dropTargetId = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId else { return false }
        return payload.hasPrefix("note:")
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload = dragState.draggedItemId, payload.hasPrefix("note:") else { return false }
        defer {
            dragState.dropTargetId = nil
            dragState.draggedItemId = nil
        }

        let notePath = String(payload.dropFirst(5))
        let noteDir = (notePath as NSString).deletingLastPathComponent

        if noteDir == parentId {
            // Same collection → reorder: place at target position
            var paths = allNoteChildren.compactMap { $0.note?.relativePath ?? $0.id }
            guard let fromIdx = paths.firstIndex(of: notePath),
                  let toIdx = paths.firstIndex(of: noteNode.note?.relativePath ?? noteNode.id)
            else { return false }
            paths.remove(at: fromIdx)
            let insertIdx = fromIdx < toIdx ? toIdx : toIdx
            paths.insert(notePath, at: insertIdx)
            onReorderNotes(parentId, paths)
        } else {
            // Different collection → move to this note's parent
            onMoveNote(notePath, parentId)
        }
        return true
    }
}

// MARK: - Reject Drop Delegate

/// Placed on the "Add Note" button to reject all drops.
private struct RejectDropDelegate: DropDelegate {
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .cancel)
    }
    func performDrop(info: DropInfo) -> Bool { false }
}

// MARK: - Navigator View

/// B — Tree navigator panel (~240pt) showing collections and recent notes.
struct NavigatorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var dragState = DragState()
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionIcon = "folder"
    @State private var collectionError: String?
    @State private var showingNewNote = false
    @State private var newNoteTitle = ""
    @State private var newNoteCollectionId = ""
    @State private var noteError: String?
    @State private var showingNewSubCollection = false
    @State private var newSubCollectionName = ""
    @State private var newSubCollectionParent = ""
    @State private var subCollectionError: String?
    @State private var showingDeleteNote = false
    @State private var deleteNotePath = ""
    @State private var deleteNoteTitle = ""
    @State private var showingDeleteCollection = false
    @State private var deleteCollectionId = ""
    @State private var deleteCollectionName = ""
    @State private var deleteCollectionIsTopLevel = false
    @State private var deleteCollectionHasContents = false

    // Rename collection
    @State private var showingRenameCollection = false
    @State private var renameCollectionId = ""
    @State private var renameCollectionText = ""

    // Rename note
    @State private var showingRenameNote = false
    @State private var renameNotePath = ""
    @State private var renameNoteText = ""

    // Change collection icon
    @State private var showingChangeIcon = false
    @State private var changeIconCollectionId = ""
    @State private var changeIconSelection = "folder"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            scrollContent
        }
        .frame(width: appState.navigatorWidth)
        .background(MahoTheme.navigatorBackground(for: colorScheme))
        .sheet(isPresented: $showingNewCollection) {
            newCollectionSheet
        }
        .sheet(isPresented: $showingNewNote) {
            newNoteSheet
        }
        .sheet(isPresented: $showingNewSubCollection) {
            newSubCollectionSheet
        }
        .confirmationDialog(
            "Delete \"\(deleteNoteTitle)\"?",
            isPresented: $showingDeleteNote,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                try? appState.deleteNote(relativePath: deleteNotePath)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This note will be moved to the Trash.")
        }
        .confirmationDialog(
            "Delete \"\(deleteCollectionName)\"?",
            isPresented: $showingDeleteCollection,
            titleVisibility: .visible
        ) {
            if deleteCollectionIsTopLevel {
                Button("Move to Trash", role: .destructive) {
                    try? appState.deleteTopLevelCollection(collectionId: deleteCollectionId)
                }
            } else {
                if deleteCollectionHasContents {
                    Button("Move Notes to Parent & Delete", role: .destructive) {
                        try? appState.deleteSubCollection(collectionId: deleteCollectionId)
                    }
                } else {
                    Button("Delete", role: .destructive) {
                        try? appState.deleteSubCollection(collectionId: deleteCollectionId)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if deleteCollectionIsTopLevel && deleteCollectionHasContents {
                Text("This collection and all its notes will be moved to the Trash.")
            } else if deleteCollectionHasContents {
                Text("Notes inside will be moved to the parent collection.")
            } else {
                Text("This empty collection will be deleted.")
            }
        }
        .alert("Rename Collection", isPresented: $showingRenameCollection) {
            TextField("Name", text: $renameCollectionText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = renameCollectionText.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                try? appState.renameCollection(collectionId: renameCollectionId, newName: name)
            }
        }
        .alert("Rename Note", isPresented: $showingRenameNote) {
            TextField("Title", text: $renameNoteText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = renameNoteText.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return }
                appState.renameNote(relativePath: renameNotePath, newTitle: title)
            }
        }
        .sheet(isPresented: $showingChangeIcon) {
            changeIconSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let vault = appState.selectedVault {
                Image(systemName: vaultIcon(for: vault))
                    .foregroundStyle(.secondary)
                Text(vault.displayName ?? vault.name)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("No Vault")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - List Content

    /// Uses `List(selection:)` for native sidebar styling with ↑↓ keyboard navigation.
    private var scrollContent: some View {
        @Bindable var state = appState
        return List(selection: $state.navigatorSelection) {
            collectionsSection
            recentSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .tint(MahoTheme.accent(for: colorScheme))
        .onChange(of: appState.navigatorSelection) { _, newValue in
            appState.handleNavigatorSelectionChange(newValue)
        }
    }

    // MARK: - Collections Section

    @ViewBuilder
    private var collectionsSection: some View {
        Section {
            let topLevelIds = appState.fileTree.map(\.id)
            ForEach(appState.fileTree, id: \.id) { node in
                CollectionNodeView(
                    node: node,
                    appState: appState,
                    dragState: dragState,
                    isTopLevel: true,
                    parentId: nil,
                    siblingDirIds: topLevelIds,
                    indentLevel: 0,
                    onNewNote: { collectionId in
                        newNoteCollectionId = collectionId
                        newNoteTitle = ""
                        noteError = nil
                        showingNewNote = true
                    },
                    onNewSubCollection: { parentId in
                        newSubCollectionParent = parentId
                        newSubCollectionName = ""
                        subCollectionError = nil
                        showingNewSubCollection = true
                    },
                    onReorderNotes: { collectionId, orderedPaths in
                        appState.reorderNotes(collectionId: collectionId, orderedPaths: orderedPaths)
                    },
                    onMoveNote: { relativePath, targetCollection in
                        appState.moveNote(relativePath: relativePath, toCollection: targetCollection)
                    },
                    onMoveNotes: { paths, targetCollection in
                        appState.moveSelectedNotes(toCollection: targetCollection)
                    },
                    onMoveCollection: { collectionId, intoParent in
                        appState.moveCollection(collectionId: collectionId, intoParent: intoParent)
                    },
                    onPromoteToTopLevel: { collectionId in
                        appState.promoteToTopLevel(collectionId: collectionId)
                    },
                    onReorderTopLevel: { orderedIds in
                        appState.reorderCollections(orderedIds: orderedIds)
                    },
                    onReorderSubCollections: { parentId, orderedIds in
                        appState.reorderSubCollections(parentId: parentId, orderedIds: orderedIds)
                    },
                    onDeleteNote: { path, title in
                        deleteNotePath = path
                        deleteNoteTitle = title
                        showingDeleteNote = true
                    },
                    onDeleteCollection: { id, name, isTopLevel, hasContents in
                        deleteCollectionId = id
                        deleteCollectionName = name
                        deleteCollectionIsTopLevel = isTopLevel
                        deleteCollectionHasContents = hasContents
                        showingDeleteCollection = true
                    },
                    onRenameCollection: { id, currentName in
                        renameCollectionId = id
                        renameCollectionText = currentName
                        showingRenameCollection = true
                    },
                    onChangeIcon: { id, currentIcon in
                        changeIconCollectionId = id
                        changeIconSelection = currentIcon
                        showingChangeIcon = true
                    },
                    onRenameNote: { path, currentTitle in
                        renameNotePath = path
                        renameNoteText = currentTitle
                        showingRenameNote = true
                    }
                )
            }
        } header: {
            HStack {
                Text("COLLECTIONS")
                Spacer()
                Button {
                    newCollectionName = ""
                    newCollectionIcon = "folder"
                    collectionError = nil
                    showingNewCollection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Collection")
                .padding(.trailing, 4)
            }
        }
    }

    // MARK: - Recent Section

    @ViewBuilder
    private var recentSection: some View {
        if !appState.recentNotes.isEmpty {
            Section {
                ForEach(appState.recentNotes, id: \.relativePath) { note in
                    recentNoteRow(note)
                }
            } header: {
                Text("RECENT")
            }
        }
    }

    private func recentNoteRow(_ note: Note) -> some View {
        return Label {
            HStack(spacing: 4) {
                Text(note.title)
                    .lineLimit(1)
                if appState.conflict(for: note.relativePath) != nil
                   || appState.githubConflictFile(for: note.relativePath) != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
        }
        .tag(note.relativePath)
        .contentShape(Rectangle())
    }

    // MARK: - New Collection Sheet

    private var newCollectionSheet: some View {
        VStack(spacing: 16) {
            Text("New Collection")
                .font(.headline)

            TextField("Collection Name", text: $newCollectionName)
                .textFieldStyle(.roundedBorder)

            iconPicker

            if let error = collectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showingNewCollection = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createCollection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var iconPicker: some View {
        let icons = [
            "folder", "book.closed", "doc.text", "star", "lightbulb",
            "terminal", "globe", "flask", "graduationcap", "heart",
            "music.note", "photo", "gamecontroller", "wrench.and.screwdriver",
            "sparkles", "atom",
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 8), spacing: 6) {
                ForEach(icons, id: \.self) { icon in
                    Button {
                        newCollectionIcon = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                            .background(
                                newCollectionIcon == icon
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(newCollectionIcon == icon ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try appState.createCollection(name: name, icon: newCollectionIcon)
            showingNewCollection = false
        } catch {
            collectionError = error.localizedDescription
        }
    }

    // MARK: - New Note Sheet

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New Note")
                .font(.headline)

            Text("in \(newNoteCollectionId)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Note Title", text: $newNoteTitle)
                .textFieldStyle(.roundedBorder)

            if let error = noteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showingNewNote = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createNote()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newNoteTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func createNote() {
        let title = newNoteTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            try appState.createNote(title: title, collectionId: newNoteCollectionId)
            showingNewNote = false
        } catch {
            noteError = error.localizedDescription
        }
    }

    // MARK: - New Sub-Collection Sheet

    private var newSubCollectionSheet: some View {
        VStack(spacing: 16) {
            Text("New Sub-Collection")
                .font(.headline)

            Text("in \(newSubCollectionParent)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Sub-Collection Name", text: $newSubCollectionName)
                .textFieldStyle(.roundedBorder)

            if let error = subCollectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showingNewSubCollection = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createSubCollection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newSubCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func createSubCollection() {
        let name = newSubCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try appState.createSubCollection(name: name, parentId: newSubCollectionParent)
            showingNewSubCollection = false
        } catch {
            subCollectionError = error.localizedDescription
        }
    }

    // MARK: - Change Icon Sheet

    private var changeIconSheet: some View {
        VStack(spacing: 16) {
            Text("Change Icon")
                .font(.headline)

            changeIconPicker

            HStack {
                Button("Cancel") {
                    showingChangeIcon = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    try? appState.changeCollectionIcon(collectionId: changeIconCollectionId, newIcon: changeIconSelection)
                    showingChangeIcon = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var changeIconPicker: some View {
        let icons = [
            "folder", "book.closed", "doc.text", "star", "lightbulb",
            "terminal", "globe", "flask", "graduationcap", "heart",
            "music.note", "photo", "gamecontroller", "wrench.and.screwdriver",
            "sparkles", "atom",
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 8), spacing: 6) {
                ForEach(icons, id: \.self) { icon in
                    Button {
                        changeIconSelection = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                            .background(
                                changeIconSelection == icon
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(changeIconSelection == icon ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private func vaultIcon(for vault: VaultEntry) -> String {
        switch vault.type {
        case .icloud: "icloud"
        case .github: "arrow.triangle.branch"
        case .local: "folder"
        case .device: "internaldrive"
        }
    }
}

// MARK: - Collection Node View (recursive)

/// Renders a collection (directory) node with expand/collapse, drag/drop, and nested children.
private struct CollectionNodeView: View {
    let node: FileTreeNode
    let appState: AppState
    @ObservedObject var dragState: DragState
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
