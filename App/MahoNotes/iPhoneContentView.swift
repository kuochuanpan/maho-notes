#if os(iOS)
import SwiftUI
import MahoNotesKit

/// iPhone layout: NavigationStack with B-column navigator as main screen,
/// vault selection via sheet, note detail via push, bottom toolbar for actions.
struct iPhoneContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchQuery = ""
    @State private var searchResults: [Note] = []
    @State private var debounceTask: Task<Void, Never>?
    @State private var navigationPath = NavigationPath()
    @State private var showingVaultSheet = false
    @State private var showingNewNote = false
    @State private var newNoteTitle = ""
    @State private var newNoteCollectionId = ""
    @State private var noteError: String?
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionIcon = "folder"
    @State private var collectionError: String?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            navigatorContent
                .scrollContentBackground(.hidden)
                .background(MahoTheme.navigatorBackground(for: colorScheme))
                .navigationTitle(selectedVaultTitle)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search notes...")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        vaultButton
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        bottomToolbarContent
                    }
                }
                .navigationDestination(for: String.self) { notePath in
                    noteDetail(for: notePath)
                }
        }
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(newValue)
        }
        .sheet(isPresented: $showingVaultSheet) {
            vaultSelectionSheet
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
    }

    // MARK: - Vault Title

    private var selectedVaultTitle: String {
        guard let vault = appState.selectedVault else { return "Maho Notes" }
        return vault.displayName ?? vault.name
    }

    // MARK: - Vault Button (Leading)

    private var vaultButton: some View {
        Button {
            showingVaultSheet = true
        } label: {
            if let entry = appState.selectedVault {
                ZStack(alignment: .bottomTrailing) {
                    Text(String((entry.displayName ?? entry.name).prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(MahoTheme.resolvedVaultColor(for: entry), in: RoundedRectangle(cornerRadius: 6))

                    if entry.type == .icloud {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.white)
                            .padding(1)
                            .background(.black.opacity(0.5), in: Circle())
                            .offset(x: 2, y: 2)
                    }
                }
            } else {
                Image(systemName: "books.vertical")
            }
        }
    }

    // MARK: - Bottom Toolbar

    @ViewBuilder
    private var bottomToolbarContent: some View {
        Button {
            presentNewNote()
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }
        .disabled(appState.selectedVault == nil || appState.collections.isEmpty)

        Spacer()

        Button {
            showingNewCollection = true
            newCollectionName = ""
            newCollectionIcon = "folder"
            collectionError = nil
        } label: {
            Label("New Collection", systemImage: "folder.badge.plus")
        }
        .disabled(appState.selectedVault == nil)

        Spacer()

        Button {
            appState.syncCoordinator.syncNow()
        } label: {
            if appState.syncCoordinator.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(appState.syncCoordinator.isSyncing)

        Spacer()

        Button {
            showingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
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
        AnyView(
            DisclosureGroup {
                ForEach(node.children, id: \.id) { child in
                    if child.isDirectory {
                        collectionRow(node: child, depth: depth + 1)
                    } else if let note = child.note {
                        noteNavigationRow(note)
                    }
                }
            } label: {
                Label(node.name, systemImage: node.icon)
                    .font(.body)
            }
        )
    }

    // MARK: - Note Row (NavigationLink push)

    private func noteNavigationRow(_ note: Note) -> some View {
        NavigationLink(value: note.relativePath) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .lineLimit(1)
                Text(note.updated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .contextMenu {
            if let conflict = appState.conflict(for: note.relativePath) {
                Button("Keep Current Version") {
                    appState.iCloudManager.resolveConflict(conflict, keeping: .keepCurrent)
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
                        appState.cycleViewMode()
                    } label: {
                        Image(systemName: viewModeIcon)
                    }
                }
            }
            .onAppear {
                appState.selectNote(path: notePath)
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

    // MARK: - Vault Selection Sheet

    private var vaultSelectionSheet: some View {
        NavigationStack {
            List {
                if !appState.icloudVaults.isEmpty {
                    Section("iCloud") {
                        ForEach(appState.icloudVaults, id: \.name) { entry in
                            vaultRow(entry)
                        }
                    }
                }
                if !appState.githubVaults.isEmpty {
                    Section("GitHub") {
                        ForEach(appState.githubVaults, id: \.name) { entry in
                            vaultRow(entry)
                        }
                    }
                }
                if !appState.localVaults.isEmpty {
                    Section("Local") {
                        ForEach(appState.localVaults, id: \.name) { entry in
                            vaultRow(entry)
                        }
                    }
                }
            }
            .navigationTitle("Vaults")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingVaultSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func vaultRow(_ entry: VaultEntry) -> some View {
        Button {
            appState.selectedVaultName = entry.name
            showingVaultSheet = false
        } label: {
            HStack {
                Text(String((entry.displayName ?? entry.name).prefix(1)).uppercased())
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(MahoTheme.resolvedVaultColor(for: entry), in: RoundedRectangle(cornerRadius: 8))

                Text(entry.displayName ?? entry.name)
                    .foregroundStyle(.primary)

                Spacer()

                if appState.primaryVaultName == entry.name {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if entry.access == .readOnly {
                    Text("read-only")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if appState.selectedVaultName == entry.name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - New Note Sheet

    private func presentNewNote() {
        if let first = appState.collections.first {
            newNoteCollectionId = first.id
        }
        newNoteTitle = ""
        noteError = nil
        showingNewNote = true
    }

    private var newNoteSheet: some View {
        NavigationStack {
            Form {
                if appState.collections.count > 1 {
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
