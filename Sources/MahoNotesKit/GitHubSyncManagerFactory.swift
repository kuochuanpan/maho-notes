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
        // Use an ephemeral URLSession (no HTTP cache) to avoid stale refs
        // after push. URLSession.shared caches GitHub API responses; when
        // pull() immediately follows push(), the cached refs.get response
        // returns the OLD commit SHA, causing pull to download stale files
        // and overwrite the just-saved local content.
        let session = URLSession(configuration: .ephemeral)
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
