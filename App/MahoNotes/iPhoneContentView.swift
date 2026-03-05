#if os(iOS)
import SwiftUI
import MahoNotesKit

/// Tab-based navigation for iPhone/iPad.
/// Tab 1: Vaults drill-down (vault list -> collections -> notes -> note detail)
/// Tab 2: Search
/// Tab 3: Settings
struct iPhoneContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            Tab("Vaults", systemImage: "books.vertical") {
                VaultNavigationView()
            }

            Tab("Search", systemImage: "magnifyingglass") {
                iOSSearchView()
            }

            Tab("Settings", systemImage: "gear") {
                iOSSettingsView()
            }
        }
    }
}

// MARK: - Vault Navigation (Drill-Down)

struct VaultNavigationView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            List {
                if !appState.icloudVaults.isEmpty {
                    Section("iCloud") {
                        ForEach(appState.icloudVaults, id: \.name) { entry in
                            vaultLink(entry)
                        }
                    }
                }
                if !appState.githubVaults.isEmpty {
                    Section("GitHub") {
                        ForEach(appState.githubVaults, id: \.name) { entry in
                            vaultLink(entry)
                        }
                    }
                }
                if !appState.localVaults.isEmpty {
                    Section("Local") {
                        ForEach(appState.localVaults, id: \.name) { entry in
                            vaultLink(entry)
                        }
                    }
                }
            }
            .navigationTitle("Vaults")
        }
    }

    private func vaultLink(_ entry: VaultEntry) -> some View {
        NavigationLink(value: entry.name) {
            HStack {
                Text(entry.name)
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
            }
        }
        .navigationDestination(for: String.self) { vaultName in
            CollectionListView(vaultName: vaultName)
        }
    }
}

// MARK: - Collection List

struct CollectionListView: View {
    @Environment(AppState.self) private var appState
    let vaultName: String

    private var vault: Vault? {
        guard let entry = appState.vaults.first(where: { $0.name == vaultName }) else { return nil }
        return Vault(path: resolvedPath(for: entry))
    }

    private var collections: [Collection] {
        (try? vault?.collections()) ?? []
    }

    private func notes(for collectionId: String) -> [Note] {
        let all = (try? vault?.allNotes()) ?? []
        return all.filter { $0.collection == collectionId }.sorted { $0.title < $1.title }
    }

    var body: some View {
        List {
            ForEach(collections, id: \.id) { collection in
                NavigationLink(value: collection) {
                    Label(collection.name, systemImage: collection.icon)
                }
            }
        }
        .navigationTitle(vaultName)
        .navigationDestination(for: Collection.self) { collection in
            NoteListView(vaultName: vaultName, collection: collection)
        }
        .onAppear {
            appState.selectedVaultName = vaultName
        }
    }
}

// MARK: - Note List

struct NoteListView: View {
    @Environment(AppState.self) private var appState
    let vaultName: String
    let collection: Collection

    var body: some View {
        List {
            ForEach(appState.notes(for: collection.id), id: \.relativePath) { note in
                NavigationLink(value: note) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                            .lineLimit(1)
                        Text(note.updated)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(collection.name)
        .navigationDestination(for: Note.self) { note in
            NoteDetailView(note: note)
        }
    }
}

// MARK: - Note Detail

struct NoteDetailView: View {
    @Environment(AppState.self) private var appState
    let note: Note

    var body: some View {
        MarkdownWebView(markdown: "# \(note.title)\n\n\(note.body)")
            .navigationTitle(note.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                appState.selectedNotePath = note.relativePath
            }
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
                        NoteDetailView(note: note)
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
            let vault = Vault(path: resolvedPath(for: entry))
            results = (try? Array(vault.searchNotes(query: trimmed).prefix(20))) ?? []
        }
    }
}
#endif
