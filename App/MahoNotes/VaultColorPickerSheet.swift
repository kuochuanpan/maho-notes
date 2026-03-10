#if os(iOS)
import SwiftUI
import MahoNotesKit

/// Sheet for choosing a vault's color badge.
struct VaultColorPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let entry: VaultEntry?
    var onDismiss: (() -> Void)?
    @State private var selectedColor: Color?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Preview of current vault icon
                    if let entry {
                        ZStack {
                            Text(String((entry.displayName ?? entry.name).prefix(1)).uppercased())
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(
                                    selectedColor ?? MahoTheme.resolvedVaultColor(for: entry),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                        }
                        .padding(.top, 8)
                    }

                    Text("Choose a color for this vault")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 12), count: 6), spacing: 12) {
                        ForEach(MahoTheme.vaultColorOptions) { option in
                            Button {
                                selectedColor = option.color
                                if let entry {
                                    appState.setVaultColor(name: entry.name, color: option.name)
                                }
                                dismiss()
                            } label: {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(option.color)
                                    .frame(width: 48, height: 48)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                                    )
                                    .overlay {
                                        if entry?.color == option.name {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("Vault Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
