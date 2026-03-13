#if os(iOS)
import SwiftUI
import MahoNotesKit

/// Sheet for adding a new vault (create local/iCloud or import from GitHub).
struct IPadAddVaultSheet: View {
    @Environment(AppState.self) private var appState
    @Binding var isPresented: Bool
    /// When GitHub is not authenticated, skip the mode picker and go straight to create.
    @State private var mode: Mode?
    private var hasGitHub: Bool { appState.authManager.isAuthenticated }
    @State private var newVaultName = ""
    @State private var newVaultAuthor = ""
    @State private var githubRepo = ""
    @State private var githubVaultName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private enum Mode: Identifiable {
        case create, github
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Group {
                if mode == nil && hasGitHub {
                    modePicker
                } else if mode == .create || (mode == nil && !hasGitHub) {
                    createVaultForm
                } else {
                    githubImportForm
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if mode != nil && hasGitHub {
                        Button("Back") { mode = nil; errorMessage = nil }
                    } else {
                        Button("Cancel") { isPresented = false }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if mode == .create || (mode == nil && !hasGitHub) {
                        Button("Create") { createVault() }
                            .disabled(newVaultName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    } else if mode == .github {
                        Button(isCreating ? "Cloning..." : "Import") { importFromGitHub() }
                            .disabled(githubRepo.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        switch mode {
        case .none: return hasGitHub ? "Add Vault" : "Create New Vault"
        case .create: return "Create New Vault"
        case .github: return "Import from GitHub"
        }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        List {
            Button {
                mode = .create
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: appState.cloudSync.cloudSyncMode == .icloud ? "icloud" : "internaldrive")
                        .font(.title3)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create New Vault")
                            .fontWeight(.medium)
                        Text(appState.cloudSync.cloudSyncMode == .icloud ? "Stored in iCloud" : "Stored on this device")
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
                mode = .github
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

    // MARK: - Create Vault Form

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
                    Image(systemName: appState.cloudSync.cloudSyncMode == .icloud ? "icloud" : "internaldrive")
                        .foregroundStyle(.secondary)
                    Text(appState.cloudSync.cloudSyncMode == .icloud ? "Will sync via iCloud" : "Stored on this device only")
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

    // MARK: - GitHub Import Form

    private var githubImportForm: some View {
        ZStack {
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
            .opacity(isCreating ? 0.3 : 1)
            .allowsHitTesting(!isCreating)

            if isCreating {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Cloning repository…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func createVault() {
        let name = newVaultName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        do {
            try appState.createNewVault(name: name, authorName: newVaultAuthor.trimmingCharacters(in: .whitespaces))
            isPresented = false
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
                    isPresented = false
                    // Small delay to let sheet dismiss animation complete
                    try await Task.sleep(for: .milliseconds(400))
                    try await appState.authManager.authenticate()
                    guard appState.authManager.isAuthenticated else {
                        isCreating = false
                        return
                    }
                    // Re-open add vault sheet to continue the import
                    isPresented = true
                    mode = .github
                    // Wait for sheet to present
                    try await Task.sleep(for: .milliseconds(400))
                }
                let vaultName = githubVaultName.trimmingCharacters(in: .whitespaces)
                try await appState.importGitHubVault(
                    repo: repo,
                    name: vaultName.isEmpty ? nil : vaultName
                )
                isPresented = false
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
#endif
