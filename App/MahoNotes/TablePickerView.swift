import SwiftUI

/// A grid picker for choosing table dimensions (rows × columns).
/// Users hover (macOS) or tap/drag (iOS) to select, then insert.
struct TablePickerView: View {
    let onInsert: (Int, Int) -> Void
    let onCancel: () -> Void

    private let maxColumns = 8
    private let maxRows = 8
    private let cellSize: CGFloat = 24
    private let cellSpacing: CGFloat = 4

    @State private var selectedColumns = 0
    @State private var selectedRows = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Insert Table")
                .font(.headline)

            // Dimension label
            if selectedColumns > 0 && selectedRows > 0 {
                Text("\(selectedColumns) \u{00D7} \(selectedRows)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("Select dimensions")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            // Grid
            gridView

            // Buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Insert") {
                    guard selectedColumns > 0 && selectedRows > 0 else { return }
                    onInsert(selectedRows, selectedColumns)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedColumns == 0 || selectedRows == 0)
            }
        }
        .padding()
        .frame(width: CGFloat(maxColumns) * (cellSize + cellSpacing) + cellSpacing + 32)
    }

    private var gridView: some View {
        let totalWidth = CGFloat(maxColumns) * (cellSize + cellSpacing) - cellSpacing
        let totalHeight = CGFloat(maxRows) * (cellSize + cellSpacing) - cellSpacing

        return VStack(spacing: cellSpacing) {
            ForEach(1...maxRows, id: \.self) { row in
                HStack(spacing: cellSpacing) {
                    ForEach(1...maxColumns, id: \.self) { col in
                        let isSelected = col <= selectedColumns && row <= selectedRows
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .frame(width: totalWidth, height: totalHeight)
        .contentShape(Rectangle())
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                updateSelection(at: location, totalWidth: totalWidth, totalHeight: totalHeight)
            case .ended:
                break
            }
        }
        .onTapGesture { location in
            updateSelection(at: location, totalWidth: totalWidth, totalHeight: totalHeight)
            if selectedColumns > 0 && selectedRows > 0 {
                onInsert(selectedRows, selectedColumns)
            }
        }
        #else
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updateSelection(at: value.location, totalWidth: totalWidth, totalHeight: totalHeight)
                }
                .onEnded { value in
                    updateSelection(at: value.location, totalWidth: totalWidth, totalHeight: totalHeight)
                    if selectedColumns > 0 && selectedRows > 0 {
                        onInsert(selectedRows, selectedColumns)
                    }
                }
        )
        #endif
    }

    private func updateSelection(at location: CGPoint, totalWidth: CGFloat, totalHeight: CGFloat) {
        let col = max(1, min(maxColumns, Int(ceil(location.x / (cellSize + cellSpacing)))))
        let row = max(1, min(maxRows, Int(ceil(location.y / (cellSize + cellSpacing)))))
        selectedColumns = col
        selectedRows = row
    }
}
