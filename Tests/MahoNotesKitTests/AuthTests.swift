import Testing
import Foundation
import Yams
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

    /// Temp stand-in for the global config dir. Every `Auth` that stores a token must use one —
    /// the default is the live App Group `config.yaml`, which holds the user's real GitHub token.
    private func makeTempGlobalDir(in tmp: URL) throws -> String {
        let dir = tmp.appendingPathComponent("global-maho").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadAuthSection(globalDir: String) throws -> [String: Any]? {
        let content = try String(contentsOfFile: "\(globalDir)/config.yaml", encoding: .utf8)
        let loaded = try Yams.load(yaml: content) as? [String: Any]
        return loaded?["auth"] as? [String: Any]
    }

    // MARK: - Token Resolution

    @Test func resolveTokenFindsAnySource() throws {
        // On a dev machine, at least one source (env, gh, stored) should be available
        // This test verifies the resolution chain works without crashing
        let (vaultPath, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = Auth(vaultPath: vaultPath, globalConfigDir: try makeTempGlobalDir(in: tmp))
        // Store a token so there's definitely one available
        try auth.storeToken("ghp_test1234567890abcdef")

        let token = try auth.resolveToken()
        #expect(!token.token.isEmpty)
    }

    @Test func storedTokenCanBeRetrieved() throws {
        let (_, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Device-level only: no vault, token lives in the (temp) global config
        let auth = Auth(globalConfigDir: try makeTempGlobalDir(in: tmp))
        try auth.storeToken("ghp_stored_only_test_123")

        let token = try auth.resolveStoredToken()
        #expect(token.token == "ghp_stored_only_test_123")
        #expect(token.source == .stored)
    }

    @Test func resolveStoredTokenThrowsWhenNoneStored() throws {
        let (_, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let auth = Auth(globalConfigDir: try makeTempGlobalDir(in: tmp))
        #expect(throws: AuthError.self) {
            try auth.resolveStoredToken()
        }
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

    @Test func storeTokenPreservesOtherConfigKeys() throws {
        let (_, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let globalDir = try makeTempGlobalDir(in: tmp)
        try "sync:\n  cloud: icloud\n".write(toFile: "\(globalDir)/config.yaml", atomically: true, encoding: .utf8)

        try Auth(globalConfigDir: globalDir).storeToken("ghp_stored_test_token_123")

        let content = try String(contentsOfFile: "\(globalDir)/config.yaml", encoding: .utf8)
        let loaded = try Yams.load(yaml: content) as? [String: Any]
        #expect((loaded?["auth"] as? [String: Any])?["github_token"] as? String == "ghp_stored_test_token_123")
        #expect((loaded?["sync"] as? [String: Any])?["cloud"] as? String == "icloud")
    }

    @Test func tokenNeverInVaultConfig() throws {
        let (vaultPath, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let globalDir = try makeTempGlobalDir(in: tmp)
        let auth = Auth(vaultPath: vaultPath, globalConfigDir: globalDir)
        try auth.storeToken("ghp_secret_token_456")

        // Verify token is NOT in vault-level config
        let config = Config(vaultPath: vaultPath)
        let vaultConfig = try config.loadVaultConfig()
        let authSection = vaultConfig["auth"] as? [String: Any]
        #expect(authSection == nil)

        // ...and that it went to the injected global config instead
        #expect(try loadAuthSection(globalDir: globalDir)?["github_token"] as? String == "ghp_secret_token_456")
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
        let warning = PreflightCheck.checkICloudStatus(vaultPath: "~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents")
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
