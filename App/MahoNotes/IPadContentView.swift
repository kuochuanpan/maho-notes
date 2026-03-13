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
    @State private var sheets = SheetCoordinator()

    var body: some View {
        @Bindable var sheets = sheets
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // A — Vault Rail
            IPadVaultRail(showingSettings: $sheets.showingSettings)
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
                                sheets.showingNewCollection = true
                                sheets.newCollectionName = ""
                                sheets.newCollectionIcon = "folder"
                                sheets.collectionError = nil
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
                        sheets.showingAddVault = true
                    },
                    onCreateCollection: {
                        sheets.showingNewCollection = true
                        sheets.newCollectionName = ""
                        sheets.newCollectionIcon = "folder"
                        sheets.collectionError = nil
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
        .sheet(isPresented: $sheets.showingSettings) {
            iOSSettingsView(onDismiss: { sheets.showingSettings = false })
        }
        .sheet(isPresented: $sheets.showingAddVault) {
            IPadAddVaultSheet(isPresented: $sheets.showingAddVault)
        }
        .sheet(isPresented: $sheets.showingNewNote) {
            newNoteSheet
        }
        .sheet(isPresented: $sheets.showingNewCollection) {
            newCollectionSheet
        }
        .alert("Rename Note", isPresented: $sheets.showingRenameNote) {
            TextField("Title", text: $sheets.renameNoteTitle)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                let trimmed = sheets.renameNoteTitle.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                appState.renameNote(relativePath: sheets.renameNotePath, newTitle: trimmed)
            }
        }
        .alert("Delete \"\(sheets.deleteNoteTitle)\"?", isPresented: $sheets.showingDeleteNote) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    try appState.deleteNote(relativePath: sheets.deleteNotePath)
                } catch {
                    print("[MahoNotes] deleteNote failed: \(error)")
                }
            }
        } message: {
            Text("This note will be moved to Trash.")
        }
        .alert("Rename Collection", isPresented: $sheets.showingRenameCollection) {
            TextField("Name", text: $sheets.renameCollectionName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                let trimmed = sheets.renameCollectionName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                try? appState.renameCollection(collectionId: sheets.renameCollectionId, newName: trimmed)
            }
        }
        .alert(
            "Delete \"\(sheets.deleteCollectionName)\"?",
            isPresented: $sheets.showingDeleteCollection
        ) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    if sheets.deleteCollectionIsTopLevel {
                        try appState.deleteTopLevelCollection(collectionId: sheets.deleteCollectionId)
                    } else {
                        try appState.deleteSubCollection(collectionId: sheets.deleteCollectionId)
                    }
                } catch {
                    print("[MahoNotes] deleteCollection failed: \(error)")
                }
            }
        } message: {
            if sheets.deleteCollectionHasContents {
                Text("Notes inside will be moved to the parent collection.")
            } else {
                Text("This empty collection will be deleted.")
            }
        }
        .sheet(isPresented: $sheets.showingChangeIcon) {
            IconPickerSheet(
                title: "Change Icon",
                selectedIcon: $sheets.changeIconValue,
                onSave: {
                    try? appState.changeCollectionIcon(collectionId: sheets.changeIconCollectionId, newIcon: sheets.changeIconValue)
                    sheets.showingChangeIcon = false
                },
                onCancel: { sheets.showingChangeIcon = false }
            )
        }
        .sheet(isPresented: $sheets.showingNewSubCollection) {
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
                sheets.showingNewCollection = true
                sheets.newCollectionName = ""
                sheets.newCollectionIcon = "folder"
                sheets.collectionError = nil
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
            sheets.newNoteCollectionId = first.id
        }
        sheets.newNoteTitle = ""
        sheets.noteError = nil
        sheets.newNoteFromContextMenu = false
        sheets.showingNewNote = true
    }

    private var newNoteSheet: some View {
        return NavigationStack {
            Form {
                if sheets.newNoteFromContextMenu {
                    HStack {
                        Text("Location")
                        Spacer()
                        Text(sheets.newNoteCollectionId.split(separator: "/").map(String.init).last ?? sheets.newNoteCollectionId)
                            .foregroundStyle(.secondary)
                    }
                } else if appState.collections.count > 1 {
                    Picker("Collection", selection: $sheets.newNoteCollectionId) {
                        ForEach(appState.collections, id: \.id) { col in
                            Text(col.name).tag(col.id)
                        }
                    }
                }
                TextField("Note Title", text: $sheets.newNoteTitle)
                if let error = sheets.noteError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { sheets.showingNewNote = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let title = sheets.newNoteTitle.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        do {
                            let path = try appState.createNote(title: title, collectionId: sheets.newNoteCollectionId)
                            selectedNotePath = path
                            sheets.showingNewNote = false
                            // Auto-enter edit mode for new note
                            appState.editorState.viewMode = .editor
                            appState.editorState.startEditing()
                        } catch {
                            sheets.noteError = error.localizedDescription
                        }
                    }
                    .disabled(sheets.newNoteTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - New Collection

    private var newCollectionSheet: some View {
        NavigationStack {
            Form {
                TextField("Collection Name", text: $sheets.newCollectionName)
                if let error = sheets.collectionError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { sheets.showingNewCollection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = sheets.newCollectionName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        do {
                            try appState.createCollection(name: name, icon: sheets.newCollectionIcon)
                            sheets.showingNewCollection = false
                        } catch {
                            sheets.collectionError = error.localizedDescription
                        }
                    }
                    .disabled(sheets.newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - New Sub-Collection Sheet

    private var newSubCollectionSheet: some View {
        NavigationStack {
            Form {
                TextField("Sub-Collection Name", text: $sheets.newSubCollectionName)
                if let error = sheets.subCollectionError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .navigationTitle("New Sub-Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { sheets.showingNewSubCollection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let name = sheets.newSubCollectionName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        do {
                            try appState.createSubCollection(name: name, parentId: sheets.newSubCollectionParentId)
                            sheets.showingNewSubCollection = false
                        } catch {
                            sheets.subCollectionError = error.localizedDescription
                        }
                    }
                    .disabled(sheets.newSubCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
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
                            sheets.showingAddVault = true
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
                        sheets.newNoteCollectionId = node.id
                        sheets.newNoteTitle = ""
                        sheets.noteError = nil
                        sheets.newNoteFromContextMenu = true
                        sheets.showingNewNote = true
                    } label: {
                        Label("New Note", systemImage: "doc.badge.plus")
                    }
                    Button {
                        sheets.newSubCollectionParentId = node.id
                        sheets.newSubCollectionName = ""
                        sheets.subCollectionError = nil
                        sheets.showingNewSubCollection = true
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
                        sheets.renameCollectionId = node.id
                        sheets.renameCollectionName = node.name
                        sheets.showingRenameCollection = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    if isTopLevel {
                        Button {
                            sheets.changeIconCollectionId = node.id
                            sheets.changeIconValue = node.icon
                            sheets.showingChangeIcon = true
                        } label: {
                            Label("Change Icon", systemImage: "photo")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        sheets.deleteCollectionId = node.id
                        sheets.deleteCollectionName = node.name
                        sheets.deleteCollectionIsTopLevel = isTopLevel
                        sheets.deleteCollectionHasContents = !node.children.isEmpty
                        sheets.showingDeleteCollection = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                // Swipe actions on the label only — prevents leaking to child note rows
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        sheets.deleteCollectionId = node.id
                        sheets.deleteCollectionName = node.name
                        sheets.deleteCollectionIsTopLevel = isTopLevel
                        sheets.deleteCollectionHasContents = !node.children.isEmpty
                        sheets.showingDeleteCollection = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        sheets.renameCollectionId = node.id
                        sheets.renameCollectionName = node.name
                        sheets.showingRenameCollection = true
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
                sheets.deleteNotePath = note.relativePath
                sheets.deleteNoteTitle = note.title
                sheets.showingDeleteNote = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                sheets.renameNotePath = note.relativePath
                sheets.renameNoteTitle = note.title
                sheets.showingRenameNote = true
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
                sheets.renameNotePath = note.relativePath
                sheets.renameNoteTitle = note.title
                sheets.showingRenameNote = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                sheets.deleteNotePath = note.relativePath
                sheets.deleteNoteTitle = note.title
                sheets.showingDeleteNote = true
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
