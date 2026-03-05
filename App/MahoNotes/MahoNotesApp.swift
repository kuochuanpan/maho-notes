import SwiftUI
import MahoNotesKit

@main
struct MahoNotesApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
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
        }
    }
}
