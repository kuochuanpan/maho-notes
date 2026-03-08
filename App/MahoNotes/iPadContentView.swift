#if os(iOS)
import SwiftUI
import MahoNotesKit

/// iPad layout using 3-column NavigationSplitView matching macOS:
/// A (VaultRail) | B (Navigator) | C (NoteContent)
struct iPadContentView: View {
    @Environment(AppState.self) private var appState
    @State private var searchQuery = ""
    @State private var searchResults: [Note] = []
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectedNotePath: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
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
            // A — Vault Rail
            iPadVaultRail(showingSettings: $showingSettings)
                .navigationBarHidden(true)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 68, ideal: 68, max: 68)
        } content: {
            // B — Navigator
            navigatorContent
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
                }
        } detail: {
            // C — Note Content (no NavigationStack — avoids second nav bar / system toggle)
            NoteContentView()
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    // Show toggle in C only when B is hidden (detailOnly)
                    if columnVisibility == .detailOnly {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation { cycleColumns() }
                            } label: {
                                Image(systemName: "sidebar.left")
                            }
                        }
                    }
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
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
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

    // MARK: - Vault Title

    private var selectedVaultTitle: String {
        guard let vault = appState.selectedVault else { return "Maho Notes" }
        return vault.displayName ?? vault.name
    }

    // MARK: - View Mode Icon

    // MARK: - Column Visibility Cycle
    // A+B+C → B+C → C only → A+B+C
    private func cycleColumns() {
        switch columnVisibility {
        case .all: columnVisibility = .doubleColumn
        case .doubleColumn: columnVisibility = .detailOnly
        case .detailOnly: columnVisibility = .all
        default: columnVisibility = .all
        }
    }

    private var viewModeIcon: String {
        switch appState.viewMode {
        case .preview: return "eye"
        case .editor: return "pencil"
        case .split: return "rectangle.split.2x1"
        }
    }

    // MARK: - New Note

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

    // MARK: - B Column (Navigator)

    @ViewBuilder
    private var navigatorContent: some View {
        List(selection: $selectedNotePath) {
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
                    iPadCollectionRow(node: node, depth: 0)
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
        .frame(minHeight: 44)
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

// MARK: - A Column: iPad Vault Rail

private struct iPadVaultRail: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool
    @State private var showingAddVault = false
    @State private var addVaultMode: AddVaultMode?
    @State private var newVaultName = ""
    @State private var newVaultAuthor = ""
    @State private var githubRepo = ""
    @State private var githubVaultName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showingDeviceFlow = false
    @State private var showingRenameDialog = false
    @State private var renameTarget: VaultEntry?
    @State private var renameText = ""
    @State private var showingColorPicker = false
    @State private var colorPickerTarget: VaultEntry?

    private enum AddVaultMode: Identifiable {
        case create, github
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Add button
            Button {
                showingAddVault = true
                addVaultMode = nil
                resetForm()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(
                        appState.vaults.isEmpty
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .foregroundStyle(appState.vaults.isEmpty ? .white : .primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider()
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 8)

            // Scrollable vault icons
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    vaultGroup(appState.icloudVaults)
                    if !appState.icloudVaults.isEmpty && !appState.githubVaults.isEmpty {
                        railDivider
                    }
                    vaultGroup(appState.githubVaults)
                    if (!appState.icloudVaults.isEmpty || !appState.githubVaults.isEmpty)
                        && !appState.localVaults.isEmpty {
                        railDivider
                    }
                    vaultGroup(appState.localVaults)
                }
                .padding(.vertical, 8)
            }

            Spacer()

            // Settings gear at bottom
            Divider()
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 8)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .frame(width: 68)
        .background(MahoTheme.vaultRailBackground)
        .sheet(isPresented: $showingAddVault) {
            addVaultSheet
        }
        .onChange(of: appState.authManager.userCode) { _, newValue in
            showingDeviceFlow = newValue != nil
        }
        .onChange(of: appState.authManager.isAuthenticated) { _, authenticated in
            if authenticated { showingDeviceFlow = false }
        }
        .sheet(isPresented: $showingDeviceFlow, onDismiss: {
            if !appState.authManager.isAuthenticated {
                appState.authManager.cancelAuth()
                isCreating = false
            }
        }) {
            DeviceFlowSheet(authManager: appState.authManager)
        }
        .alert("Rename Vault", isPresented: $showingRenameDialog) {
            TextField("Display name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let target = renameTarget {
                    appState.renameVaultDisplay(name: target.name, displayName: renameText)
                }
            }
        } message: {
            Text("Enter a display name for this vault.")
        }
        .sheet(isPresented: $showingColorPicker) {
            colorPickerSheet
        }
    }

    // MARK: - Vault Group

    @ViewBuilder
    private func vaultGroup(_ entries: [VaultEntry]) -> some View {
        ForEach(entries, id: \.name) { entry in
            vaultIcon(entry)
        }
    }

    private var railDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.2))
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
    }

    // MARK: - Vault Icon

    private func vaultIcon(_ entry: VaultEntry) -> some View {
        Button {
            appState.selectedVaultName = entry.name
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(String((entry.displayName ?? entry.name).prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(resolvedColor(for: entry), in: RoundedRectangle(cornerRadius: 10))

                if entry.type == .icloud {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.black.opacity(0.5), in: Circle())
                        .offset(x: 2, y: 2)
                } else if entry.access == .readOnly {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.black.opacity(0.5), in: Circle())
                        .offset(x: 2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if appState.selectedVaultName == entry.name {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.blue)
                    .frame(width: 3, height: 24)
                    .offset(x: -8)
            }
        }
        .contextMenu {
            vaultContextMenu(entry)
        }
    }

    // MARK: - Vault Context Menu

    @ViewBuilder
    private func vaultContextMenu(_ entry: VaultEntry) -> some View {
        Text(entry.displayName ?? entry.name)
            .foregroundStyle(.secondary)

        Divider()

        Button {
            renameTarget = entry
            renameText = entry.displayName ?? ""
            showingRenameDialog = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            colorPickerTarget = entry
            showingColorPicker = true
        } label: {
            Label("Change Color", systemImage: "paintpalette")
        }

        if appState.primaryVaultName != entry.name {
            Button {
                appState.setPrimaryVault(name: entry.name)
            } label: {
                Label("Set as Primary", systemImage: "star")
            }
        }
    }

    // MARK: - Color Picker Sheet

    private var colorPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Choose a color for this vault")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 10), count: 6), spacing: 10) {
                    ForEach(colorOptions, id: \.name) { option in
                        Button {
                            if let target = colorPickerTarget {
                                appState.setVaultColor(name: target.name, color: option.name)
                            }
                            showingColorPicker = false
                        } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(option.color)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                                )
                                .overlay {
                                    if colorPickerTarget?.color == option.name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Vault Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingColorPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Add Vault Sheet

    private var addVaultSheet: some View {
        NavigationStack {
            Group {
                if addVaultMode == nil {
                    addVaultPicker
                } else if addVaultMode == .create {
                    createVaultForm
                } else {
                    githubImportForm
                }
            }
            .navigationTitle(addVaultTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if addVaultMode != nil {
                        Button("Back") { addVaultMode = nil; errorMessage = nil }
                    } else {
                        Button("Cancel") { showingAddVault = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if addVaultMode == .create {
                        Button("Create") { createVault() }
                            .disabled(newVaultName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    } else if addVaultMode == .github {
                        Button(isCreating ? "Cloning..." : "Import") { importFromGitHub() }
                            .disabled(githubRepo.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addVaultTitle: String {
        switch addVaultMode {
        case .none: return "Add Vault"
        case .create: return "Create New Vault"
        case .github: return "Import from GitHub"
        }
    }

    private var addVaultPicker: some View {
        List {
            Button {
                addVaultMode = .create
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: appState.cloudSyncMode == .icloud ? "icloud" : "internaldrive")
                        .font(.title3)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create New Vault")
                            .fontWeight(.medium)
                        Text(appState.cloudSyncMode == .icloud ? "Stored in iCloud" : "Stored on this device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .frame(minHeight: 44)

            Button {
                addVaultMode = .github
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.title3)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import from GitHub")
                            .fontWeight(.medium)
                        Text("Clone a repository as a vault")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .frame(minHeight: 44)
        }
    }

    private var createVaultForm: some View {
        Form {
            Section {
                TextField("e.g. personal, research", text: $newVaultName)
            } header: {
                Text("Vault Name")
            }

            Section {
                TextField("Your name", text: $newVaultAuthor)
            } header: {
                Text("Author Name (optional)")
            }

            Section {
                HStack {
                    Image(systemName: appState.cloudSyncMode == .icloud ? "icloud" : "internaldrive")
                        .foregroundStyle(.secondary)
                    Text(appState.cloudSyncMode == .icloud ? "Will sync via iCloud" : "Stored on this device only")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
    }

    private var githubImportForm: some View {
        Form {
            Section {
                TextField("user/repo", text: $githubRepo)
            } header: {
                Text("GitHub Repository")
            }

            Section {
                TextField("Defaults to repo name", text: $githubVaultName)
            } header: {
                Text("Vault Name (optional)")
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - Actions

    private func resetForm() {
        newVaultName = ""
        newVaultAuthor = ""
        githubRepo = ""
        githubVaultName = ""
        errorMessage = nil
        isCreating = false
    }

    private func createVault() {
        let name = newVaultName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        do {
            try appState.createNewVault(name: name, authorName: newVaultAuthor.trimmingCharacters(in: .whitespaces))
            showingAddVault = false
        } catch {
            errorMessage = error.localizedDescription
            isCreating = false
        }
    }

    private func importFromGitHub() {
        let repo = githubRepo.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        Task { @MainActor in
            do {
                if !appState.authManager.isAuthenticated {
                    // Close the add vault sheet first so DeviceFlow sheet can present
                    showingAddVault = false
                    // Small delay to let sheet dismiss animation complete
                    try await Task.sleep(for: .milliseconds(400))
                    try await appState.authManager.authenticate()
                    guard appState.authManager.isAuthenticated else {
                        isCreating = false
                        return
                    }
                    // Re-open add vault sheet to continue the import
                    showingAddVault = true
                    addVaultMode = .github
                    // Wait for sheet to present
                    try await Task.sleep(for: .milliseconds(400))
                }
                let vaultName = githubVaultName.trimmingCharacters(in: .whitespaces)
                try await appState.importGitHubVault(
                    repo: repo,
                    name: vaultName.isEmpty ? nil : vaultName
                )
                showingAddVault = false
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }

    // MARK: - Color Helpers

    private struct ColorOption {
        let name: String
        let color: Color
    }

    private var colorOptions: [ColorOption] {
        [
            ColorOption(name: "red", color: .red),
            ColorOption(name: "orange", color: .orange),
            ColorOption(name: "yellow", color: .yellow),
            ColorOption(name: "green", color: .green),
            ColorOption(name: "mint", color: .mint),
            ColorOption(name: "teal", color: .teal),
            ColorOption(name: "cyan", color: .cyan),
            ColorOption(name: "blue", color: .blue),
            ColorOption(name: "indigo", color: .indigo),
            ColorOption(name: "purple", color: .purple),
            ColorOption(name: "pink", color: .pink),
            ColorOption(name: "brown", color: .brown),
            ColorOption(name: "coral", color: Color(red: 1.0, green: 0.45, blue: 0.35)),
            ColorOption(name: "lavender", color: Color(red: 0.69, green: 0.56, blue: 0.87)),
            ColorOption(name: "sage", color: Color(red: 0.52, green: 0.69, blue: 0.52)),
            ColorOption(name: "sky", color: Color(red: 0.45, green: 0.72, blue: 0.95)),
            ColorOption(name: "slate", color: Color(red: 0.44, green: 0.50, blue: 0.56)),
            ColorOption(name: "charcoal", color: Color(red: 0.30, green: 0.30, blue: 0.35)),
        ]
    }

    private func colorFromName(_ name: String) -> Color? {
        colorOptions.first { $0.name == name }?.color
    }

    private func resolvedColor(for entry: VaultEntry) -> Color {
        if let colorName = entry.color, let c = colorFromName(colorName) {
            return c
        }
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
}

#endif
