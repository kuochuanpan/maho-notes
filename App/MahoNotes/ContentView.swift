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
        NavigationStack {
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
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        appState.toggleNavigator()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Toggle Navigator (⌘⇧B)")
                }

                ToolbarItem(placement: .principal) {
                    TitleBarSearchField()
                }
            }
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

// MARK: - Title Bar Search Field

/// Search field embedded in the macOS title bar (like Slack).
/// Clicking or pressing ⌘K shows the search dropdown panel.
struct TitleBarSearchField: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.toggleSearch()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Search Maho Notes")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘K")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(width: 300)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(
            get: { appState.showSearchPanel },
            set: { newValue in
                if !newValue { appState.toggleSearch() }
            }
        ), arrowEdge: .bottom) {
            SearchPanelView()
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(AppState())
}
