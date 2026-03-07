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
        let client = GitHubClient(token: token)
        return GitHubSyncManager(
            client: client,
            owner: owner,
            repo: repo,
            branch: branch,
            vaultPath: vaultPath
        )
    }
}
