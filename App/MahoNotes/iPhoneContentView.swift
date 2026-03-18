#if os(iOS)
import SwiftUI
import os
import MahoNotesKit

/// iPhone layout: ZStack with custom slide-over vault rail sidebar.
/// B-column navigator is always full-width, A-column overlays from the left.
struct iPhoneContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchQuery = ""
    @State private var searchResults: [Note] = []
    @State private var isSearching = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var navigationPath = NavigationPath()
    @State private var showSidebar = false
    @State private var sheets = SheetCoordinator()

    var body: some View {
        @Bindable var sheets = sheets
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

                IPadVaultRail(showingSettings: $sheets.showingSettings)
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
        .overlay {
            if appState.isAdoptingICloud {
                iCloudAdoptionOverlay
            }
        }
        .overlay(alignment: .top) {
            if appState.isReloading && !appState.isAdoptingICloud {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing vaults…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.3), value: appState.isReloading)
            }
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
        .sheet(isPresented: $sheets.showingSettings) {
            iOSSettingsView(onDismiss: { sheets.showingSettings = false })
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
                    Logger(subsystem: "dev.pcca.maho-notes", category: "app").error("deleteNote failed: \(error)")
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
                    Logger(subsystem: "dev.pcca.maho-notes", category: "app").error("deleteCollection failed: \(error)")
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

    // MARK: - iCloud Adoption Overlay

    private var iCloudAdoptionOverlay: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating)

                Text("Syncing from iCloud…")
                    .font(.title2.bold())

                if appState.adoptedVaultCount > 0 {
                    Text("Found \(appState.adoptedVaultCount) vault\(appState.adoptedVaultCount == 1 ? "" : "s") from your other devices.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 8)

                Text("This usually takes a few seconds")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.5), value: appState.isAdoptingICloud)
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
                           disabled: appState.selectedVault == nil || appState.collections.isEmpty || appState.selectedVault?.access == .readOnly) {
                presentNewNote()
            }

            floatingButton(icon: "folder.badge.plus",
                           disabled: appState.selectedVault == nil || appState.selectedVault?.access == .readOnly) {
                sheets.showingNewCollection = true
                sheets.newCollectionName = ""
                sheets.newCollectionIcon = "folder"
                sheets.collectionError = nil
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
                sheets.showingSettings = true
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
                            sheets.showingAddVault = true
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
                        .buttonStyle(.plain)
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
                    if appState.selectedVault?.access != .readOnly {
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
                            if let entries = appState.clipboard.entries, entries.count > 1 {
                                Label("Paste \(entries.count) Notes", systemImage: "doc.on.clipboard")
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
                }
                // Swipe actions on the label only — prevents leaking to child note rows
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if appState.selectedVault?.access != .readOnly {
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
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if appState.selectedVault?.access != .readOnly {
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
            if appState.selectedVault?.access != .readOnly {
                Button(role: .destructive) {
                    sheets.deleteNotePath = note.relativePath
                    sheets.deleteNoteTitle = note.title
                    sheets.showingDeleteNote = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if appState.selectedVault?.access != .readOnly {
                Button {
                    sheets.renameNotePath = note.relativePath
                    sheets.renameNoteTitle = note.title
                    sheets.showingRenameNote = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
        .contextMenu {
            Button {
                appState.selectedNotePath = note.relativePath
                appState.clipboard.copySelectedNotes()
            } label: {
                Label("Copy Note", systemImage: "doc.on.doc")
            }
            if appState.selectedVault?.access != .readOnly {
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
                        appState.editorState.cycleViewMode(compactWidth: horizontalSizeClass == .compact)
                    } label: {
                        Image(systemName: viewModeIcon)
                    }
                    .disabled(appState.editorState.isReadOnly)
                }
            }
            .onAppear {
                // Skip selectNote if already selected (e.g. from createNote which
                // sets viewMode = .editor — selectNote would reset it to .preview)
                if appState.selectedNotePath != notePath {
                    appState.selectNote(path: notePath)
                }
            }
            .onDisappear {
                // Auto-save when navigating back to B column
                if appState.editorState.hasUnsavedChanges {
                    appState.editorState.saveNote()
                }
            }
    }

    private var viewModeIcon: String {
        switch appState.editorState.viewMode {
        case .preview: return "eye"
        case .editor: return "pencil"
        case .split: return "rectangle.split.2x1"
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsSection: some View {
        if isSearching {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                }
            }
        } else if searchResults.isEmpty {
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
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        let locations = resolveSearchLocations()
        guard !locations.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Always try text search first (fast, reliable)
            let textResults = try? await VaultSearchService.search(
                query: trimmed, mode: .text, vaults: locations, limit: 20
            )

            // Then try semantic/hybrid if user selected it
            let mode = VaultSearchService.Mode(rawValue: appState.searchManager.searchMode) ?? .text
            if mode != .text {
                let provider = appState.searchManager.embeddingProviderForSearch()
                do {
                    let semanticResults = try await VaultSearchService.search(
                        query: trimmed, mode: mode, vaults: locations,
                        embeddingProvider: provider, limit: 20
                    )
                    if !semanticResults.isEmpty {
                        if !Task.isCancelled {
                            searchResults = semanticResults
                            isSearching = false
                        }
                        return
                    }
                } catch {
                    Log.search.error("iOS semantic search failed: \(error.localizedDescription)")
                }
            }

            // Use text results (or empty)
            if !Task.isCancelled {
                searchResults = textResults ?? []
                isSearching = false
            }
        }
    }

    /// Resolve vault locations for search.
    private func resolveSearchLocations() -> [VaultLocation] {
        let store = appState.store
        let scope = appState.searchManager.searchScope
        let entries: [VaultEntry]
        if scope == "allVaults" {
            entries = appState.vaults
        } else if let entry = appState.selectedVault {
            entries = [entry]
        } else {
            return []
        }
        return entries.map { VaultLocation(name: $0.name, path: store.resolvedPath(for: $0)) }
    }

    // MARK: - New Note Sheet

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
                    // Triggered from collection context menu — fixed location
                    HStack {
                        Text("Location")
                        Spacer()
                        Text(appState.displayName(forCollectionId: sheets.newNoteCollectionId))
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
                            sheets.showingNewNote = false
                            navigationPath.append(path)
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

    // MARK: - New Collection Sheet

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
                            Logger(subsystem: "dev.pcca.maho-notes", category: "app").error("sub-collection creation failed: \(error)")
                            sheets.subCollectionError = error.localizedDescription
                        }
                    }
                    .disabled(sheets.newSubCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
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
    @State private var isSearching = false
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

                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                } else if results.isEmpty && !query.isEmpty {
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
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        let store = appState.store
        let scope = appState.searchManager.searchScope
        let entries: [VaultEntry] = scope == "allVaults"
            ? appState.vaults
            : (appState.selectedVault.map { [$0] } ?? [])
        let locations = entries.map { VaultLocation(name: $0.name, path: store.resolvedPath(for: $0)) }
        guard !locations.isEmpty else { results = []; isSearching = false; return }
        isSearching = true
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            let textResults = try? await VaultSearchService.search(
                query: trimmed, mode: .text, vaults: locations, limit: 20
            )

            let mode = VaultSearchService.Mode(rawValue: appState.searchManager.searchMode) ?? .text
            if mode != .text {
                let provider = appState.searchManager.embeddingProviderForSearch()
                do {
                    let semanticResults = try await VaultSearchService.search(
                        query: trimmed, mode: mode, vaults: locations,
                        embeddingProvider: provider, limit: 20
                    )
                    if !semanticResults.isEmpty {
                        if !Task.isCancelled {
                            results = semanticResults
                            isSearching = false
                        }
                        return
                    }
                } catch {
                    Log.search.error("iOS search (iOSSearchView) failed: \(error.localizedDescription)")
                }
            }

            if !Task.isCancelled {
                results = textResults ?? []
                isSearching = false
            }
        }
    }
}
#endif
