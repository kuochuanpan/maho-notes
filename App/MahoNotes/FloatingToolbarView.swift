import SwiftUI

/// Floating pill button at the bottom-right of C panel to cycle view modes.
struct FloatingToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        #if os(macOS)
        macOSFloatingButton
        #else
        // iPhone Duo: where the system lays bars out vertically, both iOS
        // layouts put the view-mode toggle into that bar on the trailing edge
        // (iPhoneContentView's note detail, IPadContentView's detail column),
        // so the bottom-corner pill steps aside.
        ToolbarVerticalEdgeReader { verticalEdge in
            if verticalEdge == nil {
                iOSFloatingButton
            }
        }
        #endif
    }

    #if os(macOS)
    private var macOSFloatingButton: some View {
        Button(action: { appState.editorState.cycleViewMode() }) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.editorState.isReadOnly ? .tertiary : .secondary)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .disabled(appState.editorState.isReadOnly)
        .help(tooltip)
        .padding(12)
    }
    #else
    private var iOSFloatingButton: some View {
        Button(action: { appState.editorState.cycleViewMode() }) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44) // Touch-friendly tap target
        }
        .buttonStyle(.plain)
        .foregroundStyle(appState.editorState.isReadOnly ? .tertiary : .secondary)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .disabled(appState.editorState.isReadOnly)
        .padding(12)
        .keyboardShortcut("e", modifiers: .command) // ⌘E for iPad external keyboard
    }
    #endif

    private var iconName: String {
        appState.editorState.viewMode.systemImage
    }

    #if os(macOS)
    private var tooltip: String {
        if appState.editorState.isReadOnly { return "Read-only vault" }
        switch appState.editorState.viewMode {
        case .preview: return "Switch to Editor (Cmd+E)"
        case .editor: return "Switch to Split (Cmd+E)"
        case .split: return "Switch to Preview (Cmd+E)"
        }
    }
    #endif
}
