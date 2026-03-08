import Foundation

/// Monitors the vault registry file for external changes (e.g., CLI modifications).
/// When another process modifies `vaults.yaml`, this presenter triggers a reload in the app.
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

    init(registryURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = registryURL
        self.onChange = onChange
        super.init()
    }

    func startMonitoring() {
        NSFileCoordinator.addFilePresenter(self)
    }

    func stopMonitoring() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedItemDidChange() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
    }

    deinit {
        stopMonitoring()
    }
}
