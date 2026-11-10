import Testing
import Foundation
import GitHubAPI
@testable import MahoNotesKit

// MARK: - In-memory GitHub

/// A stand-in for the part of GitHub's Git Data API that `GitHubSyncManager` uses: blobs,
/// trees, commits and one branch ref, kept in memory. Ref updates are refused unless they
/// fast-forward (or are forced), as on GitHub.
final class FakeGitHub: @unchecked Sendable {
    let host = "fake-\(UUID().uuidString.lowercased()).test"

    private let lock = NSRecursiveLock()
    private var blobs: [String: Data] = [:]
    private var trees: [String: [String: String]] = [:]          // tree SHA → path → blob SHA
    private var commits: [String: (tree: String, parents: [String])] = [:]
    private var head = ""
    private var counter = 0

    /// Answers for the next `GET ref` calls, instead of the real head (a stale replica).
    var staleHeads: [String] = []
    /// Runs once, just before the next ref update is applied (another device pushing first).
    var beforeNextRefUpdate: (() -> Void)?
    /// Runs once, when the next blob is downloaded (a local save in the middle of a sync).
    var onNextBlobDownload: (() -> Void)?
    private(set) var forcedRefUpdates = 0
    private(set) var refUpdates = 0

    init(files: [String: String]) {
        FakeGitHubProtocol.register(self)
        _ = commit(files: files)
    }

    deinit { FakeGitHubProtocol.unregister(host) }

    private func newID(_ kind: String) -> String {
        counter += 1
        return String(repeating: "0", count: 40 - "\(kind)\(counter)".count) + "\(kind)\(counter)"
    }

    var headSHA: String { lock.withLock { head } }

    /// The branch's files as text.
    var files: [String: String] {
        lock.withLock {
            (trees[commits[head]?.tree ?? ""] ?? [:]).mapValues { String(data: blobs[$0] ?? Data(), encoding: .utf8) ?? "" }
        }
    }

    var commitCount: Int { lock.withLock { commits.count } }

    /// Push a commit directly, as another device would: `changes` on top of the current
    /// files, a nil value deleting the file.
    @discardableResult
    func commit(files changes: [String: String?]) -> String {
        lock.withLock {
            var tree = trees[commits[head]?.tree ?? ""] ?? [:]
            for (path, content) in changes {
                if let content {
                    let data = Data(content.utf8)
                    let sha = GitHubSyncManager.gitBlobSHA(of: data)
                    blobs[sha] = data
                    tree[path] = sha
                } else {
                    tree[path] = nil
                }
            }
            let treeSHA = newID("7")
            trees[treeSHA] = tree
            let commitSHA = newID("c")
            commits[commitSHA] = (treeSHA, head.isEmpty ? [] : [head])
            head = commitSHA
            return commitSHA
        }
    }

    private func isAncestor(_ ancestor: String, of commit: String) -> Bool {
        var queue = [commit], seen = Set<String>()
        while let next = queue.popLast() {
            if next == ancestor { return true }
            guard seen.insert(next).inserted else { continue }
            queue += commits[next]?.parents ?? []
        }
        return false
    }

    // MARK: Requests

    func handle(method: String, path: String, body: Data?) -> (Int, Any) {
        lock.lock()
        defer { lock.unlock() }

        // "/repos/{owner}/{repo}/git/{kind}/…"
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 5, parts[0] == "repos", parts[3] == "git" else {
            return (404, ["message": "Not Found"])
        }
        let kind = parts[4]
        let rest = parts.dropFirst(5).joined(separator: "/")
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]

