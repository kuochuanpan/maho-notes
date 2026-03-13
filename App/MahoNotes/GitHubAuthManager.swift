import Foundation
import Observation
import GitHubAPI
import MahoNotesKit

// TODO: Replace with your GitHub OAuth App client ID.
// Create one at https://github.com/settings/developers → OAuth Apps → New
// Enable "Device Flow" in the app settings. No client secret needed.
private let oauthClientId = "Ov23libHvZdcws5ZS8rG"

/// Manages GitHub authentication state using the Device Flow.
///
/// Device Flow doesn't require a client secret, making it safe for App Store distribution.
/// The user authorizes by visiting `github.com/login/device` and entering a code.
///
/// Call `checkAuth()` on launch to restore a persisted token.
/// Call `authenticate()` to start the Device Flow.
/// Call `disconnect()` to clear the stored token.
@Observable
final class GitHubAuthManager: @unchecked Sendable {

    // MARK: - Observable State

    @MainActor var isAuthenticated: Bool = false
    @MainActor var username: String?
    @MainActor var isAuthenticating: Bool = false
    @MainActor var authError: String?

    /// The user code to display during Device Flow authorization.
    /// Non-nil only while `isAuthenticating` is true and waiting for user to authorize.
    @MainActor var userCode: String?

    /// The verification URL where the user enters the code.
    @MainActor var verificationURL: String?

    /// The single active auth task — ensures only one auth flow runs at a time.
    @MainActor private var authTask: Task<Void, Never>?

    nonisolated init() {}

    // MARK: - Public API

    /// Check whether a valid stored token exists, and if so fetch the GitHub username.
    /// Only checks stored tokens (config.yaml) — does NOT try `gh` CLI.
    /// This ensures the GitHub import option only appears after explicit in-app authentication.
    @MainActor
    func checkAuth() async {
        let token: String? = await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                continuation.resume(returning: try? Auth().resolveStoredToken().token)
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

    /// Called after successful authentication so dependents (e.g. SyncCoordinator)
    /// can reinitialize with the new token.
    @MainActor var onAuthenticated: (() -> Void)?

    /// Start the GitHub Device Flow.
    ///
    /// Cancels any previous auth flow, then:
    /// 1. Requests a device code from GitHub.
    /// 2. Sets `userCode` and `verificationURL` for the UI to display.
    /// 3. Polls in the background until the user authorizes (or code expires).
    /// 4. Stores the token and fetches the username on success.
    @MainActor
    func authenticate() async throws {
        // Cancel any existing auth flow entirely
        authTask?.cancel()
        authTask = nil

        isAuthenticating = true
        authError = nil
        userCode = nil
        verificationURL = nil

        let config = DeviceFlowConfiguration(
            clientId: oauthClientId,
            scopes: ["repo"]
        )
        let flow = DeviceFlow(configuration: config)

        // Run the entire auth flow in a single managed Task
        let task = Task { @MainActor in
            do {
                // Step 1: Request device code
                let codeResponse = try await flow.requestCode()
                try Task.checkCancellation()

                // Step 2: Show user code in UI
                userCode = codeResponse.userCode
                verificationURL = codeResponse.verificationUri

                // Step 3: Poll for token
                let tokenResponse = try await flow.pollForToken(deviceCode: codeResponse)
                try Task.checkCancellation()

                // Step 4: Store token and fetch username
                try Auth().storeToken(tokenResponse.accessToken)
                let name = try await fetchUsername(token: tokenResponse.accessToken)
                try Task.checkCancellation()

                isAuthenticated = true
                username = name
                isAuthenticating = false
                userCode = nil
                verificationURL = nil

                // Notify dependents (e.g. SyncCoordinator) that auth is ready
                onAuthenticated?()
            } catch {
                // Only update state if this task wasn't cancelled (superseded by a new one)
                guard !Task.isCancelled else { return }

                isAuthenticating = false
                userCode = nil
                verificationURL = nil

                if !(error is CancellationError) {
                    authError = error.localizedDescription
                }
            }
        }
        authTask = task

        // Wait for the task to complete (so callers can await)
        await task.value
    }

    /// Cancel any in-progress authentication.
    @MainActor
    func cancelAuth() {
        authTask?.cancel()
        authTask = nil
        isAuthenticating = false
        userCode = nil
        verificationURL = nil
    }

    /// Remove the stored token and reset auth state.
    @MainActor
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
