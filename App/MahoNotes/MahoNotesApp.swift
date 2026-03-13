import SwiftUI
import MahoNotesKit

@main
struct MahoNotesApp: App {
    @State private var appState = AppState()
    @AppStorage("appTheme") private var appTheme: String = "system"
    @Environment(\.scenePhase) private var scenePhase

    private var settingsColorScheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            await appState.syncCoordinator.syncOnActive()
                        }
                    }
                }
                // Note: GitHub Device Flow is used for auth — no URL scheme callback needed.
                // If deep-link processing is needed in the future, add .onOpenURL here.
        }
        #if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
        #if os(macOS)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Toggle Vault Rail") {
                    appState.toggleVaultRail()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Toggle Navigator") {
                    appState.toggleNavigator()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Focus Mode") {
                    appState.toggleFocusMode()
                }
                .keyboardShortcut("\\", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Cycle View Mode") {
                    appState.editorState.cycleViewMode()
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Search Notes") {
                    appState.searchManager.toggleSearch()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Find in Notes") {
                    appState.searchManager.toggleSearch()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(appState)
                .preferredColorScheme(settingsColorScheme)
        }
        #endif
    }
}
