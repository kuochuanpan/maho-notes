import SwiftUI
import MahoNotesKit

/// Search dropdown panel shown below the title bar search field.
/// Includes scope toggle, mode toggle, and results list.
struct SearchPanelView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var isFieldFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            togglesSection
            Divider()

            if !appState.searchManager.searchQuery.isEmpty {
                resultsList
            } else {
                quickAccessSection
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search notes...", text: Binding(
                get: { appState.searchManager.searchQuery },
                set: { newValue in
                    appState.searchManager.searchQuery = newValue
                    scheduleSearch()
                }
            ))
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .onSubmit {
                if let first = appState.searchManager.searchResults.first {
                    appState.searchManager.selectSearchResult(first)
                }
            }

            if !appState.searchManager.searchQuery.isEmpty {
                Button {
                    appState.searchManager.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.title3)
        .padding(12)
    }

    // MARK: - Scope & Mode Toggles

    private var togglesSection: some View {
        VStack(spacing: 8) {
            // Scope toggle
            HStack {
                Text("SCOPE")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)
                Spacer()
                ThemePicker(
                    selection: Binding(
                        get: { appState.searchManager.searchScope },
                        set: { appState.searchManager.searchScope = $0; scheduleSearch() }
                    ),
                    options: [("allVaults", "All Vaults"), ("thisVault", "This Vault")]
                )
            }

            // Mode toggle
            HStack {
                Text("MODE")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)
                Spacer()
                ThemePicker(
                    selection: Binding(
                        get: { appState.searchManager.searchMode },
                        set: { appState.searchManager.searchMode = $0; scheduleSearch() }
                    ),
                    options: [("text", "Text"), ("semantic", "Semantic"), ("hybrid", "Hybrid")]
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    // MARK: - Results List

    private var resultsList: some View {
        Group {
            if let error = appState.searchManager.searchError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            } else if appState.searchManager.searchResults.isEmpty {
                noResults
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.searchManager.searchResults, id: \.relativePath) { note in
                            resultRow(note)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
    }

    private func resultRow(_ note: Note) -> some View {
        Button {
            appState.searchManager.selectSearchResult(note)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(note.collection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            Rectangle().fill(Color.primary.opacity(0.001))
        }
    }

    private var noResults: some View {
        Text("No results found")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(20)
    }

    // MARK: - Quick Access

    @ViewBuilder
    private var quickAccessSection: some View {
        if !appState.recentNotes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("QUICK ACCESS")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(appState.recentNotes.prefix(5), id: \.relativePath) { note in
                    Button {
                        appState.searchManager.selectSearchResult(note)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(note.title)
                                .lineLimit(1)
                            Spacer()
                            Text(note.collection)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Debounced Search

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            appState.searchManager.performSearch()
        }
    }
}

// MARK: - Theme-aware Segmented Picker

/// A custom segmented control that uses neutral colors matching the current theme
/// instead of the default system blue accent.
private struct ThemePicker: View {
    @Binding var selection: String
    let options: [(value: String, label: String)]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.caption)
                        .fontWeight(selection == option.value ? .semibold : .regular)
                        .foregroundStyle(selection == option.value ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == option.value ? selectedBackground : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06))
        )
    }

    private var selectedBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : Color.white.opacity(0.9)
    }
}
