import SwiftUI

/// Root content view — A+B+C three-zone layout with collapsible panels.
/// A: VaultRailView (48pt) | B: NavigatorView (240pt) | C: NoteContentView (flexible)
struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if appState.isLoaded {
                    // A — Vault Rail
                    if appState.showVaultRail {
                        VaultRailView()
                        Divider()
                    }

                    // B — Tree Navigator
                    if appState.showNavigator {
                        NavigatorView()
                        Divider()
                    }
                }

                // Edge handle — thin strip to restore collapsed panels
                if appState.isLoaded && !appState.showNavigator {
                    edgeHandle
                }

                // C — Content
                NoteContentView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: appState.showNavigator)
            .animation(.easeInOut(duration: 0.2), value: appState.showVaultRail)
            .onChange(of: geo.size.width) { _, newWidth in
                handleAutoCollapse(width: newWidth)
            }
        }
        .task {
            appState.loadRegistry()
        }
        .onChange(of: appState.selectedVaultName) {
            appState.loadSelectedVault()
        }
    }

    // MARK: - Edge Handle

    private var edgeHandle: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if !appState.showVaultRail && !appState.showNavigator {
                    appState.showVaultRail = true
                    appState.showNavigator = true
                    appState.userShowVaultRail = true
                    appState.userShowNavigator = true
                } else {
                    appState.showNavigator = true
                    appState.userShowNavigator = true
                }
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    // MARK: - Auto-collapse

    private func handleAutoCollapse(width: CGFloat) {
        if width < 600 {
            appState.showVaultRail = false
            appState.showNavigator = false
        } else if width < 900 {
            appState.showVaultRail = appState.userShowVaultRail
            appState.showNavigator = false
        } else {
            appState.showVaultRail = appState.userShowVaultRail
            appState.showNavigator = appState.userShowNavigator
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
