#if os(macOS)
import SwiftUI
import MahoNotesKit

/// Sheet for adding a new vault on macOS (create local/iCloud or import from GitHub).
/// Replaces the popover approach which crashes when content size changes.
struct MacAddVaultSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode?
    private var hasGitHub: Bool { appState.authManager.isAuthenticated }
    @State private var newVaultName = ""
    @State private var newVaultAuthor = ""
    @State private var githubRepo = ""
    @State private var githubVaultName = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showingDeviceFlow = false
    @State private var didInitiateAuth = false

    private enum Mode: Identifiable {
        case create, github
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                if mode != nil && hasGitHub {
                    Button {
                        withAnimation { mode = nil; errorMessage = nil }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }

                Text(navigationTitle)
                    .font(.headline)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Content
            Group {
                if mode == nil && hasGitHub {
                    modePicker
                } else if mode == .create || (mode == nil && !hasGitHub) {
                    createVaultForm
                } else {
                    githubImportForm
                }
            }
        }
        .frame(width: 340)
        .onChange(of: appState.authManager.userCode) { _, newValue in
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
        VStack(spacing: 2) {
            Button {
                withAnimation { mode = .create }
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.horizontal, 16)

            Button {
                withAnimation { mode = .github }
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
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Create Vault Form

    private var createVaultForm: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Spacer()
                Button("Create") {
                    createVault()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newVaultName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(16)
    }

    // MARK: - GitHub Import Form

    private var githubImportForm: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                Spacer()
                Button(isCreating ? "Cloning..." : "Import") {
                    importFromGitHub()
                }
                .buttonStyle(.borderedProminent)
                .disabled(githubRepo.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func createVault() {
        let name = newVaultName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        do {
            try appState.createNewVault(name: name, authorName: newVaultAuthor.trimmingCharacters(in: .whitespaces))
            dismiss()
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
                    didInitiateAuth = true
                    try await appState.authManager.authenticate()
                    didInitiateAuth = false
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
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
#endif
