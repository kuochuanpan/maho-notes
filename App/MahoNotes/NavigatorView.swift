import SwiftUI
import MahoNotesKit

/// B — Tree navigator panel (~240pt) showing collections and recent notes.
struct NavigatorView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
        }
        .frame(width: appState.navigatorWidth)
        .background(.background)
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
            Button {
                appState.toggleNavigator()
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Navigator (⌘⇧B)")
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
                TreeNodeView(node: node, appState: appState)
            }
        } header: {
            Text("COLLECTIONS")
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

    // MARK: - Helpers

    private func vaultIcon(for vault: VaultEntry) -> String {
        switch vault.type {
        case .icloud: "icloud"
        case .github: "arrow.triangle.branch"
        case .local: "folder"
        }
    }
}

// MARK: - Recursive Tree Node View

/// Renders a single node in the file tree — directories expand/collapse, notes are selectable leaves.
/// Clicking anywhere on a directory row (not just the triangle) toggles expand/collapse.
private struct TreeNodeView: View {
    let node: FileTreeNode
    let appState: AppState
    @State private var isExpanded: Bool = false

    var body: some View {
        if node.isDirectory {
            directoryRow
        } else {
            noteLeafRow
        }
    }

    // MARK: - Directory

    @ViewBuilder
    private var directoryRow: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(node.children, id: \.id) { child in
                TreeNodeView(node: child, appState: appState)
            }
        } label: {
            Label(node.name, systemImage: node.icon)
                .contentShape(Rectangle())
                .onTapGesture {
                    isExpanded.toggle()
                }
        }
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
        .tag(node.note?.relativePath ?? node.id)
    }
}
