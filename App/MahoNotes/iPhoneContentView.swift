#if os(iOS)
import SwiftUI
import MahoNotesKit

/// iPhone layout: ZStack with custom slide-over vault rail sidebar.
/// B-column navigator is always full-width, A-column overlays from the left.
struct iPhoneContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchQuery = ""
    @State private var searchResults: [Note] = []
    @State private var debounceTask: Task<Void, Never>?
    @State private var navigationPath = NavigationPath()
    @State private var showSidebar = false
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
        ZStack(alignment: .leading) {
            // B — Navigator + C — Note Detail (via NavigationStack push)
            NavigationStack(path: $navigationPath) {
                navigatorContent
                    .scrollContentBackground(.hidden)
                    .background(MahoTheme.navigatorBackground(for: colorScheme))
                    .navigationTitle(selectedVaultTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search notes...")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showSidebar.toggle()
                                }
                            } label: {
                                Image(systemName: "sidebar.left")
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        floatingToolbar
                            .padding(.bottom, 24)
                    }
                    .navigationDestination(for: String.self) { notePath in
                        noteDetail(for: notePath)
                    }
            }

            // A — Vault rail overlay (slides in from left)
            if showSidebar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showSidebar = false }
                    }

                IPadVaultRail(showingSettings: $showingSettings)
                    .frame(width: 68)
                    .background(MahoTheme.vaultRailBackground)
                    .transition(.move(edge: .leading))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.startLocation.x < 30 && value.translation.width > 50 {
                        withAnimation(.easeInOut(duration: 0.25)) { showSidebar = true }
                    }
                }
        )
        .onChange(of: appState.selectedVaultName) { _, _ in
            withAnimation(.easeInOut(duration: 0.25)) { showSidebar = false }
        }
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(newValue)
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
        .sheet(isPresented: $showingSettings) {
            iOSSettingsView(onDismiss: { showingSettings = false })
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

    // MARK: - Floating Toolbar (Liquid Glass)

    private var floatingToolbar: some View {
        HStack(spacing: 20) {
            floatingButton(icon: "square.and.pencil",
                           disabled: appState.selectedVault == nil || appState.collections.isEmpty) {
                presentNewNote()
            }

            floatingButton(icon: "folder.badge.plus",
                           disabled: appState.selectedVault == nil) {
                showingNewCollection = true
                newCollectionName = ""
                newCollectionIcon = "folder"
                collectionError = nil
            }

            // Sync with spinner
            Button {
                appState.syncCoordinator.syncNow()
            } label: {
                Group {
                    if appState.syncCoordinator.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(appState.syncCoordinator.isSyncing)

            floatingButton(icon: "gearshape", disabled: false) {
                showingSettings = true
            }
        }
        .padding(.horizontal, 8)
        .modifier(LiquidGlassModifier())
    }

    private func floatingButton(icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Applies iOS 26 Liquid Glass when available, falls back to ultraThinMaterial.
    private struct LiquidGlassModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26, *) {
                content.glassEffect(.regular, in: .capsule)
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
        }
    }

    // MARK: - Navigator (B Column)

    @ViewBuilder
    private var navigatorContent: some View {
        List {
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
                                        .foregroundStyle(.primary)
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
                    noteNavigationRow(note)
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
                        noteNavigationRow(note)
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
                        appState.pasteNotes(toCollection: node.id)
                    } label: {
                        if let clipboard = appState.noteClipboard, clipboard.count > 1 {
                            Label("Paste \(clipboard.count) Notes", systemImage: "doc.on.clipboard")
                        } else {
                            Label("Paste Note", systemImage: "doc.on.clipboard")
                        }
                    }
                    .disabled(appState.noteClipboard == nil)

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

    // MARK: - Note Row (NavigationLink push)

    private func noteNavigationRow(_ note: Note) -> some View {
        NavigationLink(value: note.relativePath) {
            NoteRowContent(
                note: note,
                hasConflict: appState.conflict(for: note.relativePath) != nil,
                hasGitHubConflict: appState.githubConflictFile(for: note.relativePath) != nil
            )
        }
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
                appState.copySelectedNotes()
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

    // MARK: - Note Detail (C Column via push)

    private func noteDetail(for notePath: String) -> some View {
        NoteContentView()
            .background(MahoTheme.contentBackground(for: colorScheme))
            .navigationTitle(appState.selectedNote?.title ?? "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.cycleViewMode(compactWidth: horizontalSizeClass == .compact)
                    } label: {
                        Image(systemName: viewModeIcon)
                    }
                }
            }
            .onAppear {
                appState.selectNote(path: notePath)
            }
            .onDisappear {
                // Auto-save when navigating back to B column
                if appState.hasUnsavedChanges {
                    appState.saveNote()
                }
            }
    }

    private var viewModeIcon: String {
        switch appState.viewMode {
        case .preview: return "eye"
        case .editor: return "pencil"
        case .split: return "rectangle.split.2x1"
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
                    noteNavigationRow(note)
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

    // MARK: - New Note Sheet

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
                    // Triggered from collection context menu — fixed location
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
                            showingNewNote = false
                            navigationPath.append(path)
                            // Auto-enter edit mode for new note
                            appState.viewMode = .editor
                            appState.startEditing()
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

    // MARK: - New Collection Sheet

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
                            print("[MahoNotes] iPhone: sub-collection error: \(error)")
                            subCollectionError = error.localizedDescription
                        }
                    }
                    .disabled(newSubCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - iOS Search

struct iOSSearchView: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var results: [Note] = []
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                ForEach(results, id: \.relativePath) { note in
                    NavigationLink {
                        NoteContentView()
                            .navigationTitle(note.title)
                            .navigationBarTitleDisplayMode(.inline)
                            .onAppear {
                                appState.selectNote(path: note.relativePath)
                            }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(note.collection)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if results.isEmpty && !query.isEmpty {
                    Text("No results found")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search across all notes...")
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
        }
    }

    private func scheduleSearch(_ text: String) {
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let entry = appState.selectedVault else {
            results = []
            return
        }
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let vault = Vault(path: appState.store.resolvedPath(for: entry))
            results = (try? Array(vault.searchNotes(query: trimmed).prefix(20))) ?? []
        }
    }
}
#endif
