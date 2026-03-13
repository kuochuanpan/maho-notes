#if os(iOS)
import SwiftUI
import MahoNotesKit

/// iPad layout using 3-column NavigationSplitView matching macOS:
/// A (VaultRail) | B (Navigator) | C (NoteContent)
struct IPadContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchQuery = ""
    @State private var searchResults: [Note] = []
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectedNotePath: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Independent cycle tracker (0=all, 1=doubleColumn, 2=detailOnly)
    /// because NavigationSplitViewVisibility is a preference the system can override
    @State private var columnCycleState: Int = 0
    @State private var showingNewNote = false
    @State private var newNoteTitle = ""
    @State private var newNoteCollectionId = ""
    @State private var newNoteFromContextMenu = false
    @State private var noteError: String?
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionIcon = "folder"
    @State private var collectionError: String?
    @State private var showingSettings = false
    @State private var showingAddVault = false

    // Rename / Delete note alerts
    @State private var showingRenameNote = false
    @State private var renameNotePath = ""
    @State private var renameNoteTitle = ""
    @State private var showingDeleteNote = false
    @State private var deleteNotePath = ""
    @State private var deleteNoteTitle = ""

    // Rename / Delete collection alerts
    @State private var showingRenameCollection = false
    @State private var renameCollectionId = ""
    @State private var renameCollectionName = ""
    @State private var showingDeleteCollection = false
    @State private var deleteCollectionId = ""
    @State private var deleteCollectionName = ""
    @State private var deleteCollectionIsTopLevel = false
    @State private var deleteCollectionHasContents = false
    @State private var showingChangeIcon = false
    @State private var changeIconCollectionId = ""
    @State private var changeIconValue = ""

    // Sub-collection creation
    @State private var showingNewSubCollection = false
    @State private var newSubCollectionName = ""
    @State private var newSubCollectionParentId = ""
    @State private var subCollectionError: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // A — Vault Rail
            IPadVaultRail(showingSettings: $showingSettings)
                .navigationBarHidden(true)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 68, ideal: 68, max: 68)
        } content: {
            // B — Navigator
            navigatorContent
                .scrollContentBackground(.hidden)
                .background(MahoTheme.navigatorBackground(for: colorScheme))
                .navigationTitle(selectedVaultTitle)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search notes...")
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation { cycleColumns() }
                        } label: {
                            Image(systemName: "sidebar.left")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                presentNewNote()
                            } label: {
                                Label("New Note", systemImage: "square.and.pencil")
                            }
                            .disabled(appState.selectedVault == nil || appState.collections.isEmpty)

                            Button {
                                showingNewCollection = true
                                newCollectionName = ""
                                newCollectionIcon = "folder"
                                collectionError = nil
                            } label: {
                                Label("New Collection", systemImage: "folder.badge.plus")
                            }
                            .disabled(appState.selectedVault == nil)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(appState.selectedVault == nil)
                    }
                }
        } detail: {
            // C — Note Content (nav bar hidden; toggle + actions live in breadcrumb bar)
            NoteContentView()
                .background(MahoTheme.contentBackground(for: colorScheme))
                .navigationBarHidden(true)
                .toolbar(removing: .sidebarToggle)
                .environment(\.sidebarToggleAction, columnCycleState == 2
                    ? { withAnimation { cycleColumns() } } : nil)
                .environment(\.inlineActionButtons, AnyView(detailInlineActions))
                .environment(\.emptyStateActions, EmptyStateActions(
                    onCreateVault: {
                        showingAddVault = true
                    },
                    onCreateCollection: {
                        showingNewCollection = true
                        newCollectionName = ""
                        newCollectionIcon = "folder"
                        collectionError = nil
                    },
                    onCreateNote: {
                        presentNewNote()
                    }
                ))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(newValue)
        }
        .onChange(of: selectedNotePath) { oldValue, newValue in
            // Auto-save before switching to a different note
            if oldValue != nil && oldValue != newValue && appState.editorState.hasUnsavedChanges {
                appState.editorState.saveNote()
            }
            appState.selectNote(path: newValue)
        }
        .sheet(isPresented: $showingSettings) {
            iOSSettingsView(onDismiss: { showingSettings = false })
        }
        .sheet(isPresented: $showingAddVault) {
            IPadAddVaultSheet(isPresented: $showingAddVault)
        }
        .sheet(isPresented: $showingNewNote) {
            newNoteSheet
        }
        .sheet(isPresented: $showingNewCollection) {
            newCollectionSheet
        }
        .alert("Rename Note", isPresented: $showingRenameNote) {
            TextField("Title", text: $renameNoteTitle)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                let trimmed = renameNoteTitle.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                appState.renameNote(relativePath: renameNotePath, newTitle: trimmed)
            }
        }
        .alert("Delete \"\(deleteNoteTitle)\"?", isPresented: $showingDeleteNote) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    try appState.deleteNote(relativePath: deleteNotePath)
                } catch {
                    print("[MahoNotes] deleteNote failed: \(error)")
                }
            }
        } message: {
            Text("This note will be moved to Trash.")
        }
        .alert("Rename Collection", isPresented: $showingRenameCollection) {
            TextField("Name", text: $renameCollectionName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                let trimmed = renameCollectionName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                try? appState.renameCollection(collectionId: renameCollectionId, newName: trimmed)
            }
        }
        .alert(
            "Delete \"\(deleteCollectionName)\"?",
            isPresented: $showingDeleteCollection
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    if deleteCollectionIsTopLevel {
                        try appState.deleteTopLevelCollection(collectionId: deleteCollectionId)
                    } else {
                        try appState.deleteSubCollection(collectionId: deleteCollectionId)
                    }
                } catch {
                    print("[MahoNotes] deleteCollection failed: \(error)")
                }
            }
        } message: {
            if deleteCollectionHasContents {
                Text("Notes inside will be moved to the parent collection.")
            } else {
                Text("This empty collection will be deleted.")
            }
        }
        .sheet(isPresented: $showingChangeIcon) {
            IconPickerSheet(
                title: "Change Icon",
                selectedIcon: $changeIconValue,
                onSave: {
                    try? appState.changeCollectionIcon(collectionId: changeIconCollectionId, newIcon: changeIconValue)
                    showingChangeIcon = false
                },
                onCancel: { showingChangeIcon = false }
            )
        }
        .sheet(isPresented: $showingNewSubCollection) {
            newSubCollectionSheet
        }
    }

    // MARK: - Vault Title

    private var selectedVaultTitle: String {
        guard let vault = appState.selectedVault else { return "Maho Notes" }
        return vault.displayName ?? vault.name
    }

    // MARK: - Detail Inline Action Buttons (in breadcrumb bar)
    private var detailInlineActions: some View {
        HStack(spacing: 16) {
            Button {
                presentNewNote()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(appState.selectedVault == nil || appState.collections.isEmpty)

            Button {
                appState.syncCoordinator.syncNow()
            } label: {
                if appState.syncCoordinator.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(appState.syncCoordinator.isSyncing)

            Button {
                showingNewCollection = true
                newCollectionName = ""
                newCollectionIcon = "folder"
                collectionError = nil
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .disabled(appState.selectedVault == nil)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Column Visibility Cycle
    // A+B+C → B+C → C only → A+B+C
    private func cycleColumns() {
        columnCycleState = (columnCycleState + 1) % 3
        switch columnCycleState {
        case 1: columnVisibility = .doubleColumn
        case 2: columnVisibility = .detailOnly
        case 0:
            // Restore all: system may ignore .all from .detailOnly directly.
            // Step through .doubleColumn first so the system restores B,
            // then set .all on next run loop to restore A.
            columnVisibility = .doubleColumn
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                columnVisibility = .all
            }
        default: columnVisibility = .all
        }
    }

    // MARK: - New Note

    private func presentNewNote() {
        if let first = appState.collections.first {
            newNoteCollectionId = first.id
        }
        newNoteTitle = ""
        noteError = nil
        newNoteFromContextMenu = false
        showingNewNote = true
    }

    private var newNoteSheet: some View {
        return NavigationStack {
            Form {
                if newNoteFromContextMenu {
                    HStack {
                        Text("Location")
                        Spacer()
                        Text(newNoteCollectionId.split(separator: "/").map(String.init).last ?? newNoteCollectionId)
                            .foregroundStyle(.secondary)
                    }
                } else if appState.collections.count > 1 {
                    Picker("Collection", selection: $newNoteCollectionId) {
                        ForEach(appState.collections, id: \.id) { col in
                            Text(col.name).tag(col.id)
                        }
                    }
                }
                TextField("Note Title", text: $newNoteTitle)
                if let error = noteError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let title = newNoteTitle.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        do {
                            let path = try appState.createNote(title: title, collectionId: newNoteCollectionId)
                            selectedNotePath = path
                            showingNewNote = false
                            // Auto-enter edit mode for new note
                            appState.editorState.viewMode = .editor
                            appState.editorState.startEditing()
                        } catch {
                            noteError = error.localizedDescription
                        }
                    }
                    .disabled(newNoteTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - New Collection

    private var newCollectionSheet: some View {
        NavigationStack {
            Form {
                TextField("Collection Name", text: $newCollectionName)
                if let error = collectionError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewCollection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        do {
                            try appState.createCollection(name: name, icon: newCollectionIcon)
                            showingNewCollection = false
                        } catch {
                            collectionError = error.localizedDescription
                        }
                    }
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - New Sub-Collection Sheet

    private var newSubCollectionSheet: some View {
        NavigationStack {
            Form {
                TextField("Sub-Collection Name", text: $newSubCollectionName)
                if let error = subCollectionError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Sub-Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewSubCollection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = newSubCollectionName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        do {
                            try appState.createSubCollection(name: name, parentId: newSubCollectionParentId)
                            showingNewSubCollection = false
                        } catch {
                            subCollectionError = error.localizedDescription
                        }
                    }
                    .disabled(newSubCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - B Column (Navigator)

    @ViewBuilder
    private var navigatorContent: some View {
        List(selection: $selectedNotePath) {
            if !searchQuery.isEmpty {
                searchResultsSection
            } else {
                if appState.selectedVault != nil {
                    collectionsSection
                } else if appState.vaults.isEmpty {
                    // No vaults at all — guide user to create one
                    Section {
                        Button {
                            showingAddVault = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(MahoTheme.accent(for: colorScheme))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add a Vault")
                                        .fontWeight(.medium)
                                    Text("Create a vault to start taking notes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    Section {
                        Text("Select a vault")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Collections Section

    @ViewBuilder
    private var collectionsSection: some View {
        Section("Collections") {
            ForEach(appState.fileTree, id: \.id) { node in
                if node.isDirectory {
                    collectionRow(node: node, depth: 0)
                }
            }
        }

        if !appState.recentNotes.isEmpty {
            Section("Recent") {
                ForEach(appState.recentNotes, id: \.relativePath) { note in
                    noteRow(note)
                        .tag(note.relativePath)
                }
            }
        }
    }

    // MARK: - Collection Tree Row (Recursive)

    private func collectionRow(node: FileTreeNode, depth: Int) -> AnyView {
        let isTopLevel = depth == 0
        let noteChildren = node.children.filter { !$0.isDirectory }
        return AnyView(
            DisclosureGroup {
                ForEach(node.children, id: \.id) { child in
                    if child.isDirectory {
                        collectionRow(node: child, depth: depth + 1)
                    } else if let note = child.note {
                        noteRow(note)
                            .tag(note.relativePath)
                    }
                }
            } label: {
                CollectionRowContent(
                    name: node.name,
                    icon: node.icon,
                    noteCount: noteChildren.count
                )
                .contextMenu {
                    Button {
                        newNoteCollectionId = node.id
                        newNoteTitle = ""
                        noteError = nil
                        newNoteFromContextMenu = true
                        showingNewNote = true
                    } label: {
                        Label("New Note", systemImage: "doc.badge.plus")
                    }
                    Button {
                        newSubCollectionParentId = node.id
                        newSubCollectionName = ""
                        subCollectionError = nil
                        showingNewSubCollection = true
                    } label: {
                        Label("New Sub-Collection", systemImage: "folder.badge.plus")
                    }

                    Divider()

                    Button {
                        appState.clipboard.pasteNotes(toCollection: node.id)
                    } label: {
                        if let clipboard = appState.clipboard.entries, clipboard.count > 1 {
                            Label("Paste \(clipboard.count) Notes", systemImage: "doc.on.clipboard")
                        } else {
                            Label("Paste Note", systemImage: "doc.on.clipboard")
                        }
                    }
                    .disabled(appState.clipboard.entries == nil)

                    Divider()

                    Button {
                        renameCollectionId = node.id
                        renameCollectionName = node.name
                        showingRenameCollection = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    if isTopLevel {
                        Button {
                            changeIconCollectionId = node.id
                            changeIconValue = node.icon
                            showingChangeIcon = true
                        } label: {
                            Label("Change Icon", systemImage: "photo")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        deleteCollectionId = node.id
                        deleteCollectionName = node.name
                        deleteCollectionIsTopLevel = isTopLevel
                        deleteCollectionHasContents = !node.children.isEmpty
                        showingDeleteCollection = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                // Swipe actions on the label only — prevents leaking to child note rows
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteCollectionId = node.id
                        deleteCollectionName = node.name
                        deleteCollectionIsTopLevel = isTopLevel
                        deleteCollectionHasContents = !node.children.isEmpty
                        showingDeleteCollection = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        renameCollectionId = node.id
                        renameCollectionName = node.name
                        showingRenameCollection = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        )
    }

    // MARK: - Note Row

    private func noteRow(_ note: Note) -> some View {
        NoteRowContent(
            note: note,
            hasConflict: appState.conflict(for: note.relativePath) != nil,
            hasGitHubConflict: appState.githubConflictFile(for: note.relativePath) != nil
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteNotePath = note.relativePath
                deleteNoteTitle = note.title
                showingDeleteNote = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                renameNotePath = note.relativePath
                renameNoteTitle = note.title
                showingRenameNote = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                appState.selectedNotePath = note.relativePath
                appState.clipboard.copySelectedNotes()
            } label: {
                Label("Copy Note", systemImage: "doc.on.doc")
            }
            Button {
                renameNotePath = note.relativePath
                renameNoteTitle = note.title
                showingRenameNote = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                deleteNotePath = note.relativePath
                deleteNoteTitle = note.title
                showingDeleteNote = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsSection: some View {
        if searchResults.isEmpty {
            Section {
                Text("No results found")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Results") {
                ForEach(searchResults, id: \.relativePath) { note in
                    noteRow(note)
                        .tag(note.relativePath)
                }
            }
        }
    }

    // MARK: - Debounced Search

    private func scheduleSearch(_ text: String) {
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let entry = appState.selectedVault else {
            searchResults = []
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let vault = Vault(path: appState.store.resolvedPath(for: entry))
            searchResults = (try? Array(vault.searchNotes(query: trimmed).prefix(20))) ?? []
        }
    }
}

#endif
