import SwiftUI

/// Root content view — A+B+C three-zone layout.
/// A: VaultRailView (48pt) | B: NavigatorView (240pt) | C: NoteContentView (flexible)
struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            if appState.isLoaded {
                // A — Vault Rail
                VaultRailView()
                Divider()

                // B — Tree Navigator
                NavigatorView()
                Divider()
            }

            // C — Content
            NoteContentView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            appState.loadRegistry()
        }
        .onChange(of: appState.selectedVaultName) {
            appState.loadSelectedVault()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
