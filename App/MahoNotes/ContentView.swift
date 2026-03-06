import SwiftUI

/// Simple triangle shape for popover arrows.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

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
import AppKit

// MARK: - NSSearchField wrapper for title bar

/// Notification name used to programmatically focus the title bar search field (e.g. via ⌘K).
extension Notification.Name {
    static let focusTitleBarSearch = Notification.Name("focusTitleBarSearch")
}

/// A native macOS search field for embedding in the toolbar title bar area.
/// Uses NSViewRepresentable so the toolbar reliably renders it (unlike complex SwiftUI views).
struct TitleBarSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search Maho Notes"
    var onActivate: () -> Void = {}

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        // Expand to fill all available toolbar space
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        field.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // Listen for programmatic focus requests (⌘K)
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .focusTitleBarSearch, object: nil, queue: .main
        ) { _ in
            field.window?.makeFirstResponder(field)
        }

        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TitleBarSearchField
        var observer: NSObjectProtocol?
        init(_ parent: TitleBarSearchField) { self.parent = parent }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onActivate()
        }
    }
}

/// A+B+C three-zone layout with collapsible panels.
/// A: VaultRailView (48pt) | B: NavigatorView (240pt) | C: NoteContentView (flexible)
struct MacContentView: View {
    @Environment(AppState.self) private var appState
    @State private var debounceTask: Task<Void, Never>?
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        @Bindable var state = appState

        NavigationStack {
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
                            navigatorResizeHandle
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

            // Onboarding overlay for first-time users (no vaults)
            if appState.isLoaded && appState.vaults.isEmpty {
                onboardingOverlay
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

            // Centered search field in the title bar (Slack-style)
            ToolbarItem(placement: .principal) {
                TitleBarSearchField(
                    text: $state.searchQuery,
                    onActivate: {
                        if !appState.showSearchPanel {
                            appState.showSearchPanel = true
                        }
                    }
                )
                .frame(minWidth: 300, idealWidth: 500, maxWidth: 600)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
            }
        }
        } // NavigationStack
        .onChange(of: appState.searchQuery) {
            if !appState.searchQuery.isEmpty && !appState.showSearchPanel {
                appState.showSearchPanel = true
            }
            scheduleSearch()
        }
    }

    // MARK: - Search Overlay

    /// Floating search panel that drops down from the top center of the window.
    /// Reuses SearchPanelView which has scope/mode toggles and results list.
    private var searchOverlay: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — click to dismiss
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    appState.showSearchPanel = false
                }

            // Search panel dropdown — positioned below the title bar
            SearchPanelView()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .padding(.top, 4)
                .onTapGesture { /* absorb tap — prevent dismiss */ }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Onboarding Overlay

    /// First-launch overlay: dims the screen and shows a popover-style callout
    /// appearing to come from the highlighted "+" button in the vault rail.
    private var onboardingOverlay: some View {
        ZStack(alignment: .topLeading) {
            // Dimmed background
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            // Popover-style callout with left-pointing arrow
            HStack(alignment: .top, spacing: 0) {
                // Left arrow triangle pointing at the + button
                Triangle()
                    .fill(Color(.windowBackgroundColor))
                    .frame(width: 10, height: 18)
                    .rotationEffect(.degrees(-90))
                    .offset(y: 12)

                // Callout body
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Maho Notes!")
                        .font(.headline)

                    Text("Click the highlighted  ＋  button\nto create your first vault.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                )
            }
            // Position right of the vault rail, aligned with the + button
            .padding(.top, 44)
            .padding(.leading, 50)
        }
        .allowsHitTesting(false) // Let clicks through to the + button
        .transition(.opacity)
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

    // MARK: - Navigator Resize Handle

    private var navigatorResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 5)
            .background(Divider())
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = appState.navigatorWidth
                        }
                        let newWidth = (dragStartWidth ?? appState.navigatorWidth) + value.translation.width
                        appState.navigatorWidth = min(
                            AppState.navigatorWidthMax,
                            max(AppState.navigatorWidthMin, newWidth)
                        )
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
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
