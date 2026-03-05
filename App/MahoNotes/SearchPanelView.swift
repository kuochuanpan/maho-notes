import SwiftUI
import MahoNotesKit
import Combine

/// Floating search panel triggered by ⌘K, overlaid on the content area.
struct SearchPanelView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var isFieldFocused: Bool
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !appState.searchQuery.isEmpty {
                Divider()
                resultsList
            } else {
                placeholder
            }
        }
        .frame(width: 500)
        .frame(maxHeight: 460)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .onAppear {
            isFieldFocused = true
        }
        .onKeyPress(.escape) {
            appState.toggleSearch()
            return .handled
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search across all notes...", text: Binding(
                get: { appState.searchQuery },
                set: { newValue in
                    appState.searchQuery = newValue
                    scheduleSearch()
                }
            ))
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .onSubmit {
                if let first = appState.searchResults.first {
                    appState.selectSearchResult(first)
                }
            }

            if !appState.searchQuery.isEmpty {
                Button {
                    appState.clearSearch()
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

    // MARK: - Results List

    private var resultsList: some View {
        Group {
            if appState.searchResults.isEmpty {
                noResults
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appState.searchResults, id: \.relativePath) { note in
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
            appState.selectSearchResult(note)
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
        .onHover { hovering in
            // Hover effect handled via background
        }
    }

    private var noResults: some View {
        Text("No results found")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(20)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        Text("Type to search across all notes")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(20)
    }

    // MARK: - Debounced Search

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            appState.performSearch()
        }
    }
}
