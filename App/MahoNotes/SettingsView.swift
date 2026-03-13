import SwiftUI
import MahoNotesKit

#if os(macOS)
struct SettingsView: View {
    var body: some View {
        TabView {
            VaultsSettingsTab()
                .tabItem {
                    Label("Vaults", systemImage: "externaldrive")
                }

            SearchSettingsTab()
                .tabItem {
                    Label("Search & Embedding", systemImage: "magnifyingglass")
                }

            AppearanceSettingsTab()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
    }
}
#endif

// MARK: - Vaults Tab

struct VaultsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var vaultToRemove: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // MARK: - Cloud Sync
            GroupBox {
                HStack(spacing: 12) {
                    Image(systemName: "icloud")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloud Sync")
                            .fontWeight(.medium)
                        Text("Sync vaults and settings via iCloud")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("", selection: Binding(
                        get: { appState.cloudSyncMode },
                        set: { appState.requestCloudSyncChange(to: $0) }
                    )) {
                        Text("iCloud").tag(CloudSyncMode.icloud)
                        Text("Off").tag(CloudSyncMode.off)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
                .padding(4)
            }
            .padding(.horizontal, 4)

            // MARK: - GitHub Account
            GitHubAccountGroupBox(authManager: appState.authManager)
                .padding(.horizontal, 4)

            // MARK: - GitHub Sync
            if !appState.vaults.filter({ $0.github != nil }).isEmpty {
                GitHubSyncGroupBox(coordinator: appState.syncCoordinator)
                    .padding(.horizontal, 4)
            }

            // MARK: - Vault List
            List {
                ForEach(appState.vaults, id: \.name) { entry in
                    vaultRow(entry)
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            #endif

            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Use `mn vault add` from the CLI to add vaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding()
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
        // MARK: - Cloud Sync Merge Sheet
        .sheet(isPresented: Binding(
            get: { appState.showMergeSheet },
            set: { if !$0 { appState.cancelMerge() } }
        )) {
            cloudSyncMergeSheet
        }
        // MARK: - Merge Result Alert
        .alert("Merge Complete", isPresented: Binding(
            get: { appState.showMergeResult },
            set: { _ in appState.showMergeResult = false }
        )) {
            Button("OK") { appState.showMergeResult = false }
        } message: {
            let conflicts = appState.lastMergeConflicts
            if conflicts.isEmpty {
                Text("Vaults merged successfully with no conflicts.")
            } else {
                Text("Merged with \(conflicts.count) rename(s):\n" +
                     conflicts.map { "• \"\($0.originalName)\" → \"\($0.localRenamed)\" (local) & \"\($0.cloudRenamed)\" (cloud)" }
                         .joined(separator: "\n"))
            }
        }
    }

    // MARK: - Merge Sheet View

    @ViewBuilder
    private var cloudSyncMergeSheet: some View {
        let cloudVaults = appState.pendingCloudRegistry?.vaults ?? []
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
                Button(action: { appState.performMerge() }) {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: { appState.replaceCloudWithLocal() }) {
                    Label("Replace with Local", systemImage: "arrow.up.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Cancel", role: .cancel) {
                    appState.cancelMerge()
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
        .frame(width: 360)
    }

    private func vaultRow(_ entry: VaultEntry) -> some View {
        HStack {
            Image(systemName: typeIcon(entry.type))
                .foregroundStyle(.secondary)
                .frame(width: 20)

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
                Text(noteCountLabel(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func noteCountLabel(for entry: VaultEntry) -> String {
        let vaultPath = appState.store.resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        let count = (try? vault.allNotes().count) ?? 0
        return "\(count) note\(count == 1 ? "" : "s")"
    }
}

// MARK: - Appearance Tab

struct AppearanceSettingsTab: View {
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Search & Embedding Tab

struct SearchSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage("searchMode") private var searchMode: String = "text"
    @AppStorage("embeddingModel") private var embeddingModel: String = "minilm"
    @State private var isBuilding = false
    @State private var buildStatus: String?

    var body: some View {
        Form {
            // Search Mode
            Picker("Default Search Mode", selection: $searchMode) {
                Text("Text (FTS5)").tag("text")
                Text("Semantic").tag("semantic")
                Text("Hybrid").tag("hybrid")
            }
            .pickerStyle(.segmented)

            // Embedding Model
            Section {
                ForEach(EmbeddingModel.allCases, id: \.rawValue) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .fontWeight(embeddingModel == model.rawValue ? .semibold : .regular)
                            HStack(spacing: 8) {
                                Text("\(model.dimensions) dimensions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.approximateSize)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if embeddingModel == model.rawValue {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        embeddingModel = model.rawValue
                    }
                }
            } header: {
                Text("Embedding Model")
            } footer: {
                Text("Model downloads automatically from HuggingFace on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Index Status — All Vaults
            Section("Index Status") {
                if appState.vaults.isEmpty {
                    Text("No vaults configured")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.vaults, id: \.name) { entry in
                        let vaultPath = appState.store.resolvedPath(for: entry)
                        let hasVectorIndex = VectorIndex.vectorIndexExists(vaultPath: vaultPath)
                        let indexPath = (vaultPath as NSString).appendingPathComponent(".maho/index.db")
                        let hasFTS = FileManager.default.fileExists(atPath: indexPath)

                        HStack {
                            Image(systemName: vaultIcon(for: entry))
                                .frame(width: 20)
                            Text(entry.name)
                            Spacer()
                            Label(hasFTS ? "FTS" : "FTS", systemImage: hasFTS ? "checkmark.circle.fill" : "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(hasFTS ? .green : .secondary)
                            Label(hasVectorIndex ? "Vec" : "Vec", systemImage: hasVectorIndex ? "checkmark.circle.fill" : "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(hasVectorIndex ? .green : .secondary)
                        }
                    }
                }
            }

            // Build Index — All Vaults
            Section {
                Button {
                    rebuildAllIndexes()
                } label: {
                    HStack {
                        if isBuilding {
                            ProgressView()
                                .controlSize(.small)
                            Text(buildStatus ?? "Building...")
                                .lineLimit(1)
                        } else {
                            Image(systemName: "arrow.clockwise")
                            Text("Build All Indexes (Text + Vector)")
                        }
                    }
                }
                .disabled(isBuilding || appState.vaults.isEmpty)

                if let status = buildStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func vaultIcon(for entry: VaultEntry) -> String {
        switch entry.type {
        case .icloud: "icloud"
        case .github: "arrow.triangle.branch"
        case .local: "folder"
        case .device: "internaldrive"
        }
    }

    /// Build vector index in a nonisolated context to avoid Sendable issues.
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
                onStatus("Building vector index (model changed, full rebuild)...")
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

    private func rebuildAllIndexes() {
        isBuilding = true
        buildStatus = nil

        Task {
            guard let model = EmbeddingModel(rawValue: embeddingModel) else {
                await MainActor.run {
                    buildStatus = "Unknown embedding model."
                    isBuilding = false
                }
                return
            }

            var totalNotes = 0
            var totalChunks = 0
            let vaultCount = appState.vaults.count

            do {
                for (i, entry) in appState.vaults.enumerated() {
                    let vaultPath = appState.store.resolvedPath(for: entry)
                    let vault = Vault(path: vaultPath)
                    let notes = try vault.allNotes()

                    // FTS
                    await MainActor.run {
                        buildStatus = "[\(i+1)/\(vaultCount)] \(entry.name): building text index..."
                    }
                    let searchIndex = try SearchIndex(vaultPath: vaultPath)
                    let ftsStats = try searchIndex.buildIndex(notes: notes, fullRebuild: true)
                    totalNotes += ftsStats.total

                    // Vector
                    await MainActor.run {
                        buildStatus = "[\(i+1)/\(vaultCount)] \(entry.name): building vector index..."
                    }
                    let chunks = try await Self.buildVectorIndex(
                        vaultPath: vaultPath,
                        notes: notes,
                        model: model,
                        onStatus: { status in
                            Task { @MainActor in buildStatus = "[\(i+1)/\(vaultCount)] \(entry.name): \(status)" }
                        }
                    )
                    totalChunks += chunks
                }

                await MainActor.run {
                    buildStatus = "Done: \(vaultCount) vaults, \(totalNotes) notes, \(totalChunks) chunks"
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
}

// MARK: - GitHub Account GroupBox

struct GitHubAccountGroupBox: View {
    let authManager: GitHubAuthManager
    @State private var showingDeviceFlow = false
    @State private var didInitiateAuth = false

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.key")
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub Account")
                        .fontWeight(.medium)
                    if authManager.isAuthenticated, let username = authManager.username {
                        Text("@\(username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if authManager.isAuthenticating {
                        Text("Waiting for authorization…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = authManager.authError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if authManager.isAuthenticating && authManager.userCode == nil {
                    ProgressView()
                        .controlSize(.small)
                } else if authManager.isAuthenticated {
                    Button("Disconnect") {
                        authManager.disconnect()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                } else if !authManager.isAuthenticating {
                    Button("Connect to GitHub") {
                        Task {
                            didInitiateAuth = true
                            try? await authManager.authenticate()
                            didInitiateAuth = false
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(4)
        }
        .onChange(of: authManager.userCode) { _, newValue in
            if didInitiateAuth {
                showingDeviceFlow = newValue != nil
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, authenticated in
            if authenticated {
                showingDeviceFlow = false
                didInitiateAuth = false
            }
        }
        .sheet(isPresented: $showingDeviceFlow, onDismiss: {
            didInitiateAuth = false
            if !authManager.isAuthenticated {
                authManager.cancelAuth()
            }
        }) {
            DeviceFlowSheet(authManager: authManager)
        }
    }
}

// MARK: - Device Flow Sheet

/// A modal sheet that displays the GitHub Device Flow verification code
/// and opens the browser when the user confirms.
struct DeviceFlowSheet: View {
    let authManager: GitHubAuthManager
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.purple)

            Text("Connect to GitHub")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter this code on GitHub to authorize Maho Notes:")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let userCode = authManager.userCode {
                Text(userCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 24)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)

                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                    #else
                    UIPasteboard.general.string = userCode
                    #endif
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied!" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()
                .padding(.horizontal, 40)

            if let url = authManager.verificationURL, let destination = URL(string: url) {
                Button {
                    // Copy code to clipboard automatically, then open browser
                    if let userCode = authManager.userCode {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(userCode, forType: .string)
                        #else
                        UIPasteboard.general.string = userCode
                        #endif
                    }
                    #if os(macOS)
                    NSWorkspace.shared.open(destination)
                    #else
                    UIApplication.shared.open(destination)
                    #endif
                } label: {
                    Label("Open GitHub & Paste Code", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for authorization…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 380, minHeight: 360)
    }
}

// MARK: - GitHub Sync GroupBox

struct GitHubSyncGroupBox: View {
    let coordinator: SyncCoordinator

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub Sync")
                        .fontWeight(.medium)
                    if let lastSync = coordinator.lastSyncDate {
                        Text("Last synced \(lastSync, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not yet synced this session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = coordinator.lastSyncError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if coordinator.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Sync Now") {
                        coordinator.syncNow()
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            .padding(4)
        }
    }
}

// MARK: - About Tab

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Maho Notes")
                .font(.title2.bold())

            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/kuochuanpan/maho-notes")!)
                Link("Documentation", destination: URL(string: "https://github.com/kuochuanpan/maho-notes/blob/main/docs/DESIGN.md")!)
            }
            .font(.callout)

            Text("Made with \u{2615} by Kuo-Chuan & Maho \u{1F52D}")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
