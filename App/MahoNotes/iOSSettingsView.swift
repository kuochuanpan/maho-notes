#if os(iOS)
import SwiftUI
import MahoNotesKit

/// Form-based settings for iOS (replaces macOS Settings window).
struct iOSSettingsView: View {
    @Environment(AppState.self) private var appState
    var onDismiss: (() -> Void)?
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
                // Cloud Sync
                Section("Cloud Sync") {
                    HStack(spacing: 12) {
                        Image(systemName: "icloud")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud Sync")
                                .fontWeight(.medium)
                            Text("Sync vaults and settings via iCloud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if appState.cloudSync.isMigrating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Picker("", selection: Binding(
                                get: { appState.cloudSync.cloudSyncMode },
                                set: { appState.cloudSync.requestCloudSyncChange(to: $0) }
                            )) {
                                Text("iCloud").tag(CloudSyncMode.icloud)
                                Text("Off").tag(CloudSyncMode.off)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                        }
                    }

                    if let status = appState.cloudSync.migrationStatus {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // GitHub
                Section("GitHub") {
                    gitHubAccountRow
                    if !appState.vaults.filter({ $0.github != nil }).isEmpty {
                        gitHubSyncRow
                    }
                }

                // Vaults
                Section("Vaults") {
                    ForEach(appState.vaults, id: \.name) { entry in
                        vaultRow(entry)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Use the + button in the vault rail to add vaults.")
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

                // Tip Jar
                Section("Support") {
                    TipJarView()
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
            .toolbar {
                if let onDismiss {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDismiss)
                    }
                }
            }
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
            // Cloud Sync Merge Sheet
            .sheet(isPresented: Binding(
                get: { appState.cloudSync.showMergeSheet },
                set: { if !$0 { appState.cloudSync.cancelMerge() } }
            )) {
                iOSCloudSyncMergeSheet()
            }
            // Merge Result Alert
            .alert("Merge Complete", isPresented: Binding(
                get: { appState.cloudSync.showMergeResult },
                set: { _ in appState.cloudSync.showMergeResult = false }
            )) {
                Button("OK") { appState.cloudSync.showMergeResult = false }
            } message: {
                let conflicts = appState.cloudSync.lastMergeConflicts
                if conflicts.isEmpty {
                    Text("Vaults merged successfully with no conflicts.")
                } else {
                    Text("Merged with \(conflicts.count) rename(s):\n" +
                         conflicts.map { "• \"\($0.originalName)\" → \"\($0.localRenamed)\" (local) & \"\($0.cloudRenamed)\" (cloud)" }
                             .joined(separator: "\n"))
                }
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
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                vaultToRemove = entry.name
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(appState.vaults.count <= 1)
        }
    }

    // MARK: - GitHub Account Row (compact, vault-row style)

    private var gitHubAccountRow: some View {
        HStack {
            Image(systemName: "person.badge.key")
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("Account")
                    .fontWeight(.medium)
                if appState.authManager.isAuthenticated, let username = appState.authManager.username {
                    Text("@\(username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if appState.authManager.isAuthenticating {
                    Text("Authorizing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if appState.authManager.isAuthenticating && appState.authManager.userCode == nil {
                ProgressView()
                    .controlSize(.small)
            } else if appState.authManager.isAuthenticating && !appState.authManager.showDeviceFlowSheet {
                // Sheet was dismissed (e.g. user went to Safari) — show inline cancel
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        appState.authManager.cancelAuth()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            } else if appState.authManager.isAuthenticated {
                Button("Disconnect") {
                    appState.authManager.disconnect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if !appState.authManager.isAuthenticating {
                Button("Connect") {
                    Task {
                        try? await appState.authManager.authenticate()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.authManager.showDeviceFlowSheet },
            set: { newValue in
                if !newValue {
                    appState.authManager.showDeviceFlowSheet = false
                }
            }
        )) {
            DeviceFlowSheet(authManager: appState.authManager)
                .interactiveDismissDisabled(appState.authManager.isAuthenticating)
        }
    }

    // MARK: - GitHub Sync Row (compact, vault-row style)

    private var gitHubSyncRow: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sync")
                    .fontWeight(.medium)
                if let lastSync = appState.syncCoordinator.lastSyncDate {
                    Text("Last synced \(lastSync, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not yet synced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if appState.syncCoordinator.isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Sync Now") {
                    appState.syncCoordinator.syncNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
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

// MARK: - iOS Cloud Sync Merge Sheet

/// Merge sheet for iOS — same content as macOS VaultsSettingsTab's cloudSyncMergeSheet.
private struct iOSCloudSyncMergeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let cloudVaults = appState.cloudSync.pendingCloudRegistry?.vaults ?? []
            VStack(spacing: 16) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)

                Text("iCloud Already Has Vaults")
                    .font(.headline)

                Text("Found \(cloudVaults.count) vault(s) in iCloud. How would you like to proceed?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cloudVaults, id: \.name) { vault in
                            HStack(spacing: 6) {
                                Image(systemName: typeIcon(vault.type))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(vault.name)
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: 280)

                VStack(spacing: 8) {
                    Button(action: { appState.cloudSync.performMerge() }) {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: { appState.cloudSync.replaceCloudWithLocal() }) {
                        Label("Replace with Local", systemImage: "arrow.up.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Cancel", role: .cancel) {
                        appState.cloudSync.cancelMerge()
                    }
                    .controlSize(.large)
                }
                .frame(width: 240)

                Text("Merge combines both sets of vaults.\nConflicting names will be renamed with a device suffix.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .navigationTitle("Cloud Sync")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func typeIcon(_ type: VaultType) -> String {
        switch type {
        case .icloud: return "icloud"
        case .github: return "network"
        case .local: return "folder"
        case .device: return "internaldrive"
        }
    }
}
#endif
