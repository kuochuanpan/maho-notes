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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationTitle("Maho Notes")
        } detail: {
            NoteContentView()
        }
        .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search notes...")
        .onChange(of: searchQuery) { _, newValue in
            scheduleSearch(newValue)
        }
        .onChange(of: selectedNotePath) { _, newValue in
            appState.selectNote(path: newValue)
        }
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

    @ViewBuilder
    private func iPadCollectionRow(node: FileTreeNode, depth: Int) -> some View {
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
