import SwiftUI
import MahoNotesKit

/// B — Tree navigator panel (~240pt) showing collections and recent notes.
struct NavigatorView: View {
    @Environment(AppState.self) private var appState
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
                .draggable(node.id) // collection id as drag payload
                .dropDestination(for: String.self) { droppedIds, _ in
                    guard let droppedId = droppedIds.first,
                          droppedId != node.id else { return false }
                    // Move dragged collection to just before this one
                    var ids = appState.fileTree.map { $0.id }
                    guard let fromIdx = ids.firstIndex(of: droppedId),
                          let toIdx = ids.firstIndex(of: node.id) else { return false }
                    ids.remove(at: fromIdx)
                    ids.insert(droppedId, at: toIdx)
                    appState.reorderCollections(orderedIds: ids)
                    return true
                }
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
    var isTopLevel: Bool = false
    var onNewNote: ((String) -> Void)?
    var onNewSubCollection: ((String) -> Void)?
    var onReorderNotes: ((String, [String]) -> Void)?
    var onDeleteNote: ((String, String) -> Void)?       // (relativePath, title)
    var onDeleteCollection: ((String, String, Bool, Bool) -> Void)?  // (id, name, isTopLevel, hasContents)
    @State private var isExpanded: Bool = false

    var body: some View {
        if node.isDirectory {
            directoryRow
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

                    Divider()

                    Button(role: .destructive) {
                        let hasContents = !node.children.isEmpty
                        onDeleteCollection?(node.id, node.name, isTopLevel, hasContents)
                    } label: {
                        Label("Delete Collection", systemImage: "trash")
                    }
                }
            if isExpanded {
                // Children (subdirectories and notes)
                let noteChildren = node.children.filter { !$0.isDirectory }
                let dirChildren = node.children.filter { $0.isDirectory }

                // Sub-collections first
                ForEach(dirChildren, id: \.id) { child in
                    TreeNodeView(
                        node: child,
                        appState: appState,
                        isTopLevel: false,
                        onNewNote: onNewNote,
                        onNewSubCollection: onNewSubCollection,
                        onReorderNotes: onReorderNotes,
                        onDeleteNote: onDeleteNote,
                        onDeleteCollection: onDeleteCollection
                    )
                    .padding(.leading, 12)
                }

                // "+ Add Note" row (after sub-collections, before notes)
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

                // Notes — draggable for reorder (per-item drag/drop to scope within collection)
                ForEach(noteChildren, id: \.id) { child in
                    noteLeafRowFor(child)
                        .padding(.leading, 12)
                        .draggable(child.id)
                        .dropDestination(for: String.self) { droppedIds, _ in
                            guard let droppedId = droppedIds.first,
                                  droppedId != child.id else { return false }
                            var paths = noteChildren.compactMap { $0.note?.relativePath ?? $0.id }
                            guard let fromIdx = paths.firstIndex(of: droppedId),
                                  let toIdx = paths.firstIndex(of: child.id) else { return false }
                            paths.remove(at: fromIdx)
                            paths.insert(droppedId, at: toIdx)
                            onReorderNotes?(node.id, paths)
                            return true
                        }
                }
            }
        } else {
            noteLeafRow
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
