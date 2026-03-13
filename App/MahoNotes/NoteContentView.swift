import SwiftUI
import MahoNotesKit
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

// MARK: - Environment Keys for iPad inline controls

private struct SidebarToggleActionKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

private struct InlineActionButtonsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    /// Optional sidebar toggle action injected by iPad layout.
    var sidebarToggleAction: (() -> Void)? {
        get { self[SidebarToggleActionKey.self] }
        set { self[SidebarToggleActionKey.self] = newValue }
    }
    /// Optional inline action buttons injected by iPad layout (replaces nav bar).
    var inlineActionButtons: AnyView? {
        get { self[InlineActionButtonsKey.self] }
        set { self[InlineActionButtonsKey.self] = newValue }
    }
}

/// C -- Note content panel showing the selected note's title and body.
struct NoteContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.sidebarToggleAction) private var sidebarToggleAction
    @Environment(\.inlineActionButtons) private var inlineActionButtons
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14
    @FocusState private var editorFocused: Bool
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var importError: String?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    var body: some View {
        if let note = appState.selectedNote {
            noteContent(note)
        } else {
            emptyState
        }
    }

    // MARK: - Note Content

    private func noteContent(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Conflict banner
            if let conflict = appState.conflict(for: note.relativePath) {
                conflictBanner(conflict)
            } else if let conflictFile = appState.githubConflictFile(for: note.relativePath) {
                githubConflictBanner(conflictFile)
            }

            // Breadcrumb header (+ optional iPad inline controls)
            HStack(spacing: 8) {
                if let toggleAction = sidebarToggleAction {
                    Button(action: toggleAction) {
                        Image(systemName: "sidebar.left")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    breadcrumb(for: note)
                    if appState.editorState.hasUnsavedChanges {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                    }
                }
                .font(.subheadline)
                Spacer()
                // Markdown formatting toolbar (macOS + iPad landscape only, not iPhone portrait)
                if appState.editorState.viewMode != .preview && !appState.editorState.isReadOnly && !isCompactWidth {
                    markdownToolbarButtons
                }
                // iPad/iPhone: no inline action buttons in note content view
                // (new note / sync / collection buttons removed from breadcrumb bar)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Content area with floating toolbar overlay
            ZStack(alignment: .bottomTrailing) {
                contentForMode(note)
                FloatingToolbarView()
            }
        }
        #if os(macOS)
        .onChange(of: showPhotoPicker) { _, show in
            guard show else { return }
            showPhotoPicker = false
            presentMacOSPhotoPicker(for: note)
        }
        .onChange(of: showFilePicker) { _, show in
            guard show else { return }
            showFilePicker = false
            presentMacOSFilePicker(for: note)
        }
        #else
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            selectedPhotoItem = nil
            Task { await importPhotoItem(item, for: note) }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result, for: note)
        }
        #endif
        .alert("Import Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Conflict Banner

    private func conflictBanner(_ conflict: iCloudSyncManager.ConflictInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("This note has a conflict version")
                .font(.subheadline)
            Spacer()
            Button("Keep Current") {
                appState.iCloudManager.resolveConflict(conflict, keeping: .keepCurrent)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let otherVersion = conflict.versions.first {
                Button("Keep Other Version") {
                    appState.iCloudManager.resolveConflict(conflict, keeping: .keepOther(otherVersion))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.1))
    }

    private func githubConflictBanner(_ conflictPath: String) -> some View {
        let filename = URL(fileURLWithPath: conflictPath).lastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Conflict detected — local version saved as \(filename)")
                .font(.subheadline)
            Spacer()
            Button("Open Conflict File") {
                appState.selectedNotePath = conflictPath
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    @ViewBuilder
    private func contentForMode(_ note: Note) -> some View {
        if isCloudOnly(note) {
            downloadingPlaceholder(note)
        } else {
            switch appState.editorState.viewMode {
            case .preview:
                MarkdownWebView(markdown: note.body, noteDirectoryURL: noteDirectoryURL(for: note))
            case .editor:
                editorView
                    .onAppear {
                        appState.editorState.startEditing()
                        editorFocused = true
                    }
            case .split:
                HStack(spacing: 0) {
                    editorView
                    Divider()
                    MarkdownWebView(markdown: appState.editorState.editingBody, noteDirectoryURL: noteDirectoryURL(for: note))
                }
                .onAppear {
                    appState.editorState.startEditing()
                    editorFocused = true
                }
            }
        }
    }

    // MARK: - Breadcrumb

    /// Build a breadcrumb from the note's relative path.
    /// Shows up to 3 path segments + title. If the path has more than 3 segments,
    /// the leading ones are collapsed into "…".
    private func breadcrumb(for note: Note) -> some View {
        let segments = note.relativePath
            .components(separatedBy: "/")
            .dropLast() // remove filename

        // Show at most 3 directory segments; collapse earlier ones into "…"
        let maxSegments = 3
        let display: [String]
        if segments.count > maxSegments {
            display = ["…"] + Array(segments.suffix(maxSegments))
        } else {
            display = Array(segments)
        }

        return HStack(spacing: 4) {
            ForEach(Array(display.enumerated()), id: \.offset) { _, segment in
                Text(segment)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(note.title)
        }
    }

    /// Compute the directory URL containing the note file (for resolving _assets/ paths).
    private func noteDirectoryURL(for note: Note) -> URL? {
        guard let entry = appState.selectedVault else { return nil }
        let vaultPath = appState.store.resolvedPath(for: entry)
        let noteDir = (note.relativePath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: vaultPath).appendingPathComponent(noteDir)
    }

    /// Check if the note's file is a cloud-only placeholder (not downloaded yet).
    private func isCloudOnly(_ note: Note) -> Bool {
        guard let entry = appState.selectedVault, entry.type == .icloud else { return false }
        let vaultPath = appState.store.resolvedPath(for: entry)
        let dir = URL(fileURLWithPath: vaultPath)
            .appendingPathComponent((note.relativePath as NSString).deletingLastPathComponent)
        let placeholder = dir.appendingPathComponent(".\(note.relativePath.components(separatedBy: "/").last ?? "").icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    private func downloadingPlaceholder(_ note: Note) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Downloading from iCloud...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard let entry = appState.selectedVault else { return }
            let vaultPath = appState.store.resolvedPath(for: entry)
            let fileURL = URL(fileURLWithPath: vaultPath).appendingPathComponent(note.relativePath)
            appState.iCloudManager.downloadFileIfNeeded(at: fileURL)
        }
    }

    private var editorView: some View {
        @Bindable var editor = appState.editorState
        return MarkdownEditorView(
            text: $editor.editingBody,
            fontSize: editorFontSize,
            onSelectionChange: { range in
                appState.editorState.selectedRange = range
            },
            pendingAction: $editor.pendingToolbarAction,
            pendingInsertion: $editor.pendingInsertion,
            onComplexAction: { action in
                handleToolbarAction(action)
            },
            showKeyboardAccessory: isCompactWidth
        )
        .task(id: appState.editorState.editingBody) {
            // Debounced auto-save: 2s after last keystroke
            // Guard: only save when in editor/split mode with non-empty buffer
            guard appState.editorState.viewMode != .preview else { return }
            guard !appState.editorState.editingBody.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled && appState.editorState.viewMode != .preview {
                appState.editorState.saveNote()
            }
        }
    }

    /// Whether we're in compact width (iPhone).
    private var isCompactWidth: Bool {
        #if os(macOS)
        false
        #else
        horizontalSizeClass == .compact
        #endif
    }

    // MARK: - Markdown Toolbar Buttons

    @ViewBuilder
    private var markdownToolbarButtons: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownToolbarAction.breadcrumbActions) { action in
                Button {
                    handleToolbarAction(action)
                } label: {
                    Image(systemName: action.icon)
                        .font(.system(size: 12))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                #if os(macOS)
                .help(action.label)
                #endif
            }
        }
        .controlSize(.small)
    }

    /// Route toolbar actions — pickers for photo/file, normal applyToolbarAction for the rest.
    private func handleToolbarAction(_ action: MarkdownToolbarAction) {
        switch action {
        case .insertPhoto:
            showPhotoPicker = true
        case .insertFile:
            showFilePicker = true
        default:
            appState.editorState.applyToolbarAction(action)
        }
    }

    // MARK: - Asset Import

    private static let imageTypes: [UTType] = [.png, .jpeg, .gif, .webP, .svg, .heic]

    /// Import a file URL into the note's _assets/ directory and insert markdown at cursor.
    private func importAssetAndInsert(from url: URL, for note: Note, isImage: Bool) {
        guard let entry = appState.selectedVault else {
            importError = "No vault selected"
            return
        }
        let vaultPath = appState.store.resolvedPath(for: entry)
        do {
            let assetPath = try AssetManager.importAsset(
                from: url,
                forNotePath: note.relativePath,
                vaultPath: vaultPath
            )
            let filename = (assetPath as NSString).lastPathComponent
            let name = (filename as NSString).deletingPathExtension
            let markdown: String
            if isImage {
                markdown = "![" + name + "|center|50%](" + assetPath + ")"
            } else {
                markdown = "[" + filename + "](" + assetPath + ")"
            }
            appState.editorState.pendingInsertion = markdown
        } catch {
            importError = "Failed to import asset: \(error.localizedDescription)"
        }
    }

    #if os(macOS)
    private func presentMacOSPhotoPicker(for note: Note) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.imageTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to insert"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            importAssetAndInsert(from: url, for: note, isImage: true)
        }
    }

    private func presentMacOSFilePicker(for note: Note) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a file to attach"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let isImage = Self.imageTypes.contains { type in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
            }
            importAssetAndInsert(from: url, for: note, isImage: isImage)
        }
    }
    #else
    private func importPhotoItem(_ item: PhotosPickerItem, for note: Note) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                importError = "Could not load image data"
                return
            }
            // Determine extension from content type
            let ext: String
            if let contentType = item.supportedContentTypes.first {
                ext = contentType.preferredFilenameExtension ?? "png"
            } else {
                ext = "png"
            }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try data.write(to: tempURL)
            importAssetAndInsert(from: tempURL, for: note, isImage: true)
            try? FileManager.default.removeItem(at: tempURL)
        } catch {
            importError = "Failed to load photo: \(error.localizedDescription)"
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>, for note: Note) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let isImage = Self.imageTypes.contains { type in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
            }
            importAssetAndInsert(from: url, for: note, isImage: isImage)
        case .failure(let error):
            importError = "Failed to import file: \(error.localizedDescription)"
        }
    }
    #endif

    // MARK: - Empty State

    private var emptyState: some View {
        DetailEmptyStateView()
    }
}
