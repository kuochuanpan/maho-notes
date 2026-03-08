#if os(iOS)
import SwiftUI
import MahoNotesKit

/// iPad layout using NavigationSplitView with sidebar (vaults + collections) and detail (note content).
struct iPadContentView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var searchResults: [Note] = []
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectedNotePath: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationTitle("Maho Notes")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
        } detail: {
            NoteContentView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentNewNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.selectedVault == nil || appState.collections.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.cycleViewMode()
                } label: {
                    Image(systemName: viewModeIcon)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(appState.isReadOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
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
            }
            ToolbarItem(placement: .topBarTrailing) {
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
        }
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search notes...")
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(newValue)
        }
        .onChange(of: selectedNotePath) { _, newValue in
            appState.selectNote(path: newValue)
        }
        .sheet(isPresented: $showingSettings) {
            iOSSettingsView(onDismiss: { showingSettings = false })
        }
        .sheet(isPresented: $showingNewNote) {
            newNoteSheet
        }
        .sheet(isPresented: $showingNewCollection) {
            newCollectionSheet
        }
    }

    // MARK: - View Mode Icon

    private var viewModeIcon: String {
        switch appState.viewMode {
        case .preview: return "eye"
        case .editor: return "pencil"
        case .split: return "rectangle.split.2x1"
        }
    }

    // MARK: - New Note

    private func presentNewNote() {
        // Default to first collection
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
                            selectedNotePath = path
                            showingNewNote = false
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

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        List(selection: $selectedNotePath) {
            // Search results section (when searching)
            if !searchQuery.isEmpty {
                searchResultsSection
            } else {
                // Vault sections
                vaultSections

                // Collection tree for selected vault
                if appState.selectedVault != nil {
                    collectionsSection
                }

                // Settings link at bottom
                Section {
                    NavigationLink {
                        iOSSettingsView()
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
        }
    }

    // MARK: - Vault Sections

    @ViewBuilder
    private var vaultSections: some View {
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

    private func vaultRow(_ entry: VaultEntry) -> some View {
        Button {
            appState.selectedVaultName = entry.name
        } label: {
            HStack(spacing: 8) {
                vaultIcon(entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName ?? entry.name)
                        .fontWeight(appState.selectedVaultName == entry.name ? .semibold : .regular)
                    if entry.access == .readOnly {
                        Text("read-only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if appState.primaryVaultName == entry.name {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                if appState.selectedVaultName == entry.name {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            appState.selectedVaultName == entry.name
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
    }

    private func vaultIcon(_ entry: VaultEntry) -> some View {
        let letter = (entry.displayName ?? entry.name).prefix(1).uppercased()
        let bgColor = vaultColor(for: entry)
        return Text(letter)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(bgColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomTrailing) {
                if entry.type == .icloud {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.ultraThinMaterial, in: Circle())
                        .offset(x: 4, y: 4)
                } else if entry.access == .readOnly {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.ultraThinMaterial, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
    }

    private func vaultColor(for entry: VaultEntry) -> Color {
        if let colorName = entry.color, let c = colorFromName(colorName) {
            return c
        }
        // Hash-derived color fallback (same logic as VaultRailView)
        let colors: [Color] = [
            .blue, .purple, .pink, .red, .orange,
            .yellow, .green, .teal, .cyan, .indigo,
        ]
        var hash = 0
        for char in entry.name.unicodeScalars {
            hash = hash &* 31 &+ Int(char.value)
        }
        return colors[abs(hash) % colors.count]
    }

    private func colorFromName(_ name: String) -> Color? {
        let map: [String: Color] = [
            "red": .red, "orange": .orange, "yellow": .yellow,
            "green": .green, "mint": .mint, "teal": .teal,
            "blue": .blue, "indigo": .indigo, "purple": .purple,
            "pink": .pink, "brown": .brown, "cyan": .cyan,
            "gray": .gray, "black": .black, "white": .white,
            "mahoPlum": Color(red: 114/255, green: 31/255, blue: 109/255),
            "forest": Color(red: 34/255, green: 100/255, blue: 60/255),
            "navy": Color(red: 20/255, green: 40/255, blue: 100/255),
        ]
        return map[name]
    }

    // MARK: - Collections Section

    @ViewBuilder
    private var collectionsSection: some View {
        Section("Collections") {
            ForEach(appState.fileTree, id: \.id) { node in
                if node.isDirectory {
                    iPadCollectionRow(node: node, depth: 0)
                }
            }
        }

        // Recent notes
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

    private func iPadCollectionRow(node: FileTreeNode, depth: Int) -> AnyView {
        AnyView(
            DisclosureGroup {
                ForEach(node.children, id: \.id) { child in
                    if child.isDirectory {
                        iPadCollectionRow(node: child, depth: depth + 1)
                    } else if let note = child.note {
                        noteRow(note)
                            .tag(note.relativePath)
                    }
                }
            } label: {
                Label(node.name, systemImage: node.icon)
                    .font(.body)
            }
        )
    }

    // MARK: - Note Row

    private func noteRow(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .lineLimit(1)
            Text(note.updated)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44) // Touch-friendly tap target
        .contextMenu {
            if let conflict = appState.conflict(for: note.relativePath) {
                Button("Keep Current Version") {
                    appState.iCloudManager.resolveConflict(conflict, keeping: .keepCurrent)
                }
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
