#if os(iOS)
import SwiftUI
import MahoNotesKit

/// Form-based settings for iOS (replaces macOS Settings window).
struct iOSSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14
    @State private var vaultToRemove: String?

    var body: some View {
        NavigationStack {
            Form {
                // Vaults
                Section("Vaults") {
                    ForEach(appState.vaults, id: \.name) { entry in
                        vaultRow(entry)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Use `mn vault add` from the CLI to add vaults.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Appearance
                Section("Appearance") {
                    Picker("Theme", selection: $appTheme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Editor Font Size")
                            Spacer()
                            Text("\(Int(editorFontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $editorFontSize, in: 12...20, step: 1)
                    }
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    Link("GitHub", destination: URL(string: "https://github.com/kuochuanpan/maho-notes")!)
                    Link("Documentation", destination: URL(string: "https://github.com/kuochuanpan/maho-notes/blob/main/docs/DESIGN.md")!)
                }
            }
            .navigationTitle("Settings")
            .alert("Remove Vault", isPresented: Binding(
                get: { vaultToRemove != nil },
                set: { if !$0 { vaultToRemove = nil } }
            )) {
                Button("Cancel", role: .cancel) { vaultToRemove = nil }
                Button("Remove", role: .destructive) {
                    if let name = vaultToRemove {
                        appState.removeVault(name: name)
                    }
                    vaultToRemove = nil
                }
            } message: {
                Text("Remove \"\(vaultToRemove ?? "")\" from the registry? Files on disk will not be deleted.")
            }
        }
    }

    private func vaultRow(_ entry: VaultEntry) -> some View {
        HStack {
            Image(systemName: typeIcon(entry.type))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .fontWeight(.medium)
                    if appState.primaryVaultName == entry.name {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if entry.access == .readOnly {
                        Text("read-only")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }

            Spacer()

            if appState.primaryVaultName != entry.name {
                Button("Set Primary") {
                    appState.setPrimaryVault(name: entry.name)
                }
                .controlSize(.small)
            }

            Button(role: .destructive) {
                vaultToRemove = entry.name
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(appState.vaults.count <= 1)
        }
    }

    private func typeIcon(_ type: VaultType) -> String {
        switch type {
        case .icloud: return "icloud"
        case .github: return "network"
        case .local: return "folder"
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
#endif
