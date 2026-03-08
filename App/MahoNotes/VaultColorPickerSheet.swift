#if os(iOS)
import SwiftUI
import MahoNotesKit

/// Sheet for choosing a vault's color badge.
struct VaultColorPickerSheet: View {
    @Environment(AppState.self) private var appState
    let entry: VaultEntry?
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Choose a color for this vault")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 10), count: 6), spacing: 10) {
                    ForEach(MahoTheme.vaultColorOptions) { option in
                        Button {
                            if let entry {
                                appState.setVaultColor(name: entry.name, color: option.name)
                            }
                            isPresented = false
                        } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(option.color)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                                )
                                .overlay {
                                    if entry?.color == option.name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Vault Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