        switch (method, kind) {
        case ("GET", "ref"):
            let sha = staleHeads.isEmpty ? head : staleHeads.removeFirst()
            return (200, ["ref": "refs/\(rest)", "object": ["type": "commit", "sha": sha]])

        case ("PATCH", "refs"):
            if let hook = beforeNextRefUpdate {
                beforeNextRefUpdate = nil
                hook()
            }
            guard let sha = json["sha"] as? String, commits[sha] != nil else {
                return (422, ["message": "Object does not exist"])
            }
            let force = json["force"] as? Bool ?? false
            guard force || isAncestor(head, of: sha) else {
                return (422, ["message": "Update is not a fast forward"])
            }
            if force { forcedRefUpdates += 1 }
            refUpdates += 1
            head = sha
            return (200, ["ref": "refs/\(rest)", "object": ["type": "commit", "sha": sha]])

        case ("GET", "commits"):
            guard let commit = commits[rest] else { return (404, ["message": "Not Found"]) }
            return (200, ["sha": rest, "tree": ["sha": commit.tree], "parents": commit.parents.map { ["sha": $0] }])

        case ("POST", "commits"):
            guard let tree = json["tree"] as? String, trees[tree] != nil else {
                return (422, ["message": "Tree SHA does not exist"])
            }
            let sha = newID("c")
            commits[sha] = (tree, json["parents"] as? [String] ?? [])
            return (201, ["sha": sha, "tree": ["sha": tree]])

        case ("GET", "trees"):
            guard let tree = trees[rest] else { return (404, ["message": "Not Found"]) }
            let entries = tree.keys.sorted().map { ["path": $0, "mode": "100644", "type": "blob", "sha": tree[$0]!] }
            return (200, ["sha": rest, "tree": entries, "truncated": false])

        case ("POST", "trees"):
            var tree: [String: String] = [:]
            for entry in json["tree"] as? [[String: Any]] ?? [] {
                guard let path = entry["path"] as? String, let sha = entry["sha"] as? String, blobs[sha] != nil else {
                    return (422, ["message": "tree.sha is not a valid blob"])
                }
                tree[path] = sha
            }
            let sha = newID("7")
            trees[sha] = tree
            return (201, ["sha": sha, "tree": []])

        case ("GET", "blobs"):
            guard let data = blobs[rest] else { return (404, ["message": "Not Found"]) }
            if let hook = onNextBlobDownload {
                onNextBlobDownload = nil
                hook()
            }
            return (200, ["sha": rest, "content": data.base64EncodedString(), "encoding": "base64", "size": data.count])

        case ("POST", "blobs"):
            guard let content = json["content"] as? String,
                  let data = (json["encoding"] as? String) == "base64" ? Data(base64Encoded: content) : Data(content.utf8)
            else { return (422, ["message": "Bad blob"]) }
            let sha = GitHubSyncManager.gitBlobSHA(of: data)
            blobs[sha] = data
            return (201, ["sha": sha])

        default:
            return (404, ["message": "Not Found"])
        }
    }

    /// A client whose requests are answered by this object instead of the network.
    func client() -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHubProtocol.self]
        return GitHubClient(token: "test-token", baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: config))
    }
}

