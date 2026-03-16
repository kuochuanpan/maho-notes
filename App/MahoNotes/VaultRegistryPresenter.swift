import Foundation

/// Monitors the vault registry file for external changes (e.g., CLI modifications,
/// iCloud sync from another device).
///
/// When another process modifies `vaults.yaml`, this presenter triggers a reload in the app.
/// Supports monitoring both a local path and an iCloud path simultaneously.
final class VaultRegistryPresenter: NSObject, NSFilePresenter {

    var presentedItemURL: URL?
    var presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "dev.pcca.mahonotes.registry-presenter"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var onChange: (@Sendable () -> Void)?
    private var debounceItem: DispatchWorkItem?

    /// Secondary presenter for the iCloud registry path (when cloud sync is ON).
    private var iCloudPresenter: VaultRegistryFilePresenter?

    init(registryURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = registryURL
        self.onChange = onChange
        super.init()
    }

    func startMonitoring() {
        NSFileCoordinator.addFilePresenter(self)
    }

    /// Start monitoring an additional iCloud registry path.
    /// Call this when cloud sync is ON so the app detects registry changes
    /// pushed from other devices via iCloud.
    func startMonitoringICloudRegistry(at url: URL) {
        stopMonitoringICloudRegistry()
        let presenter = VaultRegistryFilePresenter(registryURL: url) { [weak self] in
            self?.debouncedOnChange()
        }
        iCloudPresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    /// Stop monitoring the iCloud registry path.
    func stopMonitoringICloudRegistry() {
        if let p = iCloudPresenter {
            NSFileCoordinator.removeFilePresenter(p)
            iCloudPresenter = nil
        }
    }

    func stopMonitoring() {
        NSFileCoordinator.removeFilePresenter(self)
        stopMonitoringICloudRegistry()
    }

    func presentedItemDidChange() {
        debouncedOnChange()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
    }

    private func debouncedOnChange() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    deinit {
        stopMonitoring()
    }
}

// MARK: - Secondary File Presenter for iCloud Registry

/// A lightweight NSFilePresenter for watching a single file (the iCloud registry).
/// Separate from VaultRegistryPresenter so each can be registered independently.
private final class VaultRegistryFilePresenter: NSObject, NSFilePresenter {

    var presentedItemURL: URL?
    var presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "dev.pcca.mahonotes.icloud-registry-presenter"
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var onChange: (() -> Void)?

    init(registryURL: URL, onChange: @escaping () -> Void) {
        self.presentedItemURL = registryURL
        self.onChange = onChange
        super.init()
    }

    func presentedItemDidChange() {
        onChange?()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
    }
}
