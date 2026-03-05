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
    }
}
