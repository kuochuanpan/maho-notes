import SwiftUI
import MahoNotesKit

/// A — Narrow vertical vault rail (~48pt wide) on the left edge.
struct VaultRailView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddAlert = false


    var body: some View {
        VStack(spacing: 0) {
            // Add button
            Button {
                showingAddAlert = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(
                        appState.vaults.isEmpty
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(appState.vaults.isEmpty ? .white : .primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .shadow(
                color: appState.vaults.isEmpty ? .accentColor.opacity(0.6) : .clear,
                radius: appState.vaults.isEmpty ? 8 : 0
            )

            Divider()
                .padding(.horizontal, 6)

            // Scrollable vault icons
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    vaultGroup(appState.icloudVaults)
                    if !appState.icloudVaults.isEmpty && !appState.githubVaults.isEmpty {
                        divider
                    }
                    vaultGroup(appState.githubVaults)
                    if (!appState.icloudVaults.isEmpty || !appState.githubVaults.isEmpty)
                        && !appState.localVaults.isEmpty {
                        divider
                    }
                    vaultGroup(appState.localVaults)
                }
                .padding(.vertical, 6)
            }

            Spacer()

            // Settings pinned at bottom
            Divider()
                .padding(.horizontal, 6)

            #if os(macOS)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.vertical, 8)
            #else
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .padding(.vertical, 8)
            #endif
        }
        .frame(width: 48)
        .background(.bar)
        .alert("Add Vault", isPresented: $showingAddAlert) {
            Button("OK") {}
        } message: {
            Text("Vault creation will be available in a future update.\nUse `mn init` from the CLI for now.")
        }
    }

    // MARK: - Vault Group

    @ViewBuilder
    private func vaultGroup(_ entries: [VaultEntry]) -> some View {
        ForEach(entries, id: \.name) { entry in
            vaultIcon(entry)
        }
    }

    private var divider: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    // MARK: - Vault Icon

    private func vaultIcon(_ entry: VaultEntry) -> some View {
        Button {
            appState.selectedVaultName = entry.name
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(String(entry.name.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(color(for: entry.name), in: RoundedRectangle(cornerRadius: 8))

                if entry.type == .icloud {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.black.opacity(0.5), in: Circle())
                        .offset(x: 2, y: 2)
                } else if entry.access == .readOnly {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(.black.opacity(0.5), in: Circle())
                        .offset(x: 2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if appState.selectedVaultName == entry.name {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.blue)
                    .frame(width: 3, height: 20)
                    .offset(x: -6)
            }
        }
        .contextMenu {
            vaultContextMenu(entry)
        }
    }

    // MARK: - Vault Context Menu

    @ViewBuilder
    private func vaultContextMenu(_ entry: VaultEntry) -> some View {
        if let name = appState.authorName {
            Text(name)
        } else {
            Text("No author set")
        }

        Text(entry.name)
            .foregroundStyle(.secondary)

        Divider()

        #if os(macOS)
        SettingsLink {
            Label("Vault Settings", systemImage: "gearshape")
        }
        #endif
    }

    // MARK: - Helpers

    private func color(for name: String) -> Color {
        let colors: [Color] = [
            .blue, .purple, .pink, .red, .orange,
            .yellow, .green, .teal, .cyan, .indigo,
        ]
        var hash = 0
        for char in name.unicodeScalars {
            hash = hash &* 31 &+ Int(char.value)
        }
        return colors[abs(hash) % colors.count]
    }
}
