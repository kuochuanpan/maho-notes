import SwiftUI

/// Root content view — NavigationSplitView shell.
/// Phase 4a: empty placeholder layout. Phase 4b will add vault rail + tree navigator + content.
struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            // B panel — Navigator (placeholder)
            sidebarContent
        } detail: {
            // C panel — Content (placeholder)
            detailContent
        }
        .task {
            appState.loadRegistry()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        if let errorMessage = appState.errorMessage {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Unable to Load Vaults")
                    .font(.headline)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    appState.reloadRegistry()
                }
            }
            .padding()
        } else if !appState.isLoaded {
            ProgressView("Loading vaults…")
                .padding()
        } else if appState.vaults.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No Vaults")
                    .font(.headline)
                Text("Create a vault to get started.\nUse `mn init` from the CLI or add one here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        } else {
            List(appState.vaults, id: \.name, selection: Binding(
                get: { appState.selectedVaultName },
                set: { appState.selectedVaultName = $0 }
            )) { vault in
                Label {
                    Text(vault.name)
                } icon: {
                    Image(systemName: vault.access == .readOnly ? "lock.fill" : "book.closed.fill")
                }
            }
            .navigationTitle("Maho Notes")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let vault = appState.selectedVault {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(vault.name)
                    .font(.title2)
                Text("Select a note to view")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.page")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Welcome to Maho Notes")
                    .font(.title2)
                Text("Select a vault from the sidebar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
