import Foundation
import Observation
import MahoNotesKit

/// Central app state — loads vault registry, resolves vault paths, tracks selection.
@Observable
@MainActor final class AppState {

    // MARK: - VaultStore

    let store = VaultStore.shared

    // MARK: - Vault Registry

    /// All registered vaults from the vault registry.
    private(set) var vaults: [VaultEntry] = []

    /// The currently selected vault name.
    var selectedVaultName: String?

    /// Error message if vault registry failed to load.
    private(set) var errorMessage: String?

    /// Whether the initial load has completed.
    private(set) var isLoaded: Bool = false

    /// Monitors the vault registry file for external changes.
    private var registryPresenter: VaultRegistryPresenter?

    /// The primary vault name from the registry.
    private(set) var primaryVaultName: String?

    // MARK: - Vault Content

    /// Collections in the currently selected vault.
    private(set) var collections: [Collection] = []

    /// Hierarchical file tree for the currently selected vault.
    private(set) var fileTree: [FileTreeNode] = []

    /// All notes in the currently selected vault, grouped by collection.
    private(set) var notesByCollection: [String: [Note]] = [:]

    /// Recent notes (last 10 by updated date).
    var recentNotes: [Note] {
        allNotes
            .sorted { $0.updated > $1.updated }
            .prefix(10)
            .map { $0 }
    }

    /// All notes flat list.
    private(set) var allNotes: [Note] = []

    // MARK: - Managers

    let searchManager = SearchManager()
    let editorState = EditorState()
    let cloudSync = CloudSyncState()
    let clipboard = NoteClipboard()

    /// Wire weak back-references after init/load.
    func wireManagers() {
        searchManager.appState = self
        editorState.appState = self
        cloudSync.appState = self
        clipboard.appState = self
    }

    /// Update a note in both allNotes and notesByCollection.
    func updateNote(_ updated: Note, replacing relativePath: String) {
        if let idx = allNotes.firstIndex(where: { $0.relativePath == relativePath }) {
            allNotes[idx] = updated
        }
        var grouped = notesByCollection
        if var notes = grouped[updated.collection] {
            if let idx = notes.firstIndex(where: { $0.relativePath == updated.relativePath }) {
                notes[idx] = updated
                grouped[updated.collection] = notes
            }
        }
        notesByCollection = grouped
    }

    /// Update registry state from a manager (e.g. after cloud merge).
    func updateRegistryState(vaults: [VaultEntry], primaryVaultName: String) {
        self.vaults = vaults
        self.primaryVaultName = primaryVaultName
    }

    // MARK: - Panel Visibility

