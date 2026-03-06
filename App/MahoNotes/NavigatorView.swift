import SwiftUI
import MahoNotesKit
import UniformTypeIdentifiers

// MARK: - Drag State

/// Tracks the currently dragged item for visual feedback across the tree.
class DragState: ObservableObject {
    @Published var draggedItemId: String?
    @Published var dropTargetId: String?
    @Published var dropPosition: DropPosition = .on

    enum DropPosition {
        case above   // Insert before target (top 25% of row)
        case on      // Move into / nest (middle 50%)
        case below   // Insert after target (bottom 25% of row)
    }
}

// MARK: - Directory Drop Delegate

struct DirectoryDropDelegate: DropDelegate {
    let node: FileTreeNode
    let isTopLevel: Bool
    let topLevelIds: [String]
    let dragState: DragState
    let onMoveNote: ((String, String) -> Void)?
    let onMoveCollection: ((String, String) -> Void)?
    let onReorderCollections: (([String]) -> Void)?
    let onReorderSubCollections: ((String, [String]) -> Void)?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
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
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        dragState.dropTargetId = nil
        dragState.draggedItemId = nil

        guard let item = info.itemProviders(for: [UTType.text]).first else { return false }
        item.loadItem(forTypeIdentifier: UTType.text.identifier) { data, _ in
            guard let data = data as? Data,
                  let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                handleDrop(payload: str)
            }
        }
        return true
    }

    private func handleDrop(payload: String) {
        if payload.hasPrefix("note:") {
            let notePath = String(payload.dropFirst(5))
            let noteDir = (notePath as NSString).deletingLastPathComponent
            guard noteDir != node.id else { return }
            onMoveNote?(notePath, node.id)

        } else if payload.hasPrefix("collection:") {
            let collId = String(payload.dropFirst(11))
            // Can't drop into self or descendant
            guard collId != node.id,
                  !node.id.hasPrefix(collId + "/") else { return }

            // Top-level → top-level = reorder
            if isTopLevel && topLevelIds.contains(collId) {
                var ids = topLevelIds
                guard let fromIdx = ids.firstIndex(of: collId),
                      let toIdx = ids.firstIndex(of: node.id) else { return }
                ids.remove(at: fromIdx)
                ids.insert(collId, at: toIdx)
                onReorderCollections?(ids)
                return
            }

            // Same-parent sub-collections = reorder
            let draggedParent = (collId as NSString).deletingLastPathComponent
            let targetParent = (node.id as NSString).deletingLastPathComponent
            if !isTopLevel && draggedParent == targetParent {
                // Reorder among siblings — caller needs parent + ordered IDs
                // We don't have sibling list here, so treat as nest for now
                // The parent-level delegate handles sub-collection reorder
            }

            // Otherwise, nest the collection into this one
            onMoveCollection?(collId, node.id)
        }
    }
}

// MARK: - Note Drop Delegate

struct NoteDropDelegate: DropDelegate {
    let noteNode: FileTreeNode
    let parentId: String
    let allNoteChildren: [FileTreeNode]
    let dragState: DragState
    let onReorderNotes: ((String, [String]) -> Void)?
    let onMoveNote: ((String, String) -> Void)?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
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
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        dragState.dropTargetId = nil
        dragState.draggedItemId = nil

        guard let item = info.itemProviders(for: [UTType.text]).first else { return false }
        item.loadItem(forTypeIdentifier: UTType.text.identifier) { data, _ in
            guard let data = data as? Data,
                  let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                handleDrop(payload: str)
            }
        }
        return true
    }

    private func handleDrop(payload: String) {
        if payload.hasPrefix("note:") {
            let notePath = String(payload.dropFirst(5))
            let noteDir = (notePath as NSString).deletingLastPathComponent

            if noteDir == parentId {
                // Same collection → reorder: insert after this note
                var paths = allNoteChildren.compactMap { $0.note?.relativePath ?? $0.id }
                guard let fromIdx = paths.firstIndex(of: notePath),
                      let toIdx = paths.firstIndex(of: noteNode.note?.relativePath ?? noteNode.id)
                else { return }
                paths.remove(at: fromIdx)
                let insertIdx = fromIdx < toIdx ? toIdx : toIdx
                paths.insert(notePath, at: insertIdx)
                onReorderNotes?(parentId, paths)
            } else {
                // Different collection → move to this note's collection
                onMoveNote?(notePath, parentId)
            }

        } else if payload.hasPrefix("collection:") {
            // Can't drop collection on note — reject silently
            return
        }
    }
}

// MARK: - Add Note Drop Delegate (rejects all drops)

