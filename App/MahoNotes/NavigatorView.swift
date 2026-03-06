import SwiftUI
import MahoNotesKit

/// B — Tree navigator panel (~240pt) showing collections and recent notes.
struct NavigatorView: View {
    @Environment(AppState.self) private var appState
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionIcon = "folder"
    @State private var collectionError: String?
    @State private var showingNewNote = false
    @State private var newNoteTitle = ""
    @State private var newNoteCollectionId = ""
    @State private var noteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: appState.navigatorWidth)
        .background(.background)
        .sheet(isPresented: $showingNewCollection) {
            newCollectionSheet
        }
        .sheet(isPresented: $showingNewNote) {
            newNoteSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let vault = appState.selectedVault {
                Image(systemName: vaultIcon(for: vault))
                    .foregroundStyle(.secondary)
                Text(vault.name)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("No Vault")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var list: some View {
        List(selection: Binding(
            get: { appState.selectedNotePath },
            set: { appState.selectNote(path: $0) }
        )) {
            collectionsSection
            recentSection
        }
        .listStyle(.sidebar)
    }

    // MARK: - Collections Section

    @ViewBuilder
    private var collectionsSection: some View {
        Section {
            ForEach(appState.fileTree, id: \.id) { node in
                TreeNodeView(
                    node: node,
                    appState: appState,
                    onNewNote: { collectionId in
                        newNoteCollectionId = collectionId
                        newNoteTitle = ""
                        noteError = nil
                        showingNewNote = true
                    }
                )
            }
        } header: {
            HStack {
                Text("COLLECTIONS")
                Spacer()
                Button {
                    newCollectionName = ""
                    newCollectionIcon = "folder"
                    collectionError = nil
                    showingNewCollection = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Collection")
                .padding(.trailing, 4)
            }
        }
    }

    // MARK: - Recent Section

    @ViewBuilder
    private var recentSection: some View {
        if !appState.recentNotes.isEmpty {
            Section {
                ForEach(appState.recentNotes, id: \.relativePath) { note in
                    noteRow(note)
                        .tag(note.relativePath)
                }
            } header: {
                Text("RECENT")
            }
        }
    }

    // MARK: - Note Row

    private func noteRow(_ note: Note) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(note.title)
                    .lineLimit(1)
                if appState.conflict(for: note.relativePath) != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - New Collection Sheet

    private var newCollectionSheet: some View {
        VStack(spacing: 16) {
            Text("New Collection")
                .font(.headline)

            TextField("Collection Name", text: $newCollectionName)
                .textFieldStyle(.roundedBorder)

            iconPicker

            if let error = collectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showingNewCollection = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createCollection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private var iconPicker: some View {
        let icons = [
            "folder", "book.closed", "doc.text", "star", "lightbulb",
            "terminal", "globe", "flask", "graduationcap", "heart",
            "music.note", "photo", "gamecontroller", "wrench.and.screwdriver",
            "sparkles", "atom",
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 8), spacing: 6) {
                ForEach(icons, id: \.self) { icon in
                    Button {
                        newCollectionIcon = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                            .background(
                                newCollectionIcon == icon
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .foregroundStyle(newCollectionIcon == icon ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            try appState.createCollection(name: name, icon: newCollectionIcon)
            showingNewCollection = false
        } catch {
            collectionError = error.localizedDescription
        }
    }

    // MARK: - New Note Sheet

    private var newNoteSheet: some View {
        VStack(spacing: 16) {
            Text("New Note")
                .font(.headline)

            Text("in \(newNoteCollectionId)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Note Title", text: $newNoteTitle)
                .textFieldStyle(.roundedBorder)

            if let error = noteError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showingNewNote = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createNote()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newNoteTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func createNote() {
        let title = newNoteTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        do {
            try appState.createNote(title: title, collectionId: newNoteCollectionId)
            showingNewNote = false
        } catch {
            noteError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func vaultIcon(for vault: VaultEntry) -> String {
        switch vault.type {
        case .icloud: "icloud"
        case .github: "arrow.triangle.branch"
        case .local: "folder"
        case .device: "internaldrive"
        }
    }
}

// MARK: - Recursive Tree Node View

/// Renders a single node in the file tree — directories expand/collapse, notes are selectable leaves.
/// Uses a manual chevron + conditional children instead of DisclosureGroup to avoid
/// macOS sidebar List conflicts with the native disclosure triangle state.
private struct TreeNodeView: View {
    let node: FileTreeNode
    let appState: AppState
    var onNewNote: ((String) -> Void)?
    @State private var isExpanded: Bool = false

    var body: some View {
        if node.isDirectory {
            directoryRow
                .contextMenu {
                    Button {
                        onNewNote?(node.id)
                    } label: {
                        Label("New Note", systemImage: "doc.badge.plus")
                    }
                }
            if isExpanded {
                ForEach(node.children, id: \.id) { child in
                    TreeNodeView(node: child, appState: appState, onNewNote: onNewNote)
                        .padding(.leading, 12)
                }
            }
        } else {
            noteLeafRow
        }
    }

    // MARK: - Directory

    private var directoryRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
                    .frame(width: 12)

                Image(systemName: node.icon)
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Note Leaf

    private var noteLeafRow: some View {
        Label {
            HStack(spacing: 4) {
                Text(node.name)
                    .lineLimit(1)
                if let note = node.note,
                   appState.conflict(for: note.relativePath) != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        } icon: {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 16)
        .tag(node.note?.relativePath ?? node.id)
    }
}
