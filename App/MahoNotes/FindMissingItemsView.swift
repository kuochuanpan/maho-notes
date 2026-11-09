import SwiftUI
import MahoNotesKit

/// Lists vaults, collections and notes that are on this device but don't show up, and
/// fixes the ones the user keeps checked. Opened from the Vaults section of Settings.
struct FindMissingItemsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model = MissingItemsModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Find Missing Items")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fix Selected") {
                            Task { await model.fixSelected(appState: appState) }
                        }
                        .disabled(model.isWorking || model.selection.isEmpty)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 540)
        #endif
        .task { await model.scan() }
    }

    @ViewBuilder
    private var content: some View {
        if model.report == nil && model.failures.isEmpty {
            ProgressView("Scanning vaults…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.report?.isEmpty == true && model.failures.isEmpty {
            ContentUnavailableView {
                Label("Nothing Missing", systemImage: "checkmark.circle")
            } description: {
                Text("Every vault, collection and note on this device shows up in Maho Notes.")
            } actions: {
                Button("Scan Again") { Task { await model.scan() } }
                    .disabled(model.isWorking)
            }
        } else {
            results
                .disabled(model.isWorking)
                .overlay {
                    if model.isWorking {
                        ProgressView()
                    }
                }
        }
    }

    private var results: some View {
        List {
            if !model.failures.isEmpty {
                Section {
                    ForEach(model.failures, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }

            if let report = model.report {
                if !report.unregisteredVaults.isEmpty {
                    Section {
                        ForEach(report.unregisteredVaults) { found in
                            SelectableRow(isSelected: selection(MissingItemsModel.key(found)), isSelectable: true) {
                                FoundVaultLabel(
                                    found: found,
                                    willCopyToICloud: found.type == .device && appState.cloudSync.cloudSyncMode == .icloud)
                            }
                        }
                    } header: {
                        Text("Vaults Not in Your List")
                    } footer: {
                        Text("Checked vaults are added to your vault list.")
                    }
                }

                ForEach(report.vaults) { vaultReport in
                    Section(vaultReport.displayName ?? vaultReport.vaultName) {
                        ForEach(vaultReport.issues) { issue in
                            SelectableRow(
                                isSelected: selection(MissingItemsModel.key(vaultReport, issue)),
                                isSelectable: issue.isFixable
                            ) {
                                IssueLabel(issue: issue)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Scan Again") { Task { await model.scan() } }
            }
        }
    }

    private func selection(_ key: String) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(key) },
            set: { isOn in
                if isOn { model.selection.insert(key) } else { model.selection.remove(key) }
            }
        )
    }
}

// MARK: - Model

@MainActor @Observable
final class MissingItemsModel {
    private(set) var report: MissingItemsReport?
    private(set) var isWorking = false
    /// Messages for fixes that failed in the last run (or a failed scan).
    private(set) var failures: [String] = []
    /// Keys of the checked rows (see `key(_:)`).
    var selection: Set<String> = []

    static func key(_ found: FoundVault) -> String { "vault:\(found.path)" }
    static func key(_ report: VaultIssueReport, _ issue: VaultIssue) -> String { "\(report.vaultName)/\(issue.id)" }

    /// Scans all vaults and checks every row that has a fix.
    func scan() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try await VaultStore.shared.findMissingItems()
            self.report = report
            var keys = Set(report.unregisteredVaults.map(Self.key))
            for vaultReport in report.vaults {
                for issue in vaultReport.issues where issue.isFixable {
                    keys.insert(Self.key(vaultReport, issue))
                }
            }
            selection = keys
            failures = []
        } catch {
            report = nil
            failures = [error.localizedDescription]
        }
    }

    /// Adds the checked vaults, applies the checked fixes, reloads the app, then rescans.
    func fixSelected(appState: AppState) async {
        guard let report, !selection.isEmpty else { return }
        isWorking = true
        var failures: [String] = []

        let addedVaults = report.unregisteredVaults.filter { selection.contains(Self.key($0)) }
        for found in addedVaults {
            do {
                try await VaultStore.shared.addFoundVault(found)
            } catch {
                failures.append(String(localized: "Couldn't fix \(found.name): \(error.localizedDescription)"))
            }
        }

        let unsortedName = String(localized: "Unsorted")
        for vaultReport in report.vaults {
            let chosen = vaultReport.issues.filter { $0.isFixable && selection.contains(Self.key(vaultReport, $0)) }
            guard !chosen.isEmpty else { continue }
            let vault = Vault(path: vaultReport.vaultPath)
            // File work stays off the main actor; only Sendable messages come back
            failures += await Task.detached {
                vault.fix(chosen, unsortedCollectionName: unsortedName).map { failure in
                    String(localized: "Couldn't fix \(failure.issue.path): \(failure.error.localizedDescription)")
                }
            }.value
        }

        if addedVaults.isEmpty {
            appState.reloadCurrentVault()
        } else {
            await appState.loadRegistryAsync()
        }
        isWorking = false
        await scan()
        self.failures = failures
    }
}

// MARK: - Rows

/// A row with a checkbox (macOS) or a selection circle (iOS). Rows without a fix show
/// no control and can't be checked.
private struct SelectableRow<Content: View>: View {
    @Binding var isSelected: Bool
    let isSelectable: Bool
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        if isSelectable {
            Toggle(isOn: $isSelected) { content }
                .toggleStyle(.checkbox)
        } else {
            content.padding(.leading, 20)
        }
        #else
        Button {
            isSelected.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .opacity(isSelectable ? 1 : 0)
                content
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isSelectable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #endif
    }
}

private struct FoundVaultLabel: View {
    let found: FoundVault
    let willCopyToICloud: Bool

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: found.title ?? found.name)
                location
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(found.noteCount) note(s)")
                    if let date = found.lastModified {
                        Text("Last edited \(date.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if willCopyToICloud {
                    Text("Will be copied to iCloud")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    @ViewBuilder
    private var location: some View {
        switch found.type {
        case .icloud: Text("iCloud")
        case .github: Text("GitHub: \(found.github ?? "")")
        case .device, .local: Text("On This Device")
        }
    }

    private var icon: String {
        switch found.type {
        case .icloud: "icloud"
        case .github: "network"
        case .device, .local: "internaldrive"
        }
    }
}

private struct IssueLabel: View {
    let issue: VaultIssue

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                reason
                    .font(.caption)
                    .foregroundStyle(.secondary)
                fix
                    .font(.caption)
                    .foregroundStyle(issue.isFixable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private var isCollection: Bool {
        issue.kind == .unlistedCollection || issue.kind == .collectionFolderMissing
    }

    private var title: String {
        guard isCollection, let name = issue.detail, name != issue.path else { return issue.path }
        return "\(name) (\(issue.path))"
    }

    private var icon: String {
        switch issue.kind {
        case .unreadableConfig, .configNotDownloaded: "gearshape"
        case .unlistedCollection, .collectionFolderMissing: "folder"
        case .notDownloaded: "icloud.and.arrow.down"
        case .noteOutsideCollections, .nonStandardExtension, .notUTF8: "doc.text"
        }
    }

    private var reason: Text {
        switch issue.kind {
        case .unreadableConfig:
            Text("maho.yaml can't be read, so collections weren't checked: \(issue.detail ?? "")")
        case .configNotDownloaded:
            Text("maho.yaml hasn't downloaded from iCloud yet, so collections weren't checked.")
        case .unlistedCollection:
            Text("Not listed in maho.yaml, so it's shown last with a default icon.")
        case .collectionFolderMissing:
            Text("Listed in maho.yaml, but its folder is missing, so it isn't shown.")
        case .noteOutsideCollections:
            Text("Outside any collection, so it isn't shown.")
        case .nonStandardExtension:
            Text("Only .md files are shown.")
        case .notUTF8:
            Text("Not UTF-8 text, so it isn't shown.")
        case .notDownloaded:
            Text("Not downloaded from iCloud yet.")
        }
    }

    private var fix: Text {
        switch issue.kind {
        case .unreadableConfig:
            Text("Correct maho.yaml in a text editor, then scan again.")
        case .configNotDownloaded, .notDownloaded:
            Text("Fix: download it")
        case .unlistedCollection:
            Text("Fix: add it to maho.yaml")
        case .collectionFolderMissing:
            Text("Fix: create the folder")
        case .noteOutsideCollections:
            Text("Fix: move it to Unsorted")
        case .nonStandardExtension:
            Text("Fix: rename it to .md")
        case .notUTF8:
            issue.isFixable
                ? Text("Fix: convert it to UTF-8")
                : Text("Open it in a text editor and save it as UTF-8.")
        }
    }
}
