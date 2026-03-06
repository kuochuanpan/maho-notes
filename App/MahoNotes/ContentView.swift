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
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        @Bindable var state = appState

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
            .navigationTitle("Maho Notes")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        appState.toggleNavigator()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("Toggle Navigator (⌘⇧B)")
                }

                // Search mode picker in the toolbar
                ToolbarItem(placement: .automatic) {
                    Picker("Mode", selection: $state.searchMode) {
                        Text("Text").tag("text")
                        Text("Semantic").tag("semantic")
                        Text("Hybrid").tag("hybrid")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .opacity(appState.showSearchPanel ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: appState.showSearchPanel)
                }
            }
        }
        .searchable(
            text: $state.searchQuery,
            isPresented: $state.showSearchPanel,
            placement: .toolbar,
            prompt: "Search Maho Notes"
        )
        .searchScopes($state.searchScope) {
            Text("All Vaults").tag("allVaults")
            Text("This Vault").tag("thisVault")
        }
        .searchSuggestions {
            if let error = appState.searchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                ForEach(appState.searchResults, id: \.relativePath) { note in
                    Button {
                        appState.selectSearchResult(note)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .font(.body)
                                .fontWeight(.medium)
                            Text(note.collection)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onChange(of: appState.searchQuery) {
            scheduleSearch()
        }
        .onChange(of: appState.searchScope) { _, _ in
            scheduleSearch()
        }
        .onChange(of: appState.searchMode) { _, _ in
            scheduleSearch()
        }
        .onChange(of: appState.showSearchPanel) { _, isPresented in
            if !isPresented {
                appState.clearSearch()
            }
        }
    }

    // MARK: - Debounced Search

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            appState.performSearch()
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
#endif

#Preview {
    ContentView()
        .environment(AppState())
}
