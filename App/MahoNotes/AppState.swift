import Foundation
import Observation
import MahoNotesKit

/// Central app state — loads vault registry, resolves vault paths, tracks selection.
@Observable
final class AppState {

    // MARK: - Vault Registry

    /// All registered vaults from the vault registry.
    private(set) var vaults: [VaultEntry] = []

    /// The currently selected vault name.
    var selectedVaultName: String?

    /// Error message if vault registry failed to load.
    private(set) var errorMessage: String?

    /// Whether the initial load has completed.
    private(set) var isLoaded: Bool = false

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

    // MARK: - Panel Visibility

    /// Whether the vault rail (A) is visible.
    var showVaultRail: Bool = UserDefaults.standard.object(forKey: "showVaultRail") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVaultRail, forKey: "showVaultRail") }
    }

    /// Whether the navigator (B) is visible.
    var showNavigator: Bool = UserDefaults.standard.object(forKey: "showNavigator") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showNavigator, forKey: "showNavigator") }
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

    // MARK: - Search

    /// Whether the search panel is visible.
    var showSearchPanel: Bool = false

    /// Current search query text.
    var searchQuery: String = ""

    /// Search results from FTS.
    private(set) var searchResults: [Note] = []

    /// Search mode: "text", "semantic", or "hybrid".
    var searchMode: String {
        get { UserDefaults.standard.string(forKey: "searchMode") ?? "text" }
        set { UserDefaults.standard.set(newValue, forKey: "searchMode") }
    }

    /// Search scope: "thisVault" or "allVaults".
    var searchScope: String {
        get { UserDefaults.standard.string(forKey: "searchScope") ?? "thisVault" }
        set { UserDefaults.standard.set(newValue, forKey: "searchScope") }
    }

    /// Embedding model identifier: "minilm", "e5-small", or "e5-large".
    var embeddingModel: String {
        get { UserDefaults.standard.string(forKey: "embeddingModel") ?? "minilm" }
        set { UserDefaults.standard.set(newValue, forKey: "embeddingModel") }
    }

    /// Error message from search (e.g., vector index not built).
    private(set) var searchError: String?

    /// Whether a search index build is in progress.
    var isIndexBuilding: Bool = false

    /// Toggle search panel visibility.
    func toggleSearch() {
        showSearchPanel.toggle()
        if !showSearchPanel {
            searchQuery = ""
            searchResults = []
            searchError = nil
        }
    }

    /// Perform search against current vault (or all vaults) using the configured search mode.
    func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }

        if searchScope == "allVaults" {
            var merged: [Note] = []
            for entry in vaults {
                let results = searchVault(entry: entry, query: query)
                merged.append(contentsOf: results)
            }
            searchResults = Array(merged.prefix(20))
        } else {
            guard let entry = selectedVault else {
                searchResults = []
                return
            }
            searchResults = Array(searchVault(entry: entry, query: query).prefix(20))
        }
    }

    /// Search a single vault using the configured search mode.
    private func searchVault(entry: VaultEntry, query: String) -> [Note] {
        let vaultPath = resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        let mode = searchMode

        switch mode {
        case "semantic":
            guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else {
                searchError = "Build search index first in Settings"
                return []
            }
            searchError = nil
            // Semantic search requires async embedding — fall back to FTS for now
            // (async search is handled by performSearchAsync)
            return ftsSearch(vault: vault, vaultPath: vaultPath, query: query)

        case "hybrid":
            guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else {
                searchError = "Build search index first in Settings"
                return []
            }
            searchError = nil
            return ftsSearch(vault: vault, vaultPath: vaultPath, query: query)

        default: // "text"
            searchError = nil
            return ftsSearch(vault: vault, vaultPath: vaultPath, query: query)
        }
    }

    /// FTS5 search against a vault's SearchIndex.
    private func ftsSearch(vault: Vault, vaultPath: String, query: String) -> [Note] {
        do {
            let index = try SearchIndex(vaultPath: vaultPath)
            let notes = try vault.allNotes()
            let _ = try index.buildIndex(notes: notes)
            let results = try index.search(query: query)
            // Map SearchResult paths back to Note objects
            return results.compactMap { result in
                notes.first { $0.relativePath == result.path }
            }
        } catch {
            // Fallback to naive vault search
            return (try? vault.searchNotes(query: query)) ?? []
        }
    }

    /// Clear the search query and results.
    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchError = nil
    }

    /// Select a note from search results and dismiss the panel.
    func selectSearchResult(_ note: Note) {
        selectedNotePath = note.relativePath
        showSearchPanel = false
        searchQuery = ""
        searchResults = []
        searchError = nil
    }

    /// Check if vector index exists for a given vault path.
    func vectorIndexExists(for vaultPath: String) -> Bool {
        VectorIndex.vectorIndexExists(vaultPath: vaultPath)
    }

    // MARK: - View Mode & Editing

    /// View mode for the content panel.
    enum ViewMode: String { case preview, editor, split }

    /// Current view mode.
    var viewMode: ViewMode = .preview

    /// The current editing buffer (raw markdown body).
    var editingBody: String = ""

    /// Whether the editing buffer differs from the saved note body.
    var hasUnsavedChanges: Bool {
        guard let note = selectedNote else { return false }
        return editingBody != note.body
    }

    /// Whether the current vault is read-only.
    var isReadOnly: Bool {
        selectedVault?.access == .readOnly
    }

    /// Copy the note body into the editing buffer.
    func startEditing() {
        guard let note = selectedNote else { return }
        if editingBody.isEmpty || !hasUnsavedChanges {
            editingBody = note.body
        }
    }

    /// Cycle view mode: preview → editor → split → preview.
    func cycleViewMode() {
        guard !isReadOnly else { return }
        switch viewMode {
        case .preview: viewMode = .editor; startEditing()
        case .editor: viewMode = .split; startEditing()
        case .split: viewMode = .preview
        }
    }

    /// Save the editing buffer back to the markdown file, preserving frontmatter.
    @MainActor
    func saveNote() {
        // Only save when actively editing (not in preview mode with stale/empty buffer)
        guard viewMode != .preview else { return }
        guard let note = selectedNote, let entry = selectedVault, !isReadOnly else { return }
        guard hasUnsavedChanges else { return }
        guard !editingBody.isEmpty else { return }

        let vaultPath = resolvedPath(for: entry)
        let filePath = (vaultPath as NSString).appendingPathComponent(note.relativePath)

        do {
            let content = try String(contentsOfFile: filePath, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            // Find frontmatter boundaries
            guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return }
            var closingIndex: Int?
            for i in 1..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    closingIndex = i
                    break
                }
            }
            guard let endIdx = closingIndex else { return }

            // Update the `updated` timestamp in frontmatter
            var frontmatterLines = Array(lines[0...endIdx])
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            let now = isoFormatter.string(from: Date())

            if let updatedIdx = frontmatterLines.firstIndex(where: { $0.hasPrefix("updated:") }) {
                frontmatterLines[updatedIdx] = "updated: \(now)"
            } else {
                frontmatterLines.insert("updated: \(now)", at: endIdx)
            }

            let newContent = frontmatterLines.joined(separator: "\n") + "\n" + editingBody
            try newContent.write(toFile: filePath, atomically: true, encoding: .utf8)

            // Reload the note in allNotes
            if let updated = try parseNote(at: filePath, relativeTo: vaultPath) {
                if let idx = allNotes.firstIndex(where: { $0.relativePath == note.relativePath }) {
                    allNotes[idx] = updated
                }
                // Update grouped notes
                var grouped = notesByCollection
                if var notes = grouped[updated.collection] {
                    if let idx = notes.firstIndex(where: { $0.relativePath == updated.relativePath }) {
                        notes[idx] = updated
                        grouped[updated.collection] = notes
                    }
                }
                notesByCollection = grouped
            }
        } catch {
            // Silently fail for now — could add error reporting later
        }
    }

    /// Revert editing buffer and switch to preview.
    @MainActor
    func cancelEditing() {
        if let note = selectedNote {
            editingBody = note.body
        }
        viewMode = .preview
    }

    // MARK: - Note Selection

    /// Relative path of the currently selected note.
    var selectedNotePath: String?

    /// Call when changing selected note to handle auto-save and reset.
    @MainActor
    func selectNote(path: String?) {
        // Auto-save when switching notes
        if selectedNotePath != nil && selectedNotePath != path && hasUnsavedChanges {
            saveNote()
        }
        selectedNotePath = path
        // Reset view mode to preview when selecting a new note
        viewMode = .preview
        editingBody = ""
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
    var localVaults: [VaultEntry] { vaults.filter { $0.type == .local } }

    // MARK: - iCloud Sync

    var iCloudManager = iCloudSyncManager()

    /// Whether the currently selected vault has any conflicts.
    var hasConflicts: Bool { !iCloudManager.conflicts.isEmpty }

    /// Find conflict info for a specific note path.
    func conflict(for notePath: String) -> iCloudSyncManager.ConflictInfo? {
        iCloudManager.conflicts.first { $0.notePath == notePath }
    }

    /// Start iCloud monitoring for the given vault entry if it's an iCloud vault.
    @MainActor
    private func startICloudMonitoringIfNeeded(for entry: VaultEntry) {
        iCloudManager.stopMonitoring()

        guard entry.type == .icloud else { return }

        let vaultPath = resolvedPath(for: entry)
        let vaultURL = URL(fileURLWithPath: vaultPath)

        iCloudManager.startMonitoring(containerURL: vaultURL) { [weak self] in
            self?.reloadCurrentVault()
        }

        iCloudManager.checkForConflicts(in: vaultURL)
    }

    /// Reload the current vault's notes without changing selection.
    @MainActor
    func reloadCurrentVault() {
        guard let entry = selectedVault else { return }

        let vaultPath = resolvedPath(for: entry)
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
            for key in grouped.keys {
                grouped[key]?.sort { $0.title < $1.title }
            }
            self.notesByCollection = grouped
        } catch {
            // Keep existing state on error
        }

        // Restore selection if the note still exists
        if let prev = previousSelection, allNotes.contains(where: { $0.relativePath == prev }) {
            selectedNotePath = prev
        }

        // Refresh conflict list for iCloud vaults
        if entry.type == .icloud {
            let vaultURL = URL(fileURLWithPath: vaultPath)
            iCloudManager.checkForConflicts(in: vaultURL)
        }
    }

    // MARK: - Init

    init() {}

    // MARK: - Loading

    /// Load the vault registry. Call on app launch.
    @MainActor
    func loadRegistry() {
        do {
            let result: VaultRegistry? = try MahoNotesKit.loadRegistry()

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
            loadSelectedVault()
        } catch {
            self.errorMessage = "Failed to load vault registry: \(error.localizedDescription)"
            self.vaults = []
            self.isLoaded = true
        }
    }

    /// Reload the vault registry.
    @MainActor
    func reloadRegistry() {
        loadRegistry()
    }

    /// Load collections and notes for the currently selected vault.
    @MainActor
    func loadSelectedVault() {
        guard let entry = selectedVault else {
            collections = []
            fileTree = []
            notesByCollection = [:]
            allNotes = []
            selectedNotePath = nil
            return
        }

        let vaultPath = resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)

        do {
            self.collections = try vault.collections()
            self.allNotes = try vault.allNotes()
            self.fileTree = try vault.buildFileTree()

            var grouped: [String: [Note]] = [:]
            for note in allNotes {
                grouped[note.collection, default: []].append(note)
            }
            // Sort notes within each collection by title
            for key in grouped.keys {
                grouped[key]?.sort { $0.title < $1.title }
            }
            self.notesByCollection = grouped
        } catch {
            self.collections = []
            self.allNotes = []
            self.fileTree = []
            self.notesByCollection = [:]
        }

        selectedNotePath = nil

        // Start iCloud monitoring if this is an iCloud vault
        startICloudMonitoringIfNeeded(for: entry)
    }

    /// Notes for a given collection id.
    func notes(for collectionId: String) -> [Note] {
        notesByCollection[collectionId] ?? []
    }

    // MARK: - Vault Management

    /// Remove a vault from the registry (does not delete files).
    @MainActor
    func removeVault(name: String) {
        guard var registry = try? MahoNotesKit.loadRegistry() else { return }
        try? registry.removeVault(named: name)
        // If removing the primary, reassign to first remaining vault
        if registry.primary == name, let first = registry.vaults.first {
            registry.primary = first.name
        }
        try? MahoNotesKit.saveRegistry(registry)
        if selectedVaultName == name {
            selectedVaultName = registry.primary
        }
        loadRegistry()
    }

    /// Set a vault as the primary vault.
    @MainActor
    func setPrimaryVault(name: String) {
        guard var registry = try? MahoNotesKit.loadRegistry() else { return }
        try? registry.setPrimary(name)
        try? MahoNotesKit.saveRegistry(registry)
        loadRegistry()
    }
}
