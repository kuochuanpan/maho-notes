import SwiftUI

/// Shared icon picker sheet for choosing SF Symbol icons.
/// Used by collection creation (new collection) and icon change.
struct IconPickerSheet: View {
    let title: String
    @Binding var selectedIcon: String
    let onSave: () -> Void
    let onCancel: () -> Void

    private let icons = [
        "folder", "book.closed", "doc.text", "star", "lightbulb",
        "terminal", "globe", "flask", "graduationcap", "heart",
        "music.note", "photo", "gamecontroller", "wrench.and.screwdriver",
        "sparkles", "atom", "leaf", "flame", "bolt",
        "cpu", "desktopcomputer", "antenna.radiowaves.left.and.right",
        "paintbrush", "scissors", "hammer", "gearshape",
        "map", "flag", "bookmark", "tag", "pin",
        "archivebox", "tray.full", "externaldrive",
    ]

    #if os(iOS)
    private let columns = Array(repeating: GridItem(.fixed(44)), count: 6)
    private let iconSize: CGFloat = 20
    private let cellSize: CGFloat = 40
    #else
    private let columns = Array(repeating: GridItem(.fixed(32)), count: 8)
    private let iconSize: CGFloat = 14
    private let cellSize: CGFloat = 28
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            iconGrid
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave() }
                    }
                }
        }
        .presentationDetents([.medium])
        #else
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
            iconGrid
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        #endif
    }

    private var iconGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(icons, id: \.self) { icon in
                Button {
                    selectedIcon = icon
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: iconSize))
                        .frame(width: cellSize, height: cellSize)
                        .background(
                            selectedIcon == icon
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(selectedIcon == icon ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}