final class FakeGitHubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: () -> FakeGitHub?] = [:]

    static func register(_ server: FakeGitHub) {
        lock.withLock { servers[server.host] = { [weak server] in server } }
    }

    static func unregister(_ host: String) {
        lock.withLock { servers[host] = nil }
    }

    private static func server(for request: URLRequest) -> FakeGitHub? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { servers[host]?() }
    }

    override class func canInit(with request: URLRequest) -> Bool { server(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        // URLSession hands a protocol the body as a stream.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let (status, object) = server.handle(method: request.httpMethod ?? "GET", path: url.path, body: body)
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Tests

/// The app's GitHub sync (REST, no git binary), run against an in-memory GitHub with one
/// temp folder per "device". Nothing here reads the real config, token or iCloud container.
@Suite("GitHubSyncManager")
struct GitHubSyncManagerTests {

    /// A device: a vault folder and a sync manager for it.
    final class Device {
        let url: URL
        let manager: GitHubSyncManager
        /// Keeps the server registered for as long as a device talks to it.
        private let github: FakeGitHub

        init(_ github: FakeGitHub) throws {
            self.github = github
            url = FileManager.default.temporaryDirectory.appendingPathComponent("maho-rest-sync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            manager = GitHubSyncManager(client: github.client(), owner: "o", repo: "r", vaultPath: url.path)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ text: String, to path: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func read(_ path: String) -> String? {
            try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
        }

        func delete(_ path: String) throws {
            try FileManager.default.removeItem(at: url.appendingPathComponent(path))
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
        }

        @discardableResult
        func sync() async throws -> SyncResult { try await manager.sync() }
    }

    private func note(_ body: String, title: String = "Note") -> String {
        "---\ntitle: \(title)\n---\n\(body)\n"
    }

    private func index(_ order: [String], title: String = "Notes") -> String {
        "---\ntitle: \(title)\norder:\n" + order.map { "  - \($0)\n" }.joined() + "---\n"
    }

    /// A repository with a small vault, and two devices that have both cloned it.
    private func twoDevices(extra: [String: String] = [:]) async throws -> (FakeGitHub, Device, Device) {
        var files = [
            "maho.yaml": "author:\n  name: Test\n",
            ".gitignore": ".maho/\n_site/\n*.conflict-*\n",
            "notes/a.md": note("A"),
            "notes/b.md": note("B"),
            "notes/_index.md": index(["a.md", "b.md"]),
        ]
        files.merge(extra) { _, new in new }
        let github = FakeGitHub(files: files)
        let a = try Device(github), b = try Device(github)
        #expect(try await a.sync().cloned)
        #expect(try await b.sync().cloned)
        return (github, a, b)
    }

    // MARK: Not losing other devices' work

    /// The data-loss bug behind the audit in issue #2: a device with local changes used to
    /// push a snapshot of its own files, forced, before looking at the remote — deleting the
    /// notes other devices had added since, and reverting their edits.
    @Test func pushDoesNotUndoWhatAnotherDevicePushed() async throws {
        let (github, a, b) = try await twoDevices()

        try a.write(note("New on A"), to: "notes/x.md")
        try a.write(note("A edited by A"), to: "notes/a.md")
        try await a.sync()

        // B has not pulled yet and changes something else.
        try b.write(note("B edited by B"), to: "notes/b.md")
        let result = try await b.sync()

        #expect(result.pulled && result.pushed)
        #expect(result.status == "ok")
        #expect(github.files["notes/x.md"] == note("New on A"))
        #expect(github.files["notes/a.md"] == note("A edited by A"))
        #expect(github.files["notes/b.md"] == note("B edited by B"))
        #expect(b.read("notes/x.md") == note("New on A"))
        #expect(b.read("notes/a.md") == note("A edited by A"))
        #expect(github.forcedRefUpdates == 0)

        // And A gets B's edit without losing its own note.
        try await a.sync()
        #expect(a.read("notes/b.md") == note("B edited by B"))
        #expect(a.exists("notes/x.md"))
    }

    @Test func nothingToDoIsReportedAsUpToDate() async throws {
        let (github, a, _) = try await twoDevices()
        let commits = github.commitCount
        let result = try await a.sync()
        #expect(!result.pulled && !result.pushed)
        #expect(result.message == "Already up to date.")
        #expect(github.commitCount == commits)
    }

    @Test func deletionsTravelBothWays() async throws {
        let (github, a, b) = try await twoDevices()

        try a.delete("notes/a.md")
        #expect(try await a.sync().pushed)
        #expect(github.files["notes/a.md"] == nil)

        let result = try await b.sync()
        #expect(result.pulled)
        #expect(!b.exists("notes/a.md"))
        #expect(b.exists("notes/b.md"))
    }

    @Test func anEditBeatsADeletion() async throws {
        let (github, a, b) = try await twoDevices()

        // Edited on A, deleted on B: the file comes back on B.
        try a.write(note("A, edited"), to: "notes/a.md")
        try await a.sync()
        try b.delete("notes/a.md")
        try await b.sync()
        #expect(b.read("notes/a.md") == note("A, edited"))
        #expect(github.files["notes/a.md"] == note("A, edited"))

        // Deleted on A, edited on B: the deletion is taken, the edit kept as a conflict copy.
        try a.delete("notes/b.md")
        try await a.sync()
        try b.write(note("B, edited"), to: "notes/b.md")
        let result = try await b.sync()
        #expect(!b.exists("notes/b.md"))
        let copy = try #require(result.conflictFiles.first)
        #expect(b.read(copy) == note("B, edited"))
        #expect(result.status == "conflicts")
    }

    // MARK: Conflicts

    @Test func sameNoteEditedOnBothDevicesKeepsBothVersions() async throws {
        let (github, a, b) = try await twoDevices()

        try a.write(note("From A"), to: "notes/a.md")
        try await a.sync()
        try b.write(note("From B"), to: "notes/a.md")
        let result = try await b.sync()

        // Remote wins in place; this device's version is next to it.
        #expect(b.read("notes/a.md") == note("From A"))
        let copy = try #require(result.conflictFiles.first)
        #expect(copy.hasPrefix("notes/a.conflict-") && copy.hasSuffix("-local.md"))
        #expect(b.read(copy) == note("From B"))

        // Transport succeeded, but the result does not call it resolved.
        #expect(result.pulled)
        #expect(result.status == "conflicts")
        #expect(result.unresolvedConflicts == [copy])

        // The copy stays on this device, and keeps being reported until it is dealt with.
        #expect(github.files.keys.allSatisfy { !$0.contains(".conflict-") })
        let again = try await b.sync()
        #expect(again.conflictFiles.isEmpty)
        #expect(again.unresolvedConflicts == [copy])
        #expect(again.status == "conflicts")

        try b.delete(copy)
        #expect(try await b.sync().status == "ok")
    }

    // MARK: Collection index (issue #2)

    @Test func notesAddedOnTwoDevicesAreBothListed() async throws {
        let (github, a, b) = try await twoDevices()

        try a.write(note("C"), to: "notes/c.md")
        try a.write(index(["a.md", "b.md", "c.md"]), to: "notes/_index.md")
        try await a.sync()

        try b.write(note("D"), to: "notes/d.md")
        try b.write(index(["a.md", "b.md", "d.md"]), to: "notes/_index.md")
        let result = try await b.sync()

        #expect(result.conflictFiles.isEmpty)
        #expect(result.mergedFiles == ["notes/_index.md"])
        #expect(result.status == "ok")
        #expect(readDirectoryOrder(at: b.url.appendingPathComponent("notes").path).notes == ["a.md", "b.md", "d.md", "c.md"])
        #expect(github.files["notes/_index.md"] == b.read("notes/_index.md"))
        #expect(github.files["notes/c.md"] != nil && github.files["notes/d.md"] != nil)

        // Syncing again changes nothing: no new conflict, no reshuffled order.
        let commits = github.commitCount
        let again = try await b.sync()
        #expect(again.message == "Already up to date.")
        #expect(github.commitCount == commits)

        // The first device takes the merged index as it is.
        let onA = try await a.sync()
        #expect(onA.conflictFiles.isEmpty && onA.mergedFiles.isEmpty)
        #expect(a.read("notes/_index.md") == b.read("notes/_index.md"))
    }

    @Test func removedNoteIsNotBroughtBackByTheOtherDevicesIndex() async throws {
        let (github, a, b) = try await twoDevices()

        try a.delete("notes/b.md")
        try a.write(index(["a.md"]), to: "notes/_index.md")
        try await a.sync()

        try b.write(note("C"), to: "notes/c.md")
        try b.write(index(["a.md", "b.md", "c.md"]), to: "notes/_index.md")
        let result = try await b.sync()

        #expect(result.conflictFiles.isEmpty)
        #expect(readDirectoryOrder(at: b.url.appendingPathComponent("notes").path).notes == ["a.md", "c.md"])
        #expect(!b.exists("notes/b.md"))
        #expect(github.files["notes/b.md"] == nil)
    }

    @Test func contradictoryIndexChangesStayAConflict() async throws {
        let (_, a, b) = try await twoDevices(extra: ["notes/c.md": "C\n", "notes/_index.md": "---\ntitle: Notes\norder:\n  - a.md\n  - b.md\n  - c.md\n---\n"])

        try a.write(index(["a.md", "c.md", "b.md"]), to: "notes/_index.md")
        try await a.sync()
        try b.write(index(["b.md", "a.md", "c.md"]), to: "notes/_index.md")
        let result = try await b.sync()

        #expect(result.mergedFiles.isEmpty)
        let copy = try #require(result.conflictFiles.first)
        #expect(copy.hasPrefix("notes/_index.conflict-"))
        #expect(b.read("notes/_index.md") == index(["a.md", "c.md", "b.md"]))
        #expect(b.read(copy) == index(["b.md", "a.md", "c.md"]))
        #expect(result.status == "conflicts")
        // A conflict copy of an index is not a note and does not show up as one.
        #expect(try Vault(path: b.url.path).allNotes().allSatisfy { !$0.relativePath.contains("_index") })
    }

    // MARK: Races

    @Test func anotherDevicePushingMidSyncIsMergedNotOverwritten() async throws {
        let (github, a, _) = try await twoDevices()

        try a.write(note("A edited"), to: "notes/a.md")
        // Just as A is about to move the branch, someone else gets there first.
        github.beforeNextRefUpdate = {
            github.commit(files: ["notes/late.md": "late\n", "notes/b.md": "B changed elsewhere\n"])
        }
        let result = try await a.sync()

        #expect(result.pushed && result.pulled)
        #expect(github.files["notes/late.md"] == "late\n")
        #expect(github.files["notes/b.md"] == "B changed elsewhere\n")
        #expect(github.files["notes/a.md"] == note("A edited"))
        #expect(a.read("notes/late.md") == "late\n")
        #expect(github.forcedRefUpdates == 0)
    }

    @Test func aStaleAnswerRightAfterAPushDoesNotRevertLocalFiles() async throws {
        let (github, a, _) = try await twoDevices()
        let before = github.headSHA

        try a.write(note("A edited"), to: "notes/a.md")
        try await a.sync()

        // GitHub's read replica has not caught up: it still reports the old head.
        github.staleHeads = [before]
        let result = try await a.sync()

        #expect(a.read("notes/a.md") == note("A edited"))
        #expect(!result.pulled)
        #expect(github.files["notes/a.md"] == note("A edited"))
    }

    @Test func aFileSavedWhileItsRemoteVersionDownloadsIsNotLost() async throws {
        let (github, a, b) = try await twoDevices()

        try a.write(note("From A"), to: "notes/a.md")
        try await a.sync()

        // B has not touched a.md when its sync starts — but the editor saves it while the
        // remote version is on its way down.
        github.onNextBlobDownload = {
            try? b.write(self.note("Typed during sync"), to: "notes/a.md")
        }
        let result = try await b.sync()

        #expect(b.read("notes/a.md") == note("From A"))
        let copy = try #require(result.conflictFiles.first)
        #expect(b.read(copy) == note("Typed during sync"))
    }

    // MARK: First sync

    @Test func firstSyncOfAFolderWithContentKeepsBothSides() async throws {
        let github = FakeGitHub(files: ["notes/a.md": note("Remote A"), "notes/r.md": note("Remote only")])
        let device = try Device(github)
        try device.write(note("Local A"), to: "notes/a.md")
        try device.write(note("Local only"), to: "notes/l.md")

        let result = try await device.sync()

        #expect(device.read("notes/a.md") == note("Remote A"))
        #expect(device.read("notes/r.md") == note("Remote only"))
        let copy = try #require(result.conflictFiles.first)
        #expect(device.read(copy) == note("Local A"))
        #expect(github.files["notes/l.md"] == note("Local only"))
        #expect(github.files["notes/r.md"] == note("Remote only"))
        #expect(SyncManifest.exists(vaultPath: device.url.path))
    }

    @Test func aWipedVaultFolderDoesNotDeleteTheRepository() async throws {
        let (github, a, _) = try await twoDevices()
        // The vault's files are gone (a wiped container); the sync state survived.
        for name in try FileManager.default.contentsOfDirectory(atPath: a.url.path) where name != ".maho" {
            try FileManager.default.removeItem(at: a.url.appendingPathComponent(name))
        }
        let before = github.files

        await #expect(throws: GitHubSyncError.self) { try await a.sync() }
        #expect(github.files == before)
    }

    @Test func aGitFolderInTheVaultIsNotUploaded() async throws {
        let (github, a, _) = try await twoDevices()
        try a.write("ref: refs/heads/main\n", to: ".git/HEAD")
        try a.write(note("A edited"), to: "notes/a.md")
        try await a.sync()
        #expect(github.files.keys.allSatisfy { !$0.hasPrefix(".git/") })
        #expect(github.files["notes/a.md"] == note("A edited"))
    }
}
