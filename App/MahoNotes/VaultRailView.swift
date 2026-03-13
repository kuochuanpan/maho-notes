import SwiftUI
import MahoNotesKit

/// A — Narrow vertical vault rail (~48pt wide) on the left edge.
struct VaultRailView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddPopover = false
    @State private var addVaultMode: AddVaultMode?
    @State private var newVaultName = ""
    @State private var newVaultAuthor = ""
    @State private var githubRepo = ""
    @State private var githubVaultName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showingDeviceFlow = false
    @State private var didInitiateAuth = false
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
                showingAddPopover = true
                // Skip mode picker if GitHub not authenticated — go straight to create
                addVaultMode = appState.authManager.isAuthenticated ? nil : .create
                resetForm()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(
                        appState.vaults.isEmpty
                            ? AnyShapeStyle(MahoTheme.vaultRailBackground.mix(with: .white, by: 0.3))
                            : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(appState.vaults.isEmpty ? .white : .primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .shadow(
                color: appState.vaults.isEmpty ? MahoTheme.vaultRailBackground.mix(with: .white, by: 0.3).opacity(0.6) : .clear,
                radius: appState.vaults.isEmpty ? 8 : 0
            )
            .popover(isPresented: $showingAddPopover, arrowEdge: .trailing) {
                addVaultPopover
            }

            Divider()
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 6)

            // Scrollable vault icons
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    vaultGroup(appState.icloudVaults)
                    if !appState.icloudVaults.isEmpty && !appState.githubVaults.isEmpty {
                        divider
                    }
                    vaultGroup(appState.githubVaults)
                    if (!appState.icloudVaults.isEmpty || !appState.githubVaults.isEmpty)
                        && !appState.localVaults.isEmpty {
                        divider
                    }
                    vaultGroup(appState.localVaults)
                }
                .padding(.vertical, 6)
            }

            Spacer()

            // Settings pinned at bottom
            Divider()
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 6)

            #if os(macOS)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.vertical, 8)
            #else
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28, height: 28)
                .padding(.vertical, 8)
            #endif
        }
        .frame(width: 48)
        .background(MahoTheme.vaultRailBackground)
        .onChange(of: appState.authManager.userCode) { _, newValue in
            // Only show sheet if this view initiated the auth flow
            if didInitiateAuth {
                showingDeviceFlow = newValue != nil
            }
        }
        .onChange(of: appState.authManager.isAuthenticated) { _, authenticated in
            if authenticated {
                showingDeviceFlow = false
                didInitiateAuth = false
            }
        }
        .sheet(isPresented: $showingDeviceFlow, onDismiss: {
            didInitiateAuth = false
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
        .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) {
            colorPickerPanel
        }
    }

    // MARK: - Add Vault Popover

    private var hasGitHub: Bool { appState.authManager.isAuthenticated }

    @ViewBuilder
    private var addVaultPopover: some View {
        VStack(spacing: 0) {
            if addVaultMode == nil && hasGitHub {
                // Mode picker (only when GitHub is authenticated)
                VStack(spacing: 2) {
                    Text("Add Vault")
                        .font(.headline)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    Button {
                        withAnimation { addVaultMode = .create }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: appState.cloudSyncMode == .icloud ? "icloud" : "internaldrive")
                                .font(.title3)
                                .frame(width: 24)
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.horizontal, 12)

                    Button {
                        withAnimation { addVaultMode = .github }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.title3)
                                .frame(width: 24)
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 8)
                .frame(width: 260)

            } else if addVaultMode == .create || (addVaultMode == nil && !hasGitHub) {
                // Create new vault form
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if appState.authManager.isAuthenticated {
                            Button {
                                addVaultMode = nil
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }

                        Text("Create New Vault")
                            .font(.headline)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vault Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("e.g. personal, research", text: $newVaultName)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Author Name (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Your name", text: $newVaultAuthor)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Image(systemName: appState.cloudSyncMode == .icloud ? "icloud" : "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appState.cloudSyncMode == .icloud ? "Will sync via iCloud" : "Stored on this device only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Cancel") {
                            showingAddPopover = false
                        }
                        Spacer()
                        Button("Create") {
                            createVault()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newVaultName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    }
                }
                .padding(16)
                .frame(width: 280)

            } else if addVaultMode == .github {
                // Import from GitHub form
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            addVaultMode = nil
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)

                        Text("Import from GitHub")
                            .font(.headline)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub Repository")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("user/repo", text: $githubRepo)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vault Name (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Defaults to repo name", text: $githubVaultName)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Button("Cancel") {
                            showingAddPopover = false
                        }
                        Spacer()
                        Button(isCreating ? "Cloning..." : "Import") {
                            importFromGitHub()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(githubRepo.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    }
                }
                .padding(16)
                .frame(width: 300)
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
            showingAddPopover = false
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
                // Authenticate if no token is available yet.
                if !appState.authManager.isAuthenticated {
                    didInitiateAuth = true
                    try await appState.authManager.authenticate()
                    didInitiateAuth = false
                    // If user cancelled (authenticate() returns without throwing), stop.
                    guard appState.authManager.isAuthenticated else {
                        isCreating = false
                        return
                    }
                }

                let vaultName = githubVaultName.trimmingCharacters(in: .whitespaces)
                try await appState.importGitHubVault(
                    repo: repo,
                    name: vaultName.isEmpty ? nil : vaultName
                )
                showingAddPopover = false
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }

    // MARK: - Vault Group

    @ViewBuilder
    private func vaultGroup(_ entries: [VaultEntry]) -> some View {
        ForEach(entries, id: \.name) { entry in
            vaultIcon(entry)
        }
    }

    private var divider: some View {
        Divider()
            .overlay(Color.white.opacity(0.2))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    // MARK: - Vault Icon

    private func vaultIcon(_ entry: VaultEntry) -> some View {
        Button {
            appState.selectedVaultName = entry.name
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(String((entry.displayName ?? entry.name).prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(MahoTheme.resolvedVaultColor(for: entry), in: RoundedRectangle(cornerRadius: 8))

                if entry.type == .icloud {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 7))
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
                    .frame(width: 3, height: 20)
                    .offset(x: -6)
            }
        }
        .contextMenu {
            vaultContextMenu(entry)
        }
    }

    // MARK: - Vault Context Menu

    @ViewBuilder
    private func vaultContextMenu(_ entry: VaultEntry) -> some View {
        if let name = appState.authorName {
            Text(name)
        } else {
            Text("No author set")
        }

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

        Divider()

        #if os(macOS)
        SettingsLink {
            Label("Vault Settings", systemImage: "gearshape")
        }
        #endif
    }

    // MARK: - Color Picker Panel

    private var colorPickerPanel: some View {
        VStack(spacing: 8) {
            Text("Vault Color")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 6), spacing: 6) {
                ForEach(MahoTheme.vaultColorOptions) { option in
                    Button {
                        if let target = colorPickerTarget {
                            appState.setVaultColor(name: target.name, color: option.name)
                        }
                        showingColorPicker = false
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(option.color)
                            .frame(width: 28, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                            )
                            .overlay {
                                if colorPickerTarget?.color == option.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

}