    /// Whether the vault rail (A) is visible.
    var showVaultRail: Bool = UserDefaults.standard.object(forKey: "showVaultRail") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVaultRail, forKey: "showVaultRail") }
    }

    /// Whether the navigator (B) is visible.
    var showNavigator: Bool = UserDefaults.standard.object(forKey: "showNavigator") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNavigator, forKey: "showNavigator") }
    }

    /// Navigator panel width (persisted via UserDefaults).
    static let navigatorWidthMin: CGFloat = 180
    static let navigatorWidthMax: CGFloat = 400
    var navigatorWidth: CGFloat = UserDefaults.standard.object(forKey: "navigatorWidth") as? CGFloat ?? 240 {
        didSet { UserDefaults.standard.set(navigatorWidth, forKey: "navigatorWidth") }
    }

    /// Tracks user's explicit panel state (before auto-collapse overrides).
    var userShowVaultRail: Bool = true
    var userShowNavigator: Bool = true

    /// Toggle navigator (B). ⌘⇧B
    func toggleNavigator() {
        showNavigator.toggle()
        userShowNavigator = showNavigator
    }

    /// Toggle vault rail (A). ⌘⇧A — hiding A also hides B; showing A also shows B.
    func toggleVaultRail() {
        showVaultRail.toggle()
        showNavigator = showVaultRail
        userShowVaultRail = showVaultRail
        userShowNavigator = showNavigator
    }

    /// Focus mode. ⌘\ — if any panel visible, hide both; if both hidden, show both.
    func toggleFocusMode() {
        if showVaultRail || showNavigator {
            showVaultRail = false
            showNavigator = false
        } else {
            showVaultRail = true
            showNavigator = true
        }
        userShowVaultRail = showVaultRail
        userShowNavigator = showNavigator
    }

    // MARK: - Note Selection

    /// Relative path of the currently selected (active) note — shown in C panel.
    var selectedNotePath: String?

    /// Multi-selection set for batch operations (Cmd+Click).
    /// The `selectedNotePath` is always included when this is non-empty.
    var selectedNotePaths: Set<String> = []

    /// Navigator List selection binding — drives native ↑↓ keyboard navigation.
    /// Synced bidirectionally with selectedNotePath/selectedNotePaths.
    var navigatorSelection: Set<String> = []

    /// Called from view's onChange(of: navigatorSelection) to sync back to selectedNotePath.
    func handleNavigatorSelectionChange(_ newSelection: Set<String>) {
        // Avoid re-entrant loops: only act if actually different
        if newSelection.count == 1, let path = newSelection.first {
            if selectedNotePath != path {
                // Auto-save when switching notes
                if selectedNotePath != nil && editorState.hasUnsavedChanges {
                    editorState.saveNote()
                }
                selectedNotePath = path
                selectedNotePaths = []
                editorState.viewMode = .preview
                editorState.editingBody = ""
            }
        } else if newSelection.isEmpty {
            if selectedNotePath != nil {
                if editorState.hasUnsavedChanges { editorState.saveNote() }
                selectedNotePath = nil
                selectedNotePaths = []
            }
        } else {
            // Multi-selection via Cmd+Click / Shift+Click
            selectedNotePaths = newSelection
            if let path = newSelection.first(where: { $0 != selectedNotePath }) ?? newSelection.first {
                if selectedNotePath != nil && selectedNotePath != path && editorState.hasUnsavedChanges {
                    editorState.saveNote()
                }
                selectedNotePath = path
                editorState.viewMode = .preview
                editorState.editingBody = ""
            }
        }
    }

    /// Whether a note path is part of the current selection (single or multi).
    func isNoteSelected(_ path: String) -> Bool {
        if !selectedNotePaths.isEmpty {
            return selectedNotePaths.contains(path)
        }
        return selectedNotePath == path
    }

    /// Normal click — single-select, clears multi-selection.
    func selectNote(path: String?) {
        // Auto-save when switching notes
        if selectedNotePath != nil && selectedNotePath != path && editorState.hasUnsavedChanges {
            editorState.saveNote()
        }
        selectedNotePath = path
        selectedNotePaths = []
        navigatorSelection = path == nil ? [] : [path!]
        // Reset view mode to preview when selecting a new note
        editorState.viewMode = .preview
        editorState.editingBody = ""
    }

    /// Cmd+Click — toggle note in multi-selection.
    func toggleNoteSelection(path: String) {
        if selectedNotePaths.isEmpty {
            // Start multi-select from current single selection
            if let current = selectedNotePath {
                selectedNotePaths = [current]
            }
        }

        if selectedNotePaths.contains(path) {
            selectedNotePaths.remove(path)
            // If we removed the active note, switch active to another selected note
            if selectedNotePath == path {
                selectedNotePath = selectedNotePaths.first
            }
            // If nothing left, clear multi-select
            if selectedNotePaths.isEmpty {
                selectedNotePath = nil
            }
        } else {
            selectedNotePaths.insert(path)
            // Auto-save before switching active note
            if selectedNotePath != nil && selectedNotePath != path && editorState.hasUnsavedChanges {
                editorState.saveNote()
            }
            selectedNotePath = path
            editorState.viewMode = .preview
            editorState.editingBody = ""
        }
        navigatorSelection = selectedNotePaths.isEmpty
            ? (selectedNotePath.map { [$0] } ?? [])
            : selectedNotePaths
    }

    /// Batch move selected notes to a target collection.
    func moveSelectedNotes(toCollection: String) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        let paths = selectedNotePaths.isEmpty
            ? (selectedNotePath.map { [$0] } ?? [])
            : Array(selectedNotePaths)

        var lastNewPath: String?
        for path in paths {
            lastNewPath = try? vault.moveNote(relativePath: path, toCollection: toCollection)
        }

        // Update selection to last moved note
        selectedNotePaths = []
        if let newPath = lastNewPath {
            selectedNotePath = newPath
            navigatorSelection = [newPath]
        }
        reloadCurrentVault()
    }

    /// The currently selected note (loaded on demand).
    var selectedNote: Note? {
        guard let path = selectedNotePath else { return nil }
        return allNotes.first { $0.relativePath == path }
    }

    // MARK: - Computed

    /// The currently selected vault entry.
    var selectedVault: VaultEntry? {
        guard let name = selectedVaultName else { return nil }
        return vaults.first { $0.name == name }
    }

    /// Vaults grouped by type for the rail.
    var icloudVaults: [VaultEntry] { vaults.filter { $0.type == .icloud } }
    var githubVaults: [VaultEntry] { vaults.filter { $0.type == .github } }
    var localVaults: [VaultEntry] { vaults.filter { $0.type == .local || $0.type == .device } }

    /// Author name from the current vault's maho.yaml (author.name key).
    var authorName: String? {
        guard let entry = selectedVault else { return nil }
        let vaultPath = store.resolvedPath(for: entry)
        let config = Config(vaultPath: vaultPath)
        guard let vaultConfig = try? config.loadVaultConfig(),
              let author = vaultConfig["author"] as? [String: Any],
              let name = author["name"] as? String,
              !name.isEmpty else { return nil }
        return name
    }

    let authManager = GitHubAuthManager()

    // MARK: - GitHub Sync

    let syncCoordinator = SyncCoordinator()

    // MARK: - iCloud Sync

    var iCloudManager = iCloudSyncManager()

    /// Whether any vault has iCloud or GitHub conflicts.
    var hasConflicts: Bool {
        !iCloudManager.conflicts.isEmpty ||
        !syncCoordinator.githubConflictFiles.values.flatMap { $0 }.isEmpty
    }

    /// Find iCloud conflict info for a specific note path.
    func conflict(for notePath: String) -> iCloudSyncManager.ConflictInfo? {
        iCloudManager.conflicts.first { $0.notePath == notePath }
    }

    /// Find a GitHub conflict file path for a specific note path.
    /// e.g. `notes/hello.md` → `notes/hello.conflict-Mahos-Mac-mini.md`
    func githubConflictFile(for notePath: String) -> String? {
        let allConflicts = syncCoordinator.githubConflictFiles.values.flatMap { $0 }
        let noteURL = URL(fileURLWithPath: notePath)
        let noteDir = noteURL.deletingLastPathComponent().relativePath
        let noteBase = noteURL.deletingPathExtension().lastPathComponent
        return allConflicts.first { conflictPath in
            let cURL = URL(fileURLWithPath: conflictPath)
            let cDir = cURL.deletingLastPathComponent().relativePath
            let cBase = cURL.deletingPathExtension().lastPathComponent
            return cDir == noteDir && cBase.hasPrefix("\(noteBase).conflict-")
        }
    }

    /// Start iCloud monitoring for the given vault entry if it's an iCloud vault.
    private func startICloudMonitoringIfNeeded(for entry: VaultEntry) {
        iCloudManager.stopMonitoring()

        guard entry.type == .icloud else { return }

        let vaultPath = store.resolvedPath(for: entry)
        let vaultURL = URL(fileURLWithPath: vaultPath)

        iCloudManager.startMonitoring(containerURL: vaultURL) { [weak self] in
            Task { @MainActor in
                self?.reloadCurrentVault()
            }
        }

        iCloudManager.checkForConflicts(in: vaultURL)
    }

    /// Reload the current vault's notes without changing selection.
    func reloadCurrentVault() {
        guard let entry = selectedVault else { return }

        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        let previousSelection = selectedNotePath

        do {
            self.collections = try vault.collections()
            self.allNotes = try vault.allNotes()
            self.fileTree = try vault.buildFileTree()

            var grouped: [String: [Note]] = [:]
            for note in allNotes {
                grouped[note.collection, default: []].append(note)
            }
            self.notesByCollection = grouped.mapValues { notes in
                notes.sorted { $0.title < $1.title }
            }
        } catch {
            // Keep existing state on error
        }

        // Restore selection if the note still exists
        if let prev = previousSelection, allNotes.contains(where: { $0.relativePath == prev }) {
            selectedNotePath = prev
            navigatorSelection = [prev]
        }

        // Refresh conflict list for iCloud vaults
        if entry.type == .icloud {
            let vaultURL = URL(fileURLWithPath: vaultPath)
            iCloudManager.checkForConflicts(in: vaultURL)
        }
    }

    // MARK: - Init

    nonisolated init() {}

    // MARK: - Loading

    /// Load the vault registry. Call on app launch.
    func loadRegistry() {
        Task { await loadRegistryAsync() }
    }

    /// Async implementation of loadRegistry.
    func loadRegistryAsync() async {
        wireManagers()
        do {
            let result: VaultRegistry? = try await store.loadRegistry()

            if let registry = result {
                self.vaults = registry.vaults
                self.primaryVaultName = registry.primary

                // Auto-select primary vault if nothing selected
                if selectedVaultName == nil {
                    selectedVaultName = registry.primary
                }
            } else {
                self.vaults = []
                self.primaryVaultName = nil
            }

            self.errorMessage = nil
            self.isLoaded = true
            let mode = await store.cloudSyncMode()
            self.cloudSync.cloudSyncMode = mode
            loadSelectedVault()
            syncCoordinator.startResolving(vaults: self.vaults)
            Task { await authManager.checkAuth() }

            // Start monitoring registry for external changes
            if registryPresenter == nil {
                let path = store.localRegistryPath
                let url = URL(fileURLWithPath: path)
                registryPresenter = VaultRegistryPresenter(registryURL: url, onChange: { [weak self] in
                    Task { @MainActor in
                        await self?.loadRegistryAsync()
                    }
                })
                registryPresenter?.startMonitoring()
            }
        } catch {
            self.errorMessage = "Failed to load vault registry: \(error.localizedDescription)"
            self.vaults = []
            self.isLoaded = true
        }
    }

    /// Reload the vault registry.
    func reloadRegistry() {
        loadRegistry()
    }

    /// Load collections and notes for the currently selected vault.
    func loadSelectedVault() {
        guard let entry = selectedVault else {
            collections = []
            fileTree = []
            notesByCollection = [:]
            allNotes = []
            selectedNotePath = nil
            navigatorSelection = []
            return
        }

        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)

        do {
            self.collections = try vault.collections()
            self.allNotes = try vault.allNotes()
            self.fileTree = try vault.buildFileTree()

            var grouped: [String: [Note]] = [:]
            for note in allNotes {
                grouped[note.collection, default: []].append(note)
            }
            self.notesByCollection = grouped.mapValues { notes in
                notes.sorted { $0.title < $1.title }
            }
        } catch {
            self.collections = []
            self.allNotes = []
            self.fileTree = []
            self.notesByCollection = [:]
        }

        selectedNotePath = nil
        navigatorSelection = []

        // Start iCloud monitoring if this is an iCloud vault
        startICloudMonitoringIfNeeded(for: entry)
    }

    /// Notes for a given collection id.
    func notes(for collectionId: String) -> [Note] {
        notesByCollection[collectionId] ?? []
    }

    // MARK: - Vault Management

    /// Remove a vault from the registry (does not delete files).
    func removeVault(name: String) {
        Task {
            guard var registry = try? await store.loadRegistry() else { return }
            try? registry.removeVault(named: name)
            // If removing the primary, reassign to first remaining vault
            if registry.primary == name, let first = registry.vaults.first {
                registry.primary = first.name
            }
            try? await store.saveRegistry(registry)
            if selectedVaultName == name {
                selectedVaultName = registry.primary
            }
            await loadRegistryAsync()
        }
    }

    /// Set a vault as the primary vault.
    func setPrimaryVault(name: String) {
        Task {
            guard var registry = try? await store.loadRegistry() else { return }
            try? registry.setPrimary(name)
            try? await store.saveRegistry(registry)
            await loadRegistryAsync()
        }
    }

    // MARK: - Vault Creation

    /// Create a new vault. Storage location is determined by cloudSyncMode.
    func createNewVault(name: String, authorName: String) throws {
        let globalConfigDir = mahoConfigBase()
        let storage: StorageOption = cloudSync.cloudSyncMode == .icloud ? .icloud : .local
        let vaultRoot = resolveVaultRoot(storage: storage)

        try createEmptyVault(
            name: name,
            vaultRoot: vaultRoot,
            authorName: authorName,
            skipTutorial: true,
            globalConfigDir: globalConfigDir
        )

        loadRegistry()
        selectedVaultName = name
    }

    /// Rename a vault's display name (UI only — does not affect internal name/paths/sync).
    func renameVaultDisplay(name: String, displayName: String) {
        let existing = vaults.first { $0.name == name }
        Task {
            try? await store.updateVaultEntry(named: name, displayName: displayName.isEmpty ? nil : displayName, color: existing?.color)
            await loadRegistryAsync()
        }
    }

    /// Set a custom color for a vault icon.
    func setVaultColor(name: String, color: String) {
        let existing = vaults.first { $0.name == name }

        // Optimistic update: immediately reflect in UI
        if let index = vaults.firstIndex(where: { $0.name == name }) {
            let old = vaults[index]
            vaults[index] = VaultEntry(
                name: old.name,
                type: old.type,
                github: old.github,
                path: old.path,
                access: old.access,
                displayName: old.displayName,
                color: color.isEmpty ? nil : color
            )
        }

        // Persist to disk asynchronously
        Task {
            try? await store.updateVaultEntry(named: name, displayName: existing?.displayName, color: color.isEmpty ? nil : color)
            await loadRegistryAsync()
        }
    }

    /// Import a vault from GitHub using the REST API (no git binary required).
    func importGitHubVault(repo: String, name: String?) async throws {
        let globalConfigDir = mahoConfigBase()
        // GitHub vaults always stored in .maho/vaults/ (not iCloud) —
        // they have their own sync via GitHub REST API.
        // resolvedPath(for:) uses mahoConfigBase() for .github type.
        let vaultRoot = resolveVaultRoot(storage: .local)

        // Use resolveStoredToken() — resolveToken() tries to spawn `gh` CLI subprocess
        // which crashes in a sandboxed app. The token is already stored in config.yaml
        // after the user completed Device Flow authentication.
        let token = try Auth().resolveStoredToken()

        let registeredName = try await importGitHubVaultViaAPI(
            repo: repo,
            vaultRoot: vaultRoot,
            name: name,
            token: token.token,
            globalConfigDir: globalConfigDir
        )

        loadRegistry()
        selectedVaultName = registeredName
    }

    // MARK: - Collection & Note Creation

    /// Create a new collection in the current vault.
    func createCollection(name: String, icon: String = "folder") throws {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        try addCollection(vaultPath: vaultPath, name: name, icon: icon)
        reloadCurrentVault()
    }

    /// Create a new note in a collection directory.
    /// - Parameters:
    ///   - title: Note title.
    ///   - collectionId: The collection directory name (relative path from vault root).
    /// - Returns: The relative path of the created note.
    @discardableResult
    func createNote(title: String, collectionId: String) throws -> String {
        guard let entry = selectedVault else { throw CollectionError.invalidName }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        let author = authorName ?? ""
        let relativePath = try vault.createNote(
            title: title,
            collection: collectionId,
            tags: [],
            author: author
        )

        // Auto-save any previous note before switching
        if selectedNotePath != nil && editorState.hasUnsavedChanges {
            editorState.saveNote()
        }

        reloadCurrentVault()

        // Directly enter editor mode — skip selectNote() to avoid
        // preview→editor flash that breaks @FocusState
        selectedNotePath = relativePath
        navigatorSelection = [relativePath]
        editorState.viewMode = .editor
        editorState.editingBody = selectedNote?.body ?? ""
        return relativePath
    }

    /// Create a sub-collection (subdirectory) under an existing collection.
    func createSubCollection(name: String, parentId: String) throws {
        guard let entry = selectedVault else {
            return
        }
        let vaultPath = store.resolvedPath(for: entry)
        let slug = makeSlug(from: name)
        guard !slug.isEmpty else {
            throw CollectionError.invalidName
        }

        let subDir = (vaultPath as NSString)
            .appendingPathComponent(parentId)
            .appending("/\(slug)")
        let fm = FileManager.default


        if fm.fileExists(atPath: subDir) {
            throw CollectionError.alreadyExists(slug)
        }

        try fm.createDirectory(atPath: subDir, withIntermediateDirectories: true)

        // Create _index.md with title
        let indexPath = (subDir as NSString).appendingPathComponent("_index.md")
        let content = """
        ---
        title: \(name)
        ---
        """
        try content.write(toFile: indexPath, atomically: true, encoding: .utf8)

        reloadCurrentVault()
    }

    /// Reorder top-level collections in maho.yaml.
    func reorderCollections(orderedIds: [String]) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        try? MahoNotesKit.reorderCollections(vaultPath: vaultPath, orderedIds: orderedIds)
        reloadCurrentVault()
    }

    // MARK: - Rename & Icon

    /// Rename a collection (top-level: update maho.yaml; sub-collection: update _index.md title).
    func renameCollection(collectionId: String, newName: String) throws {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let parentDir = (collectionId as NSString).deletingLastPathComponent

        if parentDir.isEmpty {
            // Top-level collection
            try updateCollectionInConfig(vaultPath: vaultPath, id: collectionId, name: newName)
        } else {
            // Sub-collection
            let vault = Vault(path: vaultPath)
            try vault.renameSubCollection(collectionId: collectionId, newName: newName)
        }
        reloadCurrentVault()
    }

    /// Change a top-level collection's icon in maho.yaml.
    func changeCollectionIcon(collectionId: String, newIcon: String) throws {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        try updateCollectionInConfig(vaultPath: vaultPath, id: collectionId, icon: newIcon)
        reloadCurrentVault()
    }

    /// Rename a note by updating its frontmatter title.
    func renameNote(relativePath: String, newTitle: String) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        vault.renameNote(relativePath: relativePath, newTitle: newTitle)
        reloadCurrentVault()
    }

    // MARK: - Delete

    /// Delete a note by moving it to Trash.
    func deleteNote(relativePath: String) throws {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let absPath = (vaultPath as NSString).appendingPathComponent(relativePath)
        let fileURL = URL(fileURLWithPath: absPath)

        // Remove from parent _index.md order before trashing
        let filename = (relativePath as NSString).lastPathComponent
        let parentDir = (relativePath as NSString).deletingLastPathComponent
        let parentDirAbs = (vaultPath as NSString).appendingPathComponent(parentDir)
        let (order, _) = readDirectoryOrder(at: parentDirAbs)
        if order.contains(filename) {
            let updated = order.filter { $0 != filename }
            try? writeDirectoryOrder(at: parentDirAbs, notes: updated)
        }

        #if os(iOS)
        // iOS: trashItem may fail for iCloud/sandboxed paths; use removeItem directly
        try FileManager.default.removeItem(at: fileURL)
        #else
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        #endif

        // Clear selection if the deleted note was selected
        if selectedNotePath == relativePath {
            selectedNotePath = nil
            navigatorSelection = []
            editorState.viewMode = .preview
        }
        reloadCurrentVault()

        // Trigger sync so deletion is pushed to remote
        syncCoordinator.notifyContentChanged(vault: entry)
    }

    /// Delete a sub-collection by moving its notes to the parent collection, then removing the directory.
    func deleteSubCollection(collectionId: String) throws {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let fm = FileManager.default

        let absPath = (vaultPath as NSString).appendingPathComponent(collectionId)
        let dirName = (collectionId as NSString).lastPathComponent
        let parentId = (collectionId as NSString).deletingLastPathComponent
        let parentAbsPath = parentId.isEmpty
            ? vaultPath
            : (vaultPath as NSString).appendingPathComponent(parentId)

        // Move .md files (not _index.md) to parent, and add to parent's _index.md order
        var movedFiles: [String] = []
        if let contents = try? fm.contentsOfDirectory(atPath: absPath) {
            for item in contents where item.hasSuffix(".md") && item != "_index.md" && item.lowercased() != "readme.md" {
                let src = (absPath as NSString).appendingPathComponent(item)
                let dst = (parentAbsPath as NSString).appendingPathComponent(item)
                try? fm.moveItem(atPath: src, toPath: dst)
                movedFiles.append(item)
            }
        }

        // Update parent's _index.md: remove from children, add moved notes to order
        let (parentOrder, parentChildren) = readDirectoryOrder(at: parentAbsPath)
        let updatedChildren = parentChildren.filter { $0 != dirName }
        var updatedOrder = parentOrder
        updatedOrder.append(contentsOf: movedFiles)
        try? writeDirectoryOrder(at: parentAbsPath, notes: updatedOrder, children: updatedChildren)

        // Remove the (now mostly empty) directory
        #if os(iOS)
        try fm.removeItem(at: URL(fileURLWithPath: absPath))
        #else
        try fm.trashItem(at: URL(fileURLWithPath: absPath), resultingItemURL: nil)
        #endif

        reloadCurrentVault()
    }

    /// Delete a top-level collection by moving the entire directory to Trash and removing from maho.yaml.
    func deleteTopLevelCollection(collectionId: String) throws {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let absPath = (vaultPath as NSString).appendingPathComponent(collectionId)

        // Remove directory
        #if os(iOS)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: absPath))
        #else
        try FileManager.default.trashItem(at: URL(fileURLWithPath: absPath), resultingItemURL: nil)
        #endif

        // Remove from maho.yaml
        try removeCollectionFromConfig(vaultPath: vaultPath, id: collectionId)

        // Clear selection if a note in this collection was selected
        if let selected = selectedNotePath, selected.hasPrefix(collectionId + "/") {
            selectedNotePath = nil
            navigatorSelection = []
            editorState.viewMode = .preview
        }
        reloadCurrentVault()

        // Trigger sync so deletion is pushed to remote
        syncCoordinator.notifyContentChanged(vault: entry)
    }

    /// Reorder notes within a collection directory by writing order to `_index.md`.
    func reorderNotes(collectionId: String, orderedPaths: [String]) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        _ = try? vault.reorderNotes(collectionId: collectionId, orderedPaths: orderedPaths)
        reloadCurrentVault()
    }

    /// Move a note to a different collection.
    func moveNote(relativePath: String, toCollection: String) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        let newPath = try? vault.moveNote(relativePath: relativePath, toCollection: toCollection)
        if selectedNotePath == relativePath, let newPath {
            selectedNotePath = newPath
            navigatorSelection = [newPath]
        }
        reloadCurrentVault()
    }

    /// Move a collection into another parent collection.
    func moveCollection(collectionId: String, intoParent: String) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        _ = try? vault.moveCollection(collectionId: collectionId, intoParent: intoParent)
        reloadCurrentVault()
    }

    /// Promote a sub-collection to a top-level collection.
    func promoteToTopLevel(collectionId: String) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        _ = try? vault.promoteToTopLevel(collectionId: collectionId)
        reloadCurrentVault()
    }

    /// Reorder sub-collections within a parent directory.
    func reorderSubCollections(parentId: String, orderedIds: [String]) {
        guard let entry = selectedVault else { return }
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        try? vault.reorderSubCollections(parentId: parentId, orderedIds: orderedIds)
        reloadCurrentVault()
    }
}
