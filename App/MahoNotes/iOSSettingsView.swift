#if os(iOS)
import SwiftUI
import MahoNotesKit

/// Form-based settings for iOS (replaces macOS Settings window).
struct iOSSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14
    @AppStorage("searchMode") private var searchMode: String = "text"
    @AppStorage("embeddingModel") private var embeddingModel: String = "minilm"
    @State private var vaultToRemove: String?
    @State private var isBuilding = false
    @State private var buildStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                // Vaults
                Section("Vaults") {
                    ForEach(appState.vaults, id: \.name) { entry in
                        vaultRow(entry)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Use `mn vault add` from the CLI to add vaults.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Search & Embedding
                Section("Search & Embedding") {
                    Picker("Default Search Mode", selection: $searchMode) {
                        Text("Text").tag("text")
                        Text("Semantic").tag("semantic")
                        Text("Hybrid").tag("hybrid")
                    }
                    .pickerStyle(.segmented)

                    Picker("Embedding Model", selection: $embeddingModel) {
                        ForEach(EmbeddingModel.allCases, id: \.rawValue) { model in
                            Text("\(model.displayName) (\(model.approximateSize))")
                                .tag(model.rawValue)
                        }
                    }

                    if let entry = appState.selectedVault {
                        let vaultPath = appState.store.resolvedPath(for: entry)
                        let hasVectorIndex = VectorIndex.vectorIndexExists(vaultPath: vaultPath)
                        HStack {
                            Text("Vector Index")
                            Spacer()
                            Text(hasVectorIndex ? "Available" : "Not built")
                                .foregroundStyle(hasVectorIndex ? .green : .secondary)
                        }
                    }

                    Button {
                        rebuildIndex()
                    } label: {
                        HStack {
                            if isBuilding {
                                ProgressView()
                                    .controlSize(.small)
                                Text(buildStatus ?? "Building...")
                                    .lineLimit(1)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                Text("Build Index (Text + Vector)")
                            }
                        }
                    }
                    .disabled(isBuilding || appState.selectedVault == nil)

                    if let status = buildStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Appearance
                Section("Appearance") {
                    Picker("Theme", selection: $appTheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Editor Font Size")
                            Spacer()
                            Text("\(Int(editorFontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $editorFontSize, in: 12...20, step: 1)
                    }
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    Link("GitHub", destination: URL(string: "https://github.com/kuochuanpan/maho-notes")!)
                    Link("Documentation", destination: URL(string: "https://github.com/kuochuanpan/maho-notes/blob/main/docs/DESIGN.md")!)
                }
            }
            .navigationTitle("Settings")
            .alert("Remove Vault", isPresented: Binding(
                get: { vaultToRemove != nil },
                set: { if !$0 { vaultToRemove = nil } }
            )) {
                Button("Cancel", role: .cancel) { vaultToRemove = nil }
                Button("Remove", role: .destructive) {
                    if let name = vaultToRemove {
                        appState.removeVault(name: name)
                    }
                    vaultToRemove = nil
                }
            } message: {
                Text("Remove \"\(vaultToRemove ?? "")\" from the registry? Files on disk will not be deleted.")
            }
        }
    }

    private func vaultRow(_ entry: VaultEntry) -> some View {
        HStack {
            Image(systemName: typeIcon(entry.type))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .fontWeight(.medium)
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

            Spacer()

            if appState.primaryVaultName != entry.name {
                Button("Set Primary") {
                    appState.setPrimaryVault(name: entry.name)
                }
                .controlSize(.small)
            }

            Button(role: .destructive) {
                vaultToRemove = entry.name
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(appState.vaults.count <= 1)
        }
    }

    private func typeIcon(_ type: VaultType) -> String {
        switch type {
        case .icloud: return "icloud"
        case .github: return "network"
        case .local: return "folder"
        case .device: return "internaldrive"
        }
    }

    private nonisolated static func buildVectorIndex(
        vaultPath: String,
        notes: [Note],
        model: EmbeddingModel,
        onStatus: @Sendable (String) -> Void
    ) async throws -> Int {
        let provider = SwiftEmbeddingsProvider(model: model)
        let embedder: @Sendable ([String]) async throws -> [[Float]] = { texts in
            try await provider.embedBatch(texts)
        }

        let vecIndex: VectorIndex
        do {
            vecIndex = try VectorIndex(vaultPath: vaultPath, dimensions: model.dimensions)
        } catch let error as VectorIndexError {
            if case .dimensionMismatch = error {
                let idx = try VectorIndex(
                    vaultPath: vaultPath,
                    dimensions: model.dimensions,
                    skipDimensionCheck: true
                )
                try idx.resetSchema()
                onStatus("Building vector index (full rebuild)...")
                let vecStats = try await idx.buildIndex(
                    notes: notes,
                    asyncEmbedder: embedder,
                    model: model.rawValue,
                    fullRebuild: true
                )
                return vecStats.totalChunks
            }
            throw error
        }

        onStatus("Building vector index...")
        let vecStats = try await vecIndex.buildIndex(
            notes: notes,
            asyncEmbedder: embedder,
            model: model.rawValue,
            fullRebuild: true
        )
        return vecStats.totalChunks
    }

    private func rebuildIndex() {
        guard let entry = appState.selectedVault else { return }
        isBuilding = true
        buildStatus = nil

        Task {
            let vaultPath = appState.store.resolvedPath(for: entry)
            let vault = Vault(path: vaultPath)

            do {
                let notes = try vault.allNotes()

                // 1. Build FTS index
                await MainActor.run { buildStatus = "Building text index..." }
                let searchIndex = try SearchIndex(vaultPath: vaultPath)
                let ftsStats = try searchIndex.buildIndex(notes: notes, fullRebuild: true)

                // 2. Build vector index
                guard let model = EmbeddingModel(rawValue: embeddingModel) else {
                    await MainActor.run {
                        buildStatus = "FTS: \(ftsStats.total) notes. Unknown embedding model."
                        isBuilding = false
                    }
                    return
                }

                await MainActor.run {
                    buildStatus = "Downloading \(model.displayName) (\(model.approximateSize))..."
                }

                let totalNotes = ftsStats.total
                let vecChunks = try await Self.buildVectorIndex(
                    vaultPath: vaultPath,
                    notes: notes,
                    model: model,
                    onStatus: { status in
                        Task { @MainActor in buildStatus = status }
                    }
                )

                await MainActor.run {
                    buildStatus = "Done: \(totalNotes) notes, \(vecChunks) chunks"
                    isBuilding = false
                }
            } catch {
                await MainActor.run {
                    buildStatus = "Error: \(error.localizedDescription)"
                    isBuilding = false
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
#endif
