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
            AdaptiveIOSContentView()
            #endif
        }
        .preferredColorScheme(colorScheme)
        .task {
            appState.loadRegistry()
        }
        .onChange(of: appState.selectedVaultName) {
            appState.loadSelectedVault()
        }
        .alert("Error", isPresented: Binding(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } }
        )) {
            Button("OK") { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
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
        field.controlSize = .small
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
    // Empty state action sheets
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionIcon = "folder"
    @State private var collectionError: String?
    @State private var showingNewNote = false
    @State private var newNoteTitle = ""
    @State private var newNoteCollectionId = ""
    @State private var noteError: String?

    var body: some View {
        @Bindable var state = appState
        @Bindable var search = appState.searchManager

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
                        .environment(\.emptyStateActions, EmptyStateActions(
                            onCreateCollection: appState.selectedVault?.access == .readOnly ? nil : {
                                newCollectionName = ""
                                newCollectionIcon = "folder"
                                collectionError = nil
                                showingNewCollection = true
                            },
                            onCreateNote: appState.selectedVault?.access == .readOnly ? nil : {
                                if let first = appState.collections.first {
                                    newNoteCollectionId = first.id
                                }
                                newNoteTitle = ""
                                noteError = nil
                                showingNewNote = true
                            }
                        ))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(.easeInOut(duration: 0.2), value: appState.showNavigator)
                .animation(.easeInOut(duration: 0.2), value: appState.showVaultRail)
                .onChange(of: geo.size.width) { _, newWidth in
                    handleAutoCollapse(width: newWidth)
                }
            }

            // First-launch iCloud adoption overlay
            if appState.isAdoptingICloud {
                iCloudAdoptionOverlay
            }

            // Reloading indicator — subtle overlay when registry refreshes from iCloud
            if appState.isReloading && !appState.isAdoptingICloud {
                VStack {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing vaults…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.top, 8)

                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.3), value: appState.isReloading)
            }

            // Search panel overlay — drops down from top center when active
            if appState.searchManager.showSearchPanel {
                searchOverlay
            }

            // Onboarding overlay for first-time users (no vaults)
            // Temporarily disabled — interferes with popover hit testing
            // if appState.isLoaded && appState.vaults.isEmpty {
            //     onboardingOverlay
            // }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.toggleNavigator()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .controlSize(.small)
                .help("Toggle Navigator (⌘⇧B)")
            }

            // Centered search field in the title bar (Slack-style)
            ToolbarItem(placement: .principal) {
                TitleBarSearchField(
                    text: $search.searchQuery,
                    onActivate: {
                        if !appState.searchManager.showSearchPanel {
                            appState.searchManager.showSearchPanel = true
                        }
                    }
                )
                .frame(minWidth: 300, idealWidth: 500, maxWidth: 600)
            }
        }
        } // NavigationStack
        .toolbarBackground(MahoTheme.vaultRailBackground, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .onChange(of: appState.searchManager.searchQuery) {
            if !appState.searchManager.searchQuery.isEmpty && !appState.searchManager.showSearchPanel {
                appState.searchManager.showSearchPanel = true
            }
            scheduleSearch()
        }
        .sheet(isPresented: $showingNewCollection) {
            macNewCollectionSheet
        }
        .sheet(isPresented: $showingNewNote) {
            macNewNoteSheet
        }
    }

    // MARK: - New Collection Sheet (from empty state)

    private var macNewCollectionSheet: some View {
        VStack(spacing: 16) {
            Text("New Collection")
                .font(.headline)

            TextField("Collection Name", text: $newCollectionName)
                .textFieldStyle(.roundedBorder)

            if let error = collectionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { showingNewCollection = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    do {
                        try appState.createCollection(name: name, icon: newCollectionIcon)
                        showingNewCollection = false
                    } catch {
                        collectionError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - New Note Sheet (from empty state)

    private var macNewNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New Note")
                .font(.headline)

            if appState.collections.count > 1 {
                Picker("Collection", selection: $newNoteCollectionId) {
                    ForEach(appState.collections, id: \.id) { col in
                        Text(col.name).tag(col.id)
                    }
                }
            }

            TextField("Note Title", text: $newNoteTitle)
                .textFieldStyle(.roundedBorder)

            if let error = noteError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { showingNewNote = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    let title = newNoteTitle.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    do {
                        let path = try appState.createNote(title: title, collectionId: newNoteCollectionId)
                        showingNewNote = false
                        appState.editorState.viewMode = .editor
                        appState.editorState.startEditing()
                    } catch {
                        noteError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newNoteTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    // MARK: - iCloud Adoption Overlay

    /// Full-screen welcome overlay shown during first-launch iCloud vault adoption.
    private var iCloudAdoptionOverlay: some View {
        ZStack {
            Color(.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                    .symbolEffect(.pulse, options: .repeating)

                Text("Syncing from iCloud…")
                    .font(.title2.bold())

                if appState.adoptedVaultCount > 0 {
                    Text("Found \(appState.adoptedVaultCount) vault\(appState.adoptedVaultCount == 1 ? "" : "s") from your other devices.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 8)

                Text("This usually takes a few seconds")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.5), value: appState.isAdoptingICloud)
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
                    appState.searchManager.showSearchPanel = false
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

            // Speech bubble: tail connects at the top-left corner of the box
            ZStack(alignment: .topLeading) {
                // Callout body (on top)
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
                .zIndex(1)

                // Triangle tail — center meets the box's top-left corner
                Triangle()
                    .fill(Color(.windowBackgroundColor))
                    .frame(width: 18, height: 14)
                    .rotationEffect(.degrees(-45))
                    .offset(x: -5, y: -3)
                    .zIndex(0)
            }
            // Position: B column area (vault rail ~48pt + some padding)
            .padding(.top, 48)
            .padding(.leading, 54)
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
            appState.searchManager.performSearch()
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

// MARK: - iOS Adaptive Layout

#if os(iOS)
/// Routes to iPad (NavigationSplitView) or iPhone (TabView) based on size class.
struct AdaptiveIOSContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            IPadContentView()
        } else {
            iPhoneContentView()
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(AppState())
}
