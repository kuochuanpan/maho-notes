import SwiftUI

/// Floating pill button at the bottom-right of C panel to cycle view modes.
struct FloatingToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button(action: { appState.cycleViewMode() }) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.isReadOnly ? .tertiary : .secondary)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .disabled(appState.isReadOnly)
        .help(tooltip)
        .padding(12)
    }

    private var iconName: String {
        switch appState.viewMode {
        case .preview: return "eye"
        case .editor: return "pencil"
        case .split: return "rectangle.split.2x1"
        }
    }

    private var tooltip: String {
        if appState.isReadOnly { return "Read-only vault" }
        switch appState.viewMode {
        case .preview: return "Switch to Editor (Cmd+E)"
        case .editor: return "Switch to Split (Cmd+E)"
        case .split: return "Switch to Preview (Cmd+E)"
        }
    }
}
