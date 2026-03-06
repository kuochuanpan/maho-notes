import SwiftUI

/// Root content view — routes to platform-specific layouts.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("appTheme") private var appTheme: String = "system"

    private var colorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        Group {
            #if os(macOS)
            MacContentView()
            #else
            iPhoneContentView()
            #endif
        }
        .preferredColorScheme(colorScheme)
        .task {
            appState.loadRegistry()
        }
        .onChange(of: appState.selectedVaultName) {
            appState.loadSelectedVault()
        }
    }
}

// MARK: - macOS Layout

#if os(macOS)
/// A+B+C three-zone layout with collapsible panels.
/// A: VaultRailView (48pt) | B: NavigatorView (240pt) | C: NoteContentView (flexible)
struct MacContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack(alignment: .top) {
            // Main A+B+C content
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

            // Search panel overlay — drops down from top center when active
            if appState.showSearchPanel {
                searchOverlay
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.toggleNavigator()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Toggle Navigator (⌘⇧B)")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    appState.toggleSearch()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search (⌘K)")
            }
        }
    }

    // MARK: - Search Overlay

    /// Floating search panel that drops down from the top center of the window.
    private var searchOverlay: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — click to dismiss
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.toggleSearch()
                }

            // Search panel — clicks here do NOT dismiss
            SearchPanelView()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .frame(width: 480)
                .padding(.top, 8)
                .onTapGesture { /* absorb tap — prevent dismiss */ }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
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
#endif

#Preview {
    ContentView()
        .environment(AppState())
}
