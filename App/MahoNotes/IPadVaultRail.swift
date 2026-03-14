#if os(iOS)
import SwiftUI
import MahoNotesKit

/// A-column vault rail for iPad 3-column layout.
/// Displays vault icons vertically with add/settings buttons.
struct IPadVaultRail: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool
    @State private var showingAddVault = false
    @State private var showingRenameDialog = false
    @State private var renameTarget: VaultEntry?
    @State private var renameText = ""
    @State private var colorPickerTarget: VaultEntry?

    var body: some View {
        VStack(spacing: 0) {
            // Add button
            Button {
                showingAddVault = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(
                        appState.vaults.isEmpty
                            ? AnyShapeStyle(MahoTheme.vaultRailBackground.mix(with: .white, by: 0.3))
                            : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .foregroundStyle(appState.vaults.isEmpty ? .white : .primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider()
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 8)

            // Scrollable vault icons
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    vaultGroup(appState.icloudVaults)
                    if !appState.icloudVaults.isEmpty && !appState.githubVaults.isEmpty {
                        railDivider
                    }
                    vaultGroup(appState.githubVaults)
                    if (!appState.icloudVaults.isEmpty || !appState.githubVaults.isEmpty)
                        && !appState.localVaults.isEmpty {
                        railDivider
                    }
                    vaultGroup(appState.localVaults)
                }
                .padding(.vertical, 8)
            }

            Spacer()

            // Settings gear at bottom
            Divider()
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 8)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .frame(width: 68)
        .background(MahoTheme.vaultRailBackground)
        .sheet(isPresented: $showingAddVault) {
            IPadAddVaultSheet(isPresented: $showingAddVault)
        }
        .sheet(isPresented: Binding(
            get: { appState.authManager.showDeviceFlowSheet },
            set: { newValue in
                if !newValue {
                    appState.authManager.showDeviceFlowSheet = false
                }
            }
        )) {
            DeviceFlowSheet(authManager: appState.authManager)
                .interactiveDismissDisabled(appState.authManager.isAuthenticating)
        }
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
        .sheet(item: $colorPickerTarget) { target in
            VaultColorPickerSheet(
                entry: target,
                onDismiss: { colorPickerTarget = nil }
            )
        }
    }

    // MARK: - Vault Group

    @ViewBuilder
    private func vaultGroup(_ entries: [VaultEntry]) -> some View {
        ForEach(entries, id: \.name) { entry in
            vaultIcon(entry)
                .id("\(entry.name):\(entry.color ?? "")")
        }
    }

    private var railDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.2))
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
    }

    // MARK: - Vault Icon

    private func vaultIcon(_ entry: VaultEntry) -> some View {
        Button {
            appState.selectedVaultName = entry.name
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Text(String((entry.displayName ?? entry.name).prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(MahoTheme.resolvedVaultColor(for: entry), in: RoundedRectangle(cornerRadius: 10))

                if entry.type == .icloud {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 8))
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
                    .frame(width: 3, height: 24)
                    .offset(x: -8)
            }
        }
        .contextMenu {
            vaultContextMenu(entry)
        }
    }

    // MARK: - Vault Context Menu

    @ViewBuilder
    private func vaultContextMenu(_ entry: VaultEntry) -> some View {
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
        } label: {
            Label("Change Color", systemImage: "paintpalette")
        }

        if appState.primaryVaultName != entry.name {
            Button {
                appState.setPrimaryVault(name: entry.name)
            } label: {
                Label("Set as Primary", systemImage: "star")
            }
        }
    }
}
#endif
