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
        .frame(width: 240)
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
            set: { appState.selectedNotePath = $0 }
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
            ForEach(appState.collections, id: \.id) { collection in
                DisclosureGroup {
                    ForEach(appState.notes(for: collection.id), id: \.relativePath) { note in
                        noteRow(note)
                            .tag(note.relativePath)
                    }
                } label: {
                    Label(collection.name, systemImage: collection.icon)
                }
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
            Text(note.title)
                .lineLimit(1)
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
