import SwiftUI
import MahoNotesKit
import UniformTypeIdentifiers
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

    /// Uses a plain List with manual selection via `.listRowBackground()`.
    /// `List(selection:)` was removed because macOS sidebar style draws
    /// NSTableView's system-accent selection ON TOP of `.listRowBackground()`,
    /// making it impossible to override the color via SwiftUI alone.
    /// Selection is handled by explicit `.onTapGesture` on each row.
    private var scrollContent: some View {
        return List {
            collectionsSection
            recentSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
                if appState.selectedVault?.access != .readOnly {
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
        .listRowBackground(
            MahoTheme.accent(for: colorScheme)
                .opacity(appState.navigatorSelection.contains(note.relativePath) ? 0.25 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        )
        .onTapGesture {
            appState.navigatorSelection = [note.relativePath]
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

            Text("in \(appState.displayName(forCollectionId: newNoteCollectionId))")
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
            // Auto-enter edit mode for new note
            appState.editorState.viewMode = .editor
            appState.editorState.startEditing()
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
