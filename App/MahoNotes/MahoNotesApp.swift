import SwiftUI
import MahoNotesKit

@main
struct MahoNotesApp: App {
    @State private var appState = AppState()
    @AppStorage("appTheme") private var appTheme: String = "system"

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
                    appState.cycleViewMode()
                }
                .keyboardShortcut("e", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Search Notes") {
                    appState.toggleSearch()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Find in Notes") {
                    appState.toggleSearch()
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
