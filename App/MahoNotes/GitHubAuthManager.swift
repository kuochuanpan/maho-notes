import Foundation
import Observation
import GitHubAPI
import MahoNotesKit

// TODO: Replace with your GitHub OAuth App client ID.
// Create one at https://github.com/settings/developers → OAuth Apps → New
// Enable "Device Flow" in the app settings. No client secret needed.
private let oauthClientId = "PLACEHOLDER_CLIENT_ID"

/// Manages GitHub authentication state using the Device Flow.
///
/// Device Flow doesn't require a client secret, making it safe for App Store distribution.
/// The user authorizes by visiting `github.com/login/device` and entering a code.
///
/// Call `checkAuth()` on launch to restore a persisted token.
/// Call `authenticate()` to start the Device Flow.
/// Call `disconnect()` to clear the stored token.
@Observable
@MainActor
final class GitHubAuthManager {

    // MARK: - Observable State

    var isAuthenticated: Bool = false
    var username: String?
    var isAuthenticating: Bool = false
    var authError: String?

    /// The user code to display during Device Flow authorization.
    /// Non-nil only while `isAuthenticating` is true and waiting for user to authorize.
    var userCode: String?

    /// The verification URL where the user enters the code.
    var verificationURL: String?

    /// Active polling task (so we can cancel on disconnect or re-auth).
    private var pollingTask: Task<Void, Never>?

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

    /// Start the GitHub Device Flow.
    ///
    /// 1. Requests a device code from GitHub.
    /// 2. Sets `userCode` and `verificationURL` for the UI to display.
    /// 3. Polls in the background until the user authorizes (or code expires).
    /// 4. Stores the token and fetches the username on success.
    ///
    /// - Throws: `OAuthError` or network errors on failure.
    func authenticate() async throws {
        // Cancel any existing polling
        pollingTask?.cancel()
        pollingTask = nil

        isAuthenticating = true
        authError = nil
        userCode = nil
        verificationURL = nil

        let config = DeviceFlowConfiguration(
            clientId: oauthClientId,
            scopes: ["repo"]
        )
        let flow = DeviceFlow(configuration: config)

        do {
            // Step 1: Request device code
            let codeResponse = try await flow.requestCode()

            // Step 2: Show user code in UI
            userCode = codeResponse.userCode
            verificationURL = codeResponse.verificationUri

            // Step 3: Poll for token in background
            let tokenResponse = try await flow.pollForToken(deviceCode: codeResponse)

            // Step 4: Store token and fetch username
            try Auth().storeToken(tokenResponse.accessToken)
            let name = try await fetchUsername(token: tokenResponse.accessToken)

            isAuthenticated = true
            username = name
            isAuthenticating = false
            userCode = nil
            verificationURL = nil
        } catch {
            isAuthenticating = false
            userCode = nil
            verificationURL = nil

            if error is CancellationError {
                return
            }
            authError = error.localizedDescription
            throw error
        }
    }

    /// Cancel any in-progress authentication.
    func cancelAuth() {
        pollingTask?.cancel()
        pollingTask = nil
        isAuthenticating = false
        userCode = nil
        verificationURL = nil
    }

    /// Remove the stored token and reset auth state.
    func disconnect() {
        cancelAuth()
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
