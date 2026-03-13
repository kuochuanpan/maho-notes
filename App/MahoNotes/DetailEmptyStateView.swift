import SwiftUI
import MahoNotesKit

// MARK: - Empty State Actions (Environment)

/// Actions that parent views inject for the empty state buttons.
struct EmptyStateActions {
    var onCreateVault: (() -> Void)?
    var onImportVault: (() -> Void)?
    var onCreateCollection: (() -> Void)?
    var onCreateNote: (() -> Void)?
}

private struct EmptyStateActionsKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue = EmptyStateActions()
}

extension EnvironmentValues {
    /// Actions for the detail empty state onboarding flow.
    var emptyStateActions: EmptyStateActions {
        get { self[EmptyStateActionsKey.self] }
        set { self[EmptyStateActionsKey.self] = newValue }
    }
}

// MARK: - Detail Empty State View

/// Progressive empty state shown in the C (detail) column when no note is selected.
/// Adapts its message and call-to-action based on the current app state:
///   1. No vault → prompt to create or import one
///   2. Vault exists, no collections → prompt to create first collection
///   3. Collections exist, no notes → prompt to create first note
///   4. Notes exist → "Select a note" with optional New Note shortcut
struct DetailEmptyStateView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.emptyStateActions) private var actions
    @Environment(\.colorScheme) private var colorScheme

    private enum OnboardingStep {
        case noVault
        case noCollections
        case noNotes
        case ready
    }

    private var step: OnboardingStep {
        if appState.selectedVault == nil && appState.vaults.isEmpty {
            return .noVault
        }
        if appState.selectedVault == nil {
            // Vaults exist but none selected — unusual, treat as ready
            return .ready
        }
        if appState.collections.isEmpty {
            return .noCollections
        }
        if appState.allNotes.isEmpty {
            return .noNotes
        }
        return .ready
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(MahoTheme.accent(for: colorScheme).opacity(0.5))

            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            actionButtons
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content by Step

    private var iconName: String {
        switch step {
        case .noVault:       return "externaldrive.badge.plus"
        case .noCollections: return "folder.badge.plus"
        case .noNotes:       return "square.and.pencil"
        case .ready:         return "text.page"
        }
    }

    private var title: String {
        switch step {
        case .noVault:       return "Set Up Your Vault"
        case .noCollections: return "Create Your First Collection"
        case .noNotes:       return "Write Your First Note"
        case .ready:         return "Maho Notes"
        }
    }

    private var subtitle: String {
        switch step {
        case .noVault:
            return "A vault is where your notes live — a folder on your device or iCloud."
        case .noCollections:
            return "Collections organize your notes into groups. Create one to get started."
        case .noNotes:
            return "Notes are written in Markdown — simple, portable, and yours forever."
        case .ready:
            return "Select a note from the sidebar to start reading or editing."
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch step {
        case .noVault:
            VStack(spacing: 10) {
                if let onCreateVault = actions.onCreateVault {
                    Button(action: onCreateVault) {
                        Label("Create New Vault", systemImage: "plus.circle.fill")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MahoTheme.accent(for: colorScheme))
                    .controlSize(.large)
                }
                if let onImportVault = actions.onImportVault {
                    Button(action: onImportVault) {
                        Label("Import from GitHub", systemImage: "arrow.down.circle")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

        case .noCollections:
            if let onCreateCollection = actions.onCreateCollection {
                Button(action: onCreateCollection) {
                    Label("Create Collection", systemImage: "folder.badge.plus")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(MahoTheme.accent(for: colorScheme))
                .controlSize(.large)
            }

        case .noNotes:
            if let onCreateNote = actions.onCreateNote {
                Button(action: onCreateNote) {
                    Label("Create New Note", systemImage: "square.and.pencil")
                        .frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(MahoTheme.accent(for: colorScheme))
                .controlSize(.large)
            }

        case .ready:
            if let onCreateNote = actions.onCreateNote {
                Button(action: onCreateNote) {
                    Label("New Note", systemImage: "plus")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(appState.collections.isEmpty)
            }
        }
    }
}
