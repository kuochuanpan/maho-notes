import Foundation
import Observation
import GitHubAPI
import MahoNotesKit

// TODO: Register a GitHub OAuth App at https://github.com/settings/developers
// and replace these placeholder values with your actual client ID and secret.
private let oauthClientId = "PLACEHOLDER_CLIENT_ID"
private let oauthClientSecret: String? = "PLACEHOLDER_CLIENT_SECRET"

/// Manages GitHub OAuth authentication state for the app.
///
/// Call `checkAuth()` on launch to restore a persisted token.
/// Call `authenticate()` to run the OAuth flow and store a new token.
/// Call `disconnect()` to clear the stored token.
@Observable
@MainActor
final class GitHubAuthManager {

    // MARK: - Observable State

    var isAuthenticated: Bool = false
    var username: String?
    var isAuthenticating: Bool = false
    var authError: String?

    // MARK: - Public API

    /// Check whether a valid stored token exists, and if so fetch the GitHub username.
    func checkAuth() async {
        // Resolve token off-actor — may run `gh auth token` subprocess on macOS.
        let token: String? = await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                continuation.resume(returning: try? Auth().resolveToken().token)
            }
        }

        guard let token else {
            isAuthenticated = false
            username = nil
            return
        }

        do {
            let name = try await fetchUsername(token: token)
            isAuthenticated = true
            username = name
        } catch {
            // Token exists but is invalid/expired — treat as not authenticated.
            isAuthenticated = false
            username = nil
        }
    }

    /// Run the GitHub OAuth flow. Stores the token and updates `isAuthenticated` / `username`.
    ///
    /// - Throws: `OAuthError` or network errors on failure. Does NOT throw if the user cancels.
    func authenticate() async throws {
        isAuthenticating = true
        authError = nil

        do {
            let config = OAuthConfiguration(
                clientId: oauthClientId,
                clientSecret: oauthClientSecret,
                redirectURI: "mahonotes://github-callback",
                scopes: ["repo"]
            )
            let flow = OAuthFlow(configuration: config)
            let tokenResponse = try await flow.authenticate()

            try Auth().storeToken(tokenResponse.accessToken)

            let name = try await fetchUsername(token: tokenResponse.accessToken)
            isAuthenticated = true
            username = name
            isAuthenticating = false
        } catch {
            isAuthenticating = false
            // User cancelled — not an error, just silently stop.
            if let oauthError = error as? OAuthError, case .cancelled = oauthError {
                return
            }
            authError = error.localizedDescription
            throw error
        }
    }

    /// Remove the stored token and reset auth state.
    func disconnect() {
        removeStoredToken()
        isAuthenticated = false
        username = nil
        authError = nil
    }

    // MARK: - Private

    /// Fetch the authenticated user's login name from GET /user.
    private func fetchUsername(token: String) async throws -> String {
        let url = URL(string: "https://api.github.com/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return login
    }

    /// Remove the `github_token` entry from `~/.maho/config.yaml` without a Yams dependency.
    ///
    /// Filters out any line whose trimmed content starts with `github_token:`. The surrounding
    /// `auth:` block stays (but becomes empty), which `Auth.resolveToken()` handles gracefully
    /// by returning `nil` when no token key is present.
    private func removeStoredToken() {
        let configPath = "\(Auth.globalConfigDir)/config.yaml"
        let fm = FileManager.default

        guard fm.fileExists(atPath: configPath),
              let data = fm.contents(atPath: configPath),
              let content = String(data: data, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n")
        let filtered = lines.filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("github_token:")
        }
        let output = filtered.joined(separator: "\n")
        try? output.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}
