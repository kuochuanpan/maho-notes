import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Auth")
struct AuthTests {
    private func makeTestVault() throws -> (String, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-auth-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Create minimal vault structure
        let yaml = """
        author:
          name: Test
        github:
          repo: test/repo
        """
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let mahoDir = tmp.appendingPathComponent(".maho")
        try fm.createDirectory(at: mahoDir, withIntermediateDirectories: true)

        return (tmp.path, tmp)
    }

    // MARK: - Token Resolution

    @Test func resolveTokenFindsAnySource() throws {
        // On a dev machine, at least one source (env, gh, stored) should be available
        // This test verifies the resolution chain works without crashing
        let (vaultPath, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = Auth(vaultPath: vaultPath)
        // Store a token so there's definitely one available
        try auth.storeToken("ghp_test1234567890abcdef")

        let token = try auth.resolveToken()
        #expect(!token.token.isEmpty)
    }

    @Test func storedTokenCanBeRetrieved() throws {
        let (vaultPath, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = Auth(vaultPath: vaultPath)
        try auth.storeToken("ghp_stored_only_test_123")

        // Verify the stored token is persisted in device config
        let config = Config(vaultPath: vaultPath)
        let deviceConfig = try config.loadDeviceConfig()
        let authSection = deviceConfig["auth"] as? [String: Any]
        #expect(authSection?["github_token"] as? String == "ghp_stored_only_test_123")
    }

    @Test func maskedTokenDisplay() throws {
        let token = AuthToken(token: "ghp_abcdefghijklmnop1234", source: .environment)
        let masked = token.masked
        // Should show first 8 + ... + last 4
        #expect(masked.hasPrefix("ghp_abcd"))
        #expect(masked.hasSuffix("1234"))
        #expect(masked.contains("..."))
    }

    @Test func maskedShortToken() throws {
        let token = AuthToken(token: "short", source: .environment)
        // Short tokens get fully masked
        #expect(token.masked == "*****")
    }

    @Test func tokenSourceEnvVar() throws {
        let token = AuthToken(token: "test", source: .environment)
        #expect(token.source.rawValue == "GITHUB_TOKEN environment variable")
    }

    @Test func tokenSourceGhCLI() throws {
        let token = AuthToken(token: "test", source: .ghCLI)
        #expect(token.source.rawValue == "gh auth token")
    }

    @Test func tokenSourceStored() throws {
        let token = AuthToken(token: "test", source: .stored)
        #expect(token.source.rawValue == ".maho/config.yaml")
    }

    @Test func storeAndRetrieveToken() throws {
        let (vaultPath, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = Auth(vaultPath: vaultPath)
        try auth.storeToken("ghp_stored_test_token_123")

        // Verify it's stored in device config
        let config = Config(vaultPath: vaultPath)
        let deviceConfig = try config.loadDeviceConfig()
        let authSection = deviceConfig["auth"] as? [String: Any]
        #expect(authSection?["github_token"] as? String == "ghp_stored_test_token_123")
    }

    @Test func tokenNeverInVaultConfig() throws {
        let (vaultPath, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = Auth(vaultPath: vaultPath)
        try auth.storeToken("ghp_secret_token_456")

        // Verify token is NOT in vault-level config
        let config = Config(vaultPath: vaultPath)
        let vaultConfig = try config.loadVaultConfig()
        let authSection = vaultConfig["auth"] as? [String: Any]
        #expect(authSection == nil)
    }

    // MARK: - Error Messages

    @Test func authErrorNoTokenHasGuidance() throws {
        let error = AuthError.noTokenFound
        let desc = error.description
        #expect(desc.contains("GITHUB_TOKEN"))
        #expect(desc.contains("gh auth login"))
    }

    @Test func authErrorGhNotInstalledHasGuidance() throws {
        let error = AuthError.ghNotInstalled
        let desc = error.description
        #expect(desc.contains("brew install gh"))
    }

    @Test func authErrorGhNotLoggedInHasGuidance() throws {
        let error = AuthError.ghNotLoggedIn(message: "not logged in")
        let desc = error.description
        #expect(desc.contains("gh auth login"))
        #expect(desc.contains("not logged in"))
    }

    @Test func authErrorTokenInvalidHasGuidance() throws {
        let error = AuthError.tokenInvalid(message: "HTTP 401")
        let desc = error.description
        #expect(desc.contains("mn config auth"))
        #expect(desc.contains("HTTP 401"))
    }

    // MARK: - Pre-flight Checks

    @Test func gitInstalledCheck() throws {
        // On macOS with dev tools, git should be available
        try PreflightCheck.checkGitInstalled()
    }

    @Test func gitNotInstalledErrorMessage() throws {
        let error = AuthError.gitNotInstalled
        let desc = error.description
        #expect(desc.contains("xcode-select --install"))
    }

    @Test func iCloudCheckNonICloudPath() throws {
        let warning = PreflightCheck.checkICloudStatus(vaultPath: "/tmp/test-vault")
        #expect(warning == nil)
    }

    @Test func iCloudCheckICloudPath() throws {
        let warning = PreflightCheck.checkICloudStatus(vaultPath: "~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/Documents")
        // May or may not warn depending on system; just ensure no crash
        _ = warning
    }

    // MARK: - Token Validation (401)

    @Test func invalidTokenThrowsOnValidation() throws {
        let auth = Auth(vaultPath: "/tmp")
        #expect(throws: (any Error).self) {
            try auth.validateToken("ghp_definitely_not_a_real_token")
        }
    }
}
