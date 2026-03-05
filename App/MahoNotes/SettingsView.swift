import SwiftUI
import MahoNotesKit

#if os(macOS)
struct SettingsView: View {
    var body: some View {
        TabView {
            VaultsSettingsTab()
                .tabItem {
                    Label("Vaults", systemImage: "externaldrive")
                }

            AppearanceSettingsTab()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 340)
    }
}
#endif

// MARK: - Vaults Tab

struct VaultsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var vaultToRemove: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(appState.vaults, id: \.name) { entry in
                    vaultRow(entry)
                }
            }
            #if os(macOS)
            .listStyle(.inset(alternatesRowBackgrounds: true))
            #endif

            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Use `mn vault add` from the CLI to add vaults.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding()
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

    private func vaultRow(_ entry: VaultEntry) -> some View {
        HStack {
            Image(systemName: typeIcon(entry.type))
                .foregroundStyle(.secondary)
                .frame(width: 20)

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
                Text(noteCountLabel(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func noteCountLabel(for entry: VaultEntry) -> String {
        let vaultPath = resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)
        let count = (try? vault.allNotes().count) ?? 0
        return "\(count) note\(count == 1 ? "" : "s")"
    }
}

// MARK: - Appearance Tab

struct AppearanceSettingsTab: View {
    @AppStorage("appTheme") private var appTheme: String = "system"
    @AppStorage("editorFontSize") private var editorFontSize: Double = 14

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About Tab

struct AboutSettingsTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Maho Notes")
                .font(.title2.bold())

            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .frame(width: 200)

            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/kuochuanpan/maho-notes")!)
                Link("Documentation", destination: URL(string: "https://github.com/kuochuanpan/maho-notes/blob/main/docs/DESIGN.md")!)
            }
            .font(.callout)

            Text("Made with \u{2615} by Kuo-Chuan & Maho \u{1F52D}")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