struct AddNoteDropDelegate: DropDelegate {
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

/// B — Tree navigator panel (~240pt) showing collections and recent notes.
struct NavigatorView: View {
    @Environment(AppState.self) private var appState
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: appState.navigatorWidth)
        .background(.background)
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let vault = appState.selectedVault {
                Image(systemName: vaultIcon(for: vault))
                    .foregroundStyle(.secondary)
                Text(vault.name)
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

    // MARK: - List

    private var list: some View {
        List(selection: Binding(
            get: { appState.selectedNotePath },
            set: { appState.selectNote(path: $0) }
        )) {
            collectionsSection
            recentSection
        }
        .listStyle(.sidebar)
    }

    // MARK: - Collections Section

    @ViewBuilder
    private var collectionsSection: some View {
        Section {
            ForEach(appState.fileTree, id: \.id) { node in
                TreeNodeView(
                    node: node,
                    appState: appState,
                    dragState: dragState,
                    isTopLevel: true,
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
                    onMoveCollection: { collectionId, intoParent in
                        appState.moveCollection(collectionId: collectionId, intoParent: intoParent)
                    },
                    onPromoteToTopLevel: { collectionId in
                        appState.promoteToTopLevel(collectionId: collectionId)
                    },
                    onReorderCollections: { orderedIds in
                        appState.reorderCollections(orderedIds: orderedIds)
                    },
                    onReorderSubCollections: { parentId, orderedIds in
                        appState.reorderSubCollections(parentId: parentId, orderedIds: orderedIds)
                    },
                    topLevelIds: appState.fileTree.map { $0.id },
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
                    noteRow(note)
                        .tag(note.relativePath)
                }
            } header: {
                Text("RECENT")
            }
        }
    }

    // MARK: - Note Row

    private func noteRow(_ note: Note) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(note.title)
                    .lineLimit(1)
                if appState.conflict(for: note.relativePath) != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
        }
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

// MARK: - Recursive Tree Node View

/// Renders a single node in the file tree — directories expand/collapse, notes are selectable leaves.
/// Uses a manual chevron + conditional children instead of DisclosureGroup to avoid
/// macOS sidebar List conflicts with the native disclosure triangle state.
private struct TreeNodeView: View {
    let node: FileTreeNode
    let appState: AppState
    @ObservedObject var dragState: DragState
    var isTopLevel: Bool = false
    var onNewNote: ((String) -> Void)?
    var onNewSubCollection: ((String) -> Void)?
    var onReorderNotes: ((String, [String]) -> Void)?
    var onMoveNote: ((String, String) -> Void)?              // (relativePath, targetCollectionId)
    var onMoveCollection: ((String, String) -> Void)?        // (collectionId, targetParentId)
    var onPromoteToTopLevel: ((String) -> Void)?             // (collectionId)
    var onReorderCollections: (([String]) -> Void)?          // top-level collection reorder
    var onReorderSubCollections: ((String, [String]) -> Void)?  // (parentId, orderedIds)
    var topLevelIds: [String] = []                           // for top-level reorder
    var onDeleteNote: ((String, String) -> Void)?            // (relativePath, title)
    var onDeleteCollection: ((String, String, Bool, Bool) -> Void)?  // (id, name, isTopLevel, hasContents)
    @State private var isExpanded: Bool = false

    var body: some View {
        if node.isDirectory {
            directoryRow
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: dragState.dropTargetId == node.id ? 2 : 0)
                )
                .contextMenu {
                    Button {
                        onNewNote?(node.id)
                    } label: {
                        Label("New Note", systemImage: "doc.badge.plus")
                    }
                    Button {
                        onNewSubCollection?(node.id)
                    } label: {
                        Label("New Sub-Collection", systemImage: "folder.badge.plus")
                    }

                    if !isTopLevel {
                        Divider()
                        Button {
                            onPromoteToTopLevel?(node.id)
                        } label: {
                            Label("Move to Top Level", systemImage: "arrow.up.to.line")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        let hasContents = !node.children.isEmpty
                        onDeleteCollection?(node.id, node.name, isTopLevel, hasContents)
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
                    isTopLevel: isTopLevel,
                    topLevelIds: topLevelIds,
                    dragState: dragState,
                    onMoveNote: onMoveNote,
                    onMoveCollection: onMoveCollection,
                    onReorderCollections: onReorderCollections,
                    onReorderSubCollections: onReorderSubCollections
                ))
            if isExpanded {
                expandedChildren
            }
        } else {
            noteLeafRow
                .onDrag {
                    let payload = "note:" + (node.note?.relativePath ?? node.id)
                    dragState.draggedItemId = payload
                    return NSItemProvider(object: payload as NSString)
                }
        }
    }

    // MARK: - Expanded Children

    @ViewBuilder
    private var expandedChildren: some View {
        let noteChildren = node.children.filter { !$0.isDirectory }
        let dirChildren = node.children.filter { $0.isDirectory }

        // Sub-collections first
        ForEach(dirChildren, id: \.id) { child in
            TreeNodeView(
                node: child,
                appState: appState,
                dragState: dragState,
                isTopLevel: false,
                onNewNote: onNewNote,
                onNewSubCollection: onNewSubCollection,
                onReorderNotes: onReorderNotes,
                onMoveNote: onMoveNote,
                onMoveCollection: onMoveCollection,
                onPromoteToTopLevel: onPromoteToTopLevel,
                onReorderCollections: onReorderCollections,
                onReorderSubCollections: onReorderSubCollections,
                topLevelIds: topLevelIds,
                onDeleteNote: onDeleteNote,
                onDeleteCollection: onDeleteCollection
            )
            .padding(.leading, 12)
        }

        // "+ Add Note" row — reject all drops
        Button {
            onNewNote?(node.id)
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
        .padding(.leading, 28)
        .onDrop(of: [UTType.text], delegate: AddNoteDropDelegate())

        // Notes
        ForEach(noteChildren, id: \.id) { child in
            noteLeafRowFor(child)
                .padding(.leading, 12)
                .onDrag {
                    let payload = "note:" + (child.note?.relativePath ?? child.id)
                    dragState.draggedItemId = payload
                    return NSItemProvider(object: payload as NSString)
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
                    }
                }
        }
    }

    // MARK: - Directory

    private var directoryRow: some View {
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
    }

    // MARK: - Note Leaf

    private var noteLeafRow: some View {
        noteLeafRowFor(node)
    }

    private func noteLeafRowFor(_ child: FileTreeNode) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(child.name)
                    .lineLimit(1)
                if let note = child.note,
                   appState.conflict(for: note.relativePath) != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
        .tag(child.note?.relativePath ?? child.id)
        .contextMenu {
            Button(role: .destructive) {
                onDeleteNote?(child.note?.relativePath ?? child.id, child.name)
            } label: {
                Label("Delete Note", systemImage: "trash")
            }
        }
    }
}
