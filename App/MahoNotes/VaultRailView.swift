import SwiftUI
import MahoNotesKit

/// A — Narrow vertical vault rail (~48pt wide) on the left edge.
struct VaultRailView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddSheet = false
    @State private var showingRenameDialog = false
    @State private var renameTarget: VaultEntry?
    @State private var renameText = ""
    @State private var showingColorPicker = false
    @State private var colorPickerTarget: VaultEntry?

    var body: some View {
        VStack(spacing: 0) {
            // Add button
            Button {
                showingAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(
                        appState.vaults.isEmpty
                            ? AnyShapeStyle(MahoTheme.vaultRailBackground.mix(with: .white, by: 0.3))
                            : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .foregroundStyle(appState.vaults.isEmpty ? .white : .primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .shadow(
                color: appState.vaults.isEmpty ? MahoTheme.vaultRailBackground.mix(with: .white, by: 0.3).opacity(0.6) : .clear,
                radius: appState.vaults.isEmpty ? 8 : 0
            )
            .sheet(isPresented: $showingAddSheet) {
                MacAddVaultSheet()
            }

            Divider()
                .overlay(Color.white.opacity(0.2))
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
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 6)

            #if os(macOS)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.vertical, 8)
            #else
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28, height: 28)
                .padding(.vertical, 8)
            #endif
        }
        .frame(width: 48)
        .background(MahoTheme.vaultRailBackground)
        .alert("Rename Vault", isPresented: $showingRenameDialog) {
            TextField("Display name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let target = renameTarget {
                    appState.renameVaultDisplay(name: target.name, displayName: renameText)
                }
            }
        } message: {
            Text("Enter a display name for this vault.")
        }
        .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) {
            colorPickerPanel
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
            .overlay(Color.white.opacity(0.2))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }

    // MARK: - Vault Icon

    private func vaultIcon(_ entry: VaultEntry) -> some View {
        Button {
            appState.selectedVaultName = entry.name
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(String((entry.displayName ?? entry.name).prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(MahoTheme.resolvedVaultColor(for: entry), in: RoundedRectangle(cornerRadius: 8))

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

        Text(entry.displayName ?? entry.name)
            .foregroundStyle(.secondary)

        Divider()

        Button {
            renameTarget = entry
            renameText = entry.displayName ?? ""
            showingRenameDialog = true
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            colorPickerTarget = entry
            showingColorPicker = true
        } label: {
            Label("Change Color", systemImage: "paintpalette")
        }

        Divider()

        #if os(macOS)
        SettingsLink {
            Label("Vault Settings", systemImage: "gearshape")
        }
        #endif
    }

    // MARK: - Color Picker Panel

    private var colorPickerPanel: some View {
        VStack(spacing: 8) {
            Text("Vault Color")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 6), spacing: 6) {
                ForEach(MahoTheme.vaultColorOptions) { option in
                    Button {
                        if let target = colorPickerTarget {
                            appState.setVaultColor(name: target.name, color: option.name)
                        }
                        showingColorPicker = false
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(option.color)
                            .frame(width: 28, height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                            )
                            .overlay {
                                if colorPickerTarget?.color == option.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

}
