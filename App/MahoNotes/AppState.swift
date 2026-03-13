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

    // MARK: - Cloud Sync

    /// Current cloud sync mode (read from global config).
    var cloudSyncMode: CloudSyncMode = .off

    /// Whether the merge confirmation sheet is showing.
    var showMergeSheet: Bool = false

    /// Cloud registry found when activating sync (for merge flow).
    var pendingCloudRegistry: VaultRegistry?

    /// Summary of conflicts after a merge, for display.
    var lastMergeConflicts: [VaultNameConflict] = []

    /// Whether to show the post-merge summary.
    var showMergeResult: Bool = false

    /// Load cloud sync mode from global config.
    func loadCloudSyncMode() {
        Task {
            let mode = await store.cloudSyncMode()
            self.cloudSyncMode = mode
        }
    }

    /// Called when user toggles cloud sync. Checks for merge needs before applying.
    func requestCloudSyncChange(to mode: CloudSyncMode) {
        Task {
            if mode == .off {
                // Turning off — migrate vaults back to local, then disable
                if let localRegistry = try? await store.loadRegistry() {
                    if let migrated = try? await store.migrateFromCloud(localRegistry) {
                        await applyCloudSyncMode(.off)
                        try? await store.saveRegistry(migrated)
                        await loadRegistryAsync()
                        return
                    }
                }
                await applyCloudSyncMode(.off)
                return
            }

            // Turning on — check if iCloud already has a registry
            let check = await store.checkCloudRegistryExists()
            switch check {
            case .noCloudRegistry:
                // No conflict — activate, migrate vaults to iCloud, and save
                await applyCloudSyncMode(.icloud)
                if var localRegistry = try? await store.loadRegistry() {
                    if let migrated = try? await store.migrateToCloud(localRegistry) {
                        localRegistry = migrated
                    }
                    try? await store.saveRegistry(localRegistry)
                    await loadRegistryAsync()
                }
            case .cloudRegistryExists(let cloudRegistry):
                // Need merge — show confirmation
                pendingCloudRegistry = cloudRegistry
                showMergeSheet = true
            }
        }
    }

    /// Merge local vaults with cloud registry.
    func performMerge() {
        Task {
            // Load local registry BEFORE switching mode (same reason as replaceCloudWithLocal)
            let localRegistrySnapshot: VaultRegistry?
            do {
                localRegistrySnapshot = try await store.loadRegistry()
            } catch {
                localRegistrySnapshot = nil
            }

            guard let cloudRegistry = pendingCloudRegistry,
                  let localRegistry = localRegistrySnapshot ?? VaultRegistry(primary: "default", vaults: [])
                  as VaultRegistry?
            else {
                pendingCloudRegistry = nil
                showMergeSheet = false
                return
            }

            var (merged, conflicts) = await store.mergeRegistries(local: localRegistry, cloud: cloudRegistry)

            // Activate cloud sync, then migrate device vaults to iCloud and save
            await applyCloudSyncMode(.icloud)
            if let migrated = try? await store.migrateToCloud(merged) {
                merged = migrated
            }
            try? await store.saveRegistry(merged)

            // Update local state directly (avoid loadRegistry re-reading before iCloud propagates)
            self.vaults = merged.vaults
            self.primaryVaultName = merged.primary
            self.lastMergeConflicts = conflicts
            self.pendingCloudRegistry = nil
            self.showMergeSheet = false

            // Now reload to pick up resolved paths
            await loadRegistryAsync()

            if !conflicts.isEmpty {
                self.showMergeResult = true
            }
        }
    }

    /// Replace cloud registry with local registry (discard cloud).
    func replaceCloudWithLocal() {
        Task {
            // Load local registry BEFORE switching to iCloud mode
            // (otherwise loadRegistry reads from iCloud and gets the cloud registry)
            let localRegistrySnapshot: VaultRegistry?
            do {
                localRegistrySnapshot = try await store.loadRegistry()
            } catch {
                localRegistrySnapshot = nil
            }

            await applyCloudSyncMode(.icloud)

            if var registry = localRegistrySnapshot {
                if let migrated = try? await store.migrateToCloud(registry) {
                    registry = migrated
                }
                try? await store.saveRegistry(registry)
            }

            pendingCloudRegistry = nil
            showMergeSheet = false
            await loadRegistryAsync()
        }
    }

    /// Cancel merge — don't turn on cloud sync.
    func cancelMerge() {
        pendingCloudRegistry = nil
        showMergeSheet = false
    }

    /// Internal: persist cloud sync mode.
    private func applyCloudSyncMode(_ mode: CloudSyncMode) async {
        do {
            try await store.setCloudSyncMode(mode)
            self.cloudSyncMode = mode
        } catch {
            let current = await store.cloudSyncMode()
            self.cloudSyncMode = current
        }
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
        if showSearchPanel {
            // Focus the title bar search field
            #if os(macOS)
            NotificationCenter.default.post(name: .focusTitleBarSearch, object: nil)
            #endif
        } else {
            searchQuery = ""
            searchResults = []
            searchError = nil
        }
    }

    /// Embedding provider (lazy-loaded, reused across searches).
    private var embeddingProvider: (any EmbeddingProvider)?

    /// Get or create the embedding provider for the current model setting.
    private func getEmbeddingProvider() -> any EmbeddingProvider {
        if let provider = embeddingProvider, provider.modelIdentifier == embeddingModel {
            return provider
        }
        let model = EmbeddingModel(rawValue: embeddingModel) ?? .minilm
        let provider = SwiftEmbeddingsProvider(model: model)
        embeddingProvider = provider
        return provider
    }

    /// Perform search (async — supports FTS, semantic, and hybrid modes).
    func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }

        let mode = searchMode
        if mode == "text" {
            // Synchronous FTS — no async needed
            performFTSSearch(query: query)
        } else {
            // Semantic or Hybrid — need async embedding
            Task {
                await performAsyncSearch(query: query, mode: mode)
            }
        }
    }

    /// Synchronous FTS-only search.
    private func performFTSSearch(query: String) {
        searchError = nil
        if searchScope == "allVaults" {
            var merged: [Note] = []
            for entry in vaults {
                merged.append(contentsOf: ftsSearch(entry: entry, query: query))
            }
            searchResults = Array(merged.prefix(20))
        } else if let entry = selectedVault {
            searchResults = Array(ftsSearch(entry: entry, query: query).prefix(20))
        } else {
            searchResults = []
        }
    }

    /// Async search for semantic and hybrid modes.
    private func performAsyncSearch(query: String, mode: String) async {
        let entries = searchScope == "allVaults" ? vaults : (selectedVault.map { [$0] } ?? [])

        // Check vector index exists for at least one vault
        let hasVectorIndex = entries.contains { VectorIndex.vectorIndexExists(vaultPath: store.resolvedPath(for: $0)) }
        guard hasVectorIndex else {
            searchError = "Build search index first (Settings → Search or `mn index`)"
            searchResults = []
            return
        }

        searchError = nil

        // Embed the query
        let provider = getEmbeddingProvider()
        let queryVector: [Float]
        do {
            queryVector = try await provider.embed(query)
        } catch {
            searchError = "Embedding failed: \(error.localizedDescription)"
            performFTSSearch(query: query)
            return
        }

        // For cross-vault search: collect ALL results across vaults, then rank globally.
        // This prevents per-vault "top result" pollution — a vault with irrelevant
        // content won't show up just because something is its "best match."

        // Semantic: collect (score, Note) pairs, sort globally by cosine similarity
        var scoredNotes: [(score: Double, note: Note)] = []

        // Hybrid: collect raw FTS + vector results across vaults with vault-prefixed paths,
        // then do ONE global RRF merge to get fair cross-vault ranking.
        var globalFtsResults: [SearchResult] = []
        var globalVecResults: [VectorSearchResult] = []
        var notesByPrefixedPath: [String: Note] = [:]

        for entry in entries {
            let vaultPath = store.resolvedPath(for: entry)
            let vault = Vault(path: vaultPath)
            let notes: [Note]
            do {
                notes = try vault.allNotes()
            } catch {
                continue
            }

            let vecResults = vectorSearchResults(vaultPath: vaultPath, queryVector: queryVector)

            if mode == "semantic" {
                // Map vector results → Note with score
                for r in vecResults {
                    if let note = notes.first(where: { $0.relativePath == r.path }) {
                        scoredNotes.append((score: r.score, note: note))
                    }
                }
            } else {
                // Hybrid: prefix paths with vault name to avoid collision across vaults
                let vaultPrefix = entry.name + "::"
                for note in notes {
                    notesByPrefixedPath[vaultPrefix + note.relativePath] = note
                }

                // Collect FTS results with prefixed paths
                let ftsResults = ftsSearchResults(entry: entry, query: query)
                for r in ftsResults {
                    globalFtsResults.append(SearchResult(
                        path: vaultPrefix + r.path,
                        title: r.title,
                        tags: r.tags,
                        snippet: r.snippet,
                        rank: r.rank
                    ))
                }
                // Collect vector results with prefixed paths
                for r in vecResults {
                    globalVecResults.append(VectorSearchResult(
                        path: vaultPrefix + r.path,
                        chunkText: r.chunkText,
                        score: r.score,
                        chunkId: r.chunkId
                    ))
                }
            }
        }

        if mode == "semantic" {
            // Sort globally by cosine similarity — absolute scores are comparable across vaults
            searchResults = scoredNotes
                .sorted { $0.score > $1.score }
                .prefix(20)
                .map { $0.note }
        } else {
            // Global RRF merge: one ranking across all vaults
            let merged = HybridSearch.merge(
                ftsResults: globalFtsResults,
                vectorResults: globalVecResults,
                limit: 20
            )
            searchResults = merged.compactMap { notesByPrefixedPath[$0.path] }
        }
    }

    /// FTS search returning Note objects for a single vault.
    private func ftsSearch(entry: VaultEntry, query: String) -> [Note] {
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        do {
            let index = try SearchIndex(vaultPath: vaultPath)
            let notes = try vault.allNotes()
            let _ = try index.buildIndex(notes: notes)
            let results = try index.search(query: query)
            return results.compactMap { result in
                notes.first { $0.relativePath == result.path }
            }
        } catch {
            return (try? vault.searchNotes(query: query)) ?? []
        }
    }

    /// FTS search returning raw SearchResult (for hybrid merge).
    private func ftsSearchResults(entry: VaultEntry, query: String) -> [SearchResult] {
        let vaultPath = store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        do {
            let index = try SearchIndex(vaultPath: vaultPath)
            let notes = try vault.allNotes()
            let _ = try index.buildIndex(notes: notes)
            return try index.search(query: query)
        } catch {
            return []
        }
    }

    /// Vector search returning Note objects.
    private func vectorSearch(vaultPath: String, queryVector: [Float], notes: [Note]) -> [Note] {
        let results = vectorSearchResults(vaultPath: vaultPath, queryVector: queryVector)
        return results.compactMap { result in
            notes.first { $0.relativePath == result.path }
        }
    }

    /// Vector search returning raw VectorSearchResult (for hybrid merge).
    private func vectorSearchResults(vaultPath: String, queryVector: [Float]) -> [VectorSearchResult] {
        guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else { return [] }
        do {
            let dimensions = queryVector.count
            let vecIndex = try VectorIndex(vaultPath: vaultPath, dimensions: dimensions, skipDimensionCheck: true)
            return try vecIndex.search(queryVector: queryVector)
        } catch {
            return []
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
        navigatorSelection = [note.relativePath]
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
    /// When `compactWidth` is true (iPhone portrait), skip split: preview ↔ editor.
    func cycleViewMode(compactWidth: Bool = false) {
        guard !isReadOnly else { return }
        switch viewMode {
        case .preview: viewMode = .editor; startEditing()
        case .editor:
            if compactWidth {
                // iPhone portrait: skip split, go back to preview
                if hasUnsavedChanges { saveNote() }
                viewMode = .preview
            } else {
                viewMode = .split; startEditing()
            }
        case .split:
            // Save before switching to preview (saveNote guards viewMode != .preview)
            if hasUnsavedChanges { saveNote() }
            viewMode = .preview
        }
    }

    /// Save the editing buffer back to the markdown file, preserving frontmatter.
    func saveNote() {
        // Only save when actively editing (not in preview mode with stale/empty buffer)
        guard viewMode != .preview else { return }
        guard let note = selectedNote, let entry = selectedVault, !isReadOnly else { return }
        guard hasUnsavedChanges else { return }
        guard !editingBody.isEmpty else { return }

        let vaultPath = store.resolvedPath(for: entry)
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
            syncCoordinator.notifyContentChanged(vault: entry)

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

                // Background: re-embed the updated note for vector search
                reembedNoteInBackground(updated, vaultPath: vaultPath)
            }
        } catch {
            // Silently fail for now — could add error reporting later
        }
    }

    /// Re-embed a single note's vector chunks in the background after save.
    /// Only runs if a vector index already exists for the vault (skip if never built).
    private func reembedNoteInBackground(_ note: Note, vaultPath: String) {
        guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else { return }

        let currentEmbeddingModel = embeddingModel
        Task.detached {
            do {
                let model = EmbeddingModel(rawValue: currentEmbeddingModel) ?? .minilm
                let provider = SwiftEmbeddingsProvider(model: model)

                let vecIndex = try VectorIndex(vaultPath: vaultPath, dimensions: provider.dimensions, skipDimensionCheck: true)

                // Chunk the note and embed
                let chunks = Chunker.chunkNote(title: note.title, body: note.body)
                guard !chunks.isEmpty else {
                    try vecIndex.removeNote(path: note.relativePath)
                    return
                }

                let texts = chunks.map { $0.text }
                let vectors = try await provider.embedBatch(texts)

                let filePath = (vaultPath as NSString).appendingPathComponent(note.relativePath)
                let mtime = (try? FileManager.default.attributesOfItem(atPath: filePath))?[.modificationDate]
                    .flatMap { ($0 as? Date)?.timeIntervalSince1970 } ?? Date().timeIntervalSince1970

                try vecIndex.indexNote(
                    path: note.relativePath,
                    chunks: chunks.map { (id: $0.id, text: $0.text) },
                    vectors: vectors,
                    model: model.rawValue,
                    mtime: mtime
                )
            } catch {
                // Silently fail — vector re-indexing is best-effort
            }
        }
    }

    /// Revert editing buffer and switch to preview.
    func cancelEditing() {
        if let note = selectedNote {
            editingBody = note.body
        }
        viewMode = .preview
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
                if selectedNotePath != nil && hasUnsavedChanges {
                    saveNote()
                }
                selectedNotePath = path
                selectedNotePaths = []
                viewMode = .preview
                editingBody = ""
            }
        } else if newSelection.isEmpty {
            if selectedNotePath != nil {
                if hasUnsavedChanges { saveNote() }
                selectedNotePath = nil
                selectedNotePaths = []
            }
        } else {
            // Multi-selection via Cmd+Click / Shift+Click
            selectedNotePaths = newSelection
            if let path = newSelection.first(where: { $0 != selectedNotePath }) ?? newSelection.first {
                if selectedNotePath != nil && selectedNotePath != path && hasUnsavedChanges {
                    saveNote()
                }
                selectedNotePath = path
                viewMode = .preview
                editingBody = ""
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
        if selectedNotePath != nil && selectedNotePath != path && hasUnsavedChanges {
            saveNote()
        }
        selectedNotePath = path
        selectedNotePaths = []
        navigatorSelection = path == nil ? [] : [path!]
        // Reset view mode to preview when selecting a new note
        viewMode = .preview
        editingBody = ""
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
            if selectedNotePath != nil && selectedNotePath != path && hasUnsavedChanges {
                saveNote()
            }
            selectedNotePath = path
            viewMode = .preview
            editingBody = ""
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

    // MARK: - Note Clipboard

    struct NoteClipboardEntry {
        let relativePath: String
        let vaultName: String
    }

    /// Copied notes waiting to be pasted.
    var noteClipboard: [NoteClipboardEntry]?

    /// Copy the currently selected note(s) to the clipboard.
    func copySelectedNotes() {
        guard let vaultName = selectedVaultName else { return }
        let paths: [String]
        if selectedNotePaths.count > 1 {
            paths = Array(selectedNotePaths)
        } else if let path = selectedNotePath {
            paths = [path]
        } else {
            return
        }
        noteClipboard = paths.map { NoteClipboardEntry(relativePath: $0, vaultName: vaultName) }
    }

    /// Paste copied notes into a target collection in the current vault.
    func pasteNotes(toCollection collectionId: String) {
        guard let clipboard = noteClipboard, !clipboard.isEmpty else { return }
        guard let targetEntry = selectedVault else { return }
        let targetVaultPath = store.resolvedPath(for: targetEntry)
        let fm = FileManager.default

        let targetDir = (targetVaultPath as NSString).appendingPathComponent(collectionId)
        try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

        var pastedFilenames: [String] = []

        for item in clipboard {
            // Resolve source vault path
            let sourceEntry = vaults.first { $0.name == item.vaultName }
            let sourceVaultPath: String
            if let entry = sourceEntry {
                sourceVaultPath = store.resolvedPath(for: entry)
            } else {
                continue
            }

            let sourceAbs = (sourceVaultPath as NSString).appendingPathComponent(item.relativePath)
            guard fm.fileExists(atPath: sourceAbs) else { continue }

            let originalFilename = (item.relativePath as NSString).lastPathComponent
            let ext = (originalFilename as NSString).pathExtension
            let baseName = (originalFilename as NSString).deletingPathExtension

            // Determine target filename with (Copy) suffix
            var targetFilename: String
            var targetAbs: String
            var copySuffix: String

            let copyName = "\(baseName)(Copy).\(ext)"
            targetAbs = (targetDir as NSString).appendingPathComponent(copyName)

            if !fm.fileExists(atPath: targetAbs) {
                targetFilename = copyName
                copySuffix = "(Copy)"
            } else {
                var counter = 2
                repeat {
                    copySuffix = "(Copy \(counter))"
                    targetFilename = "\(baseName)\(copySuffix).\(ext)"
                    targetAbs = (targetDir as NSString).appendingPathComponent(targetFilename)
                    counter += 1
                } while fm.fileExists(atPath: targetAbs)
            }

            // Copy file and update frontmatter title
            do {
                try fm.copyItem(atPath: sourceAbs, toPath: targetAbs)

                // Update title in frontmatter to include (Copy) suffix
                if var content = try? String(contentsOfFile: targetAbs, encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n")
                    if let titleIdx = lines.firstIndex(where: { $0.hasPrefix("title:") }) {
                        var mutableLines = lines
                        let originalTitle = mutableLines[titleIdx]
                            .replacingOccurrences(of: "title:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        mutableLines[titleIdx] = "title: \(originalTitle) \(copySuffix)"
                        content = mutableLines.joined(separator: "\n")
                        try? content.write(toFile: targetAbs, atomically: true, encoding: .utf8)
                    }
                }

                pastedFilenames.append(targetFilename)
            } catch {
                // Skip failed copies
            }
        }

        // Append pasted files to target _index.md order
        if !pastedFilenames.isEmpty {
            let (existingOrder, _) = readDirectoryOrder(at: targetDir)
            var newOrder = existingOrder
            newOrder.append(contentsOf: pastedFilenames)
            try? writeDirectoryOrder(at: targetDir, notes: newOrder)
        }

        reloadCurrentVault()

        // Trigger sync
        if let entry = selectedVault {
            syncCoordinator.notifyContentChanged(vault: entry)
        }
    }

    // MARK: - GitHub Auth

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
            self.cloudSyncMode = mode
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
        let storage: StorageOption = cloudSyncMode == .icloud ? .icloud : .local
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
        print("[MahoNotes] setVaultColor: name=\(name) color=\(color) existing.color=\(existing?.color ?? "nil")")

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
            print("[MahoNotes] setVaultColor: optimistic update done, new color=\(vaults[index].color ?? "nil")")
        } else {
            print("[MahoNotes] setVaultColor: vault '\(name)' NOT FOUND in vaults array (\(vaults.map(\.name)))")
        }

        // Persist to disk asynchronously
        Task {
            do {
                try await store.updateVaultEntry(named: name, displayName: existing?.displayName, color: color.isEmpty ? nil : color)
                print("[MahoNotes] setVaultColor: persisted successfully")
            } catch {
                print("[MahoNotes] setVaultColor: persist FAILED: \(error)")
            }
            await loadRegistryAsync()
            // Verify after reload
            if let reloaded = vaults.first(where: { $0.name == name }) {
                print("[MahoNotes] setVaultColor: after reload, color=\(reloaded.color ?? "nil")")
            }
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
        if selectedNotePath != nil && hasUnsavedChanges {
            saveNote()
        }

        reloadCurrentVault()

        // Directly enter editor mode — skip selectNote() to avoid
        // preview→editor flash that breaks @FocusState
        selectedNotePath = relativePath
        navigatorSelection = [relativePath]
        viewMode = .editor
        editingBody = selectedNote?.body ?? ""
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
            viewMode = .preview
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
            viewMode = .preview
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
