import Foundation
import GitHubAPI

extension GitHubSyncManager {

    /// Create a `GitHubSyncManager` from an `"owner/repo"` string and an auth token.
    ///
    /// Returns `nil` if `ownerRepo` is not in the expected `owner/repo` format.
    public static func make(
        ownerRepo: String,
        branch: String = "main",
        vaultPath: String,
        token: String
    ) -> GitHubSyncManager? {
        let parts = ownerRepo.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0])
        let repo = String(parts[1])
        // Disable ALL HTTP caching to avoid stale refs after push.
        // Even ephemeral sessions maintain an in-memory cache within the
        // session lifetime. Since push's refs.get() and pull's refs.get()
        // hit the same URL within one sync cycle, the in-memory cache
        // returns the stale pre-push HEAD, causing pull to download old
        // file content and overwrite the user's edits.
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config)
        let client = GitHubClient(token: token, session: session)
        return GitHubSyncManager(
            client: client,
            owner: owner,
            repo: repo,
            branch: branch,
            vaultPath: vaultPath
        )
    }
}
