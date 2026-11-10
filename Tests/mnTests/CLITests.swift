import Testing
import Foundation

/// Runs the real `mn` binary. Every invocation gets a throwaway home directory and an
/// explicit `--vault <temp folder>`, so nothing here can reach the user's config or vaults.
struct Sandbox {
    let root: URL
    let home: URL
    let vault: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("mn-cli-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        vault = root.appendingPathComponent("vault")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: vault.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let yaml = """
        title: Test Vault
        author:
          name: Test Author
        collections:
          - id: notes
            name: Notes
        """
        try yaml.write(to: vault.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String

        /// stdout parsed as a JSON object.
        func object() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        }

        /// stdout parsed as a JSON array of objects.
        func array() throws -> [[String: Any]] {
            try #require(try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [[String: Any]])
        }

        /// The `error` object of a JSON failure.
        func error() throws -> [String: Any] {
            try #require(try object()["error"] as? [String: Any])
        }
    }

    /// Run `mn <arguments> --vault <sandbox vault>`.
    @discardableResult
    func mn(_ arguments: String..., stdin: String? = nil, vault overrideVault: String? = nil) throws -> Result {
        try run(arguments, stdin: stdin, vault: overrideVault)
    }

    @discardableResult
    func run(_ arguments: [String], stdin: String? = nil, vault overrideVault: String? = nil) throws -> Result {
        try Self.launch(arguments + ["--vault", overrideVault ?? vault.path], home: home, stdin: stdin)
    }

    /// Run `mn` with exactly these arguments, in a throwaway home directory.
    static func launch(_ arguments: [String], home: URL, stdin: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = try binary()
        process.arguments = arguments
        process.environment = [
            "CFFIXED_USER_HOME": home.path,
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try input.fileHandleForWriting.close()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: vault.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The `mn` executable SwiftPM built next to the test bundle.
    static func binary() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MN_BINARY"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("mn"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("mn"))
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(packageRoot.appendingPathComponent(".build/debug/mn"))
        return try #require(
            candidates.first { fm.isExecutableFile(atPath: $0.path) },
            "mn binary not found; looked in \(candidates.map(\.path))"
        )
    }
}

@Suite("mn CLI (end to end)")
struct CLITests {

    // MARK: - Writing

    @Test func newWritesTheWholeNoteInOneCall() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let result = try box.mn(
            "new", "Plan: Q4 #1", "--collection", "notes", "--tags", "a:b, plain", "--stdin", "--json",
            stdin: "## Decisions\n- Ship on Friday\n"
        )
        #expect(result.status == 0)
        let json = try result.object()
        #expect(json["action"] as? String == "created")
        #expect(json["path"] as? String == "notes/plan-q4-1.md")
        #expect(json["absolutePath"] as? String == box.vault.appendingPathComponent("notes/plan-q4-1.md").path)
        let note = try #require(json["note"] as? [String: Any])
        #expect(note["title"] as? String == "Plan: Q4 #1")
        #expect(note["tags"] as? [String] == ["a:b", "plain"])
        #expect(note["author"] as? String == "Test Author")
        #expect(note["body"] == nil)

        let content = try box.read("notes/plan-q4-1.md")
        #expect(content.hasPrefix("---\ntitle: \"Plan: Q4 #1\"\ntags: [a:b, plain]\n"))
        #expect(content.hasSuffix("---\n\n# Plan: Q4 #1\n\n## Decisions\n- Ship on Friday\n"))
    }

    @Test func bodyOptionsAreExclusiveAndFileWorks() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let bodyFile = box.root.appendingPathComponent("body.md")
        try "from a file\n".write(to: bodyFile, atomically: true, encoding: .utf8)

        #expect(try box.mn("new", "From File", "--collection", "notes", "--file", bodyFile.path).status == 0)
        #expect(try box.read("notes/from-file.md").hasSuffix("# From File\n\nfrom a file\n"))

        let both = try box.mn("new", "Both", "--collection", "notes", "--body", "x", "--file", bodyFile.path)
        #expect(both.status == 64)

        let missing = try box.mn("new", "Missing", "--collection", "notes", "--file", "/nonexistent/body.md", "--json")
        #expect(missing.status == 1)
        #expect(try missing.error()["code"] as? String == "invalid_input")
        #expect(!FileManager.default.fileExists(atPath: box.vault.appendingPathComponent("notes/missing.md").path))
    }

    @Test func typoInCollectionDoesNotCreateOne() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let typo = try box.mn("new", "X", "--collection", "nots", "--json")
        #expect(typo.status == 1)
        let error = try typo.error()
        #expect(error["code"] as? String == "collection_not_found")
        #expect((error["hint"] as? String)?.contains("notes") == true)
        #expect(!FileManager.default.fileExists(atPath: box.vault.appendingPathComponent("nots").path))

        let escape = try box.mn("new", "X", "--collection", "../outside", "--create-collection", "--json")
        #expect(escape.status == 1)
        #expect(try escape.error()["code"] as? String == "invalid_collection")
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("outside").path))

        let created = try box.mn("new", "X", "--collection", "inbox", "--create-collection")
        #expect(created.status == 0)
        #expect(created.stdout == "Created: inbox/x.md\n")
        #expect(try box.read("maho.yaml").contains("id: inbox"))
    }

    @Test func retryWithSkipDoesNotDuplicate() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        #expect(try box.mn("new", "Once", "--collection", "notes", "--body", "first").status == 0)
        let retry = try box.mn("new", "Once", "--collection", "notes", "--body", "second", "--if-exists", "skip", "--json")
        #expect(retry.status == 0)
        #expect(try retry.object()["action"] as? String == "exists")
        #expect(try box.read("notes/once.md").contains("first"))

        let strict = try box.mn("new", "Once", "--collection", "notes", "--if-exists", "error", "--json")
        #expect(strict.status == 1)
        #expect(try strict.error()["code"] as? String == "note_exists")
        #expect(!FileManager.default.fileExists(atPath: box.vault.appendingPathComponent("notes/once-1.md").path))
    }

    @Test func writeAppendAndEdit() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "Log", "--collection", "notes", "--body", "Intro.")

        // Values that start with a dash are text, not options.
        #expect(try box.mn("write", "notes/log", "--append", "--body", "- first").status == 0)
        #expect(try box.mn("write", "notes/log.md", "--append", "--stdin", stdin: "- second\n").status == 0)
        #expect(try box.read("notes/log.md").hasSuffix("# Log\n\nIntro.\n\n- first\n- second\n"))

        let ambiguous = try box.mn("edit", "notes/log.md", "--find", "- ", "--replace", "* ", "--json")
        #expect(ambiguous.status == 1)
        #expect(try ambiguous.error()["code"] as? String == "ambiguous_text")

        let edited = try box.mn("edit", "notes/log.md", "--find", "- first", "--replace", "- FIRST", "--json")
        #expect(edited.status == 0)
        #expect(try edited.object()["replacements"] as? Int == 1)
        #expect(try box.read("notes/log.md").hasSuffix("- FIRST\n- second\n"))

        let replaced = try box.mn("write", "notes/log.md", "--body", "fresh", "--json")
        #expect(try replaced.object()["action"] as? String == "replaced")
        #expect(try box.read("notes/log.md").hasSuffix("---\n\nfresh\n"))
        #expect(try box.read("notes/log.md").contains("title: Log\n"))

        let noBody = try box.mn("write", "notes/log.md", "--json")
        #expect(noBody.status == 1)
        #expect(try noBody.error()["code"] as? String == "missing_body")
    }

    @Test func emptyInputDoesNotBlankANote() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "Keep", "--collection", "notes", "--body", "precious")
        let before = try box.read("notes/keep.md")

        // What `failing-command | mn write … --stdin` looks like.
        let piped = try box.mn("write", "notes/keep.md", "--stdin", "--json", stdin: "")
        #expect(piped.status == 1)
        #expect(try piped.error()["code"] as? String == "missing_body")
        let appended = try box.mn("write", "notes/keep.md", "--append", "--body", "  ", "--json")
        #expect(try appended.error()["code"] as? String == "missing_body")
        #expect(try box.read("notes/keep.md") == before)

        // Clearing on purpose is still possible.
        #expect(try box.mn("write", "notes/keep.md", "--body", "").status == 0)
        #expect(!(try box.read("notes/keep.md").contains("precious")))
    }

    @Test func relativeVaultStillReportsAbsolutePaths() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let process = Process()
        process.executableURL = try Sandbox.binary()
        process.arguments = ["new", "Rel", "--collection", "notes", "--json", "--vault", "vault"]
        process.currentDirectoryURL = box.root
        process.environment = ["CFFIXED_USER_HOME": box.home.path, "HOME": box.home.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let absolute = try #require(json["absolutePath"] as? String)
        #expect(absolute.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: absolute))
    }

    @Test func indexFileCannotBeWrittenOrDeleted() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "A", "--collection", "notes")
        let before = try box.read("notes/_index.md")

        for arguments in [["write", "notes/_INDEX.md", "--body", "oops"], ["delete", "notes/_INDEX", "--force"]] {
            let result = try box.run(arguments + ["--json"])
            #expect(result.status == 1, "\(arguments)")
            #expect(try result.error()["code"] as? String == "invalid_path", "\(arguments)")
        }
        #expect(try box.read("notes/_index.md") == before)
    }

    @Test func failuresPrintOneJSONDocument() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "A", "--collection", "notes")

        // The bad model name is caught before the keyword index is built and reported.
        let result = try box.mn("index", "--model", "bogus", "--json")
        #expect(result.status == 1)
        #expect(try result.error()["code"] as? String == "invalid_value")

        let bare = try box.mn("new", "Bare", "--collection", "notes", "--no-heading")
        #expect(bare.status == 0)
        #expect(!(try box.read("notes/bare.md").contains("# Bare")))
    }

    // MARK: - Metadata

    @Test func metaTwiceLeavesTheNoteIntact() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.write("notes/block.md", """
            ---
            title: Block
            tags:
              - one
              - two
            created: 2026-01-02T03:04:05+08:00
            updated: 2026-01-02T03:04:05+08:00
            description: "keep: me"
            ---

            body

            """)

        #expect(try box.mn("meta", "notes/block.md", "--add-tag", "three").status == 0)
        let second = try box.mn(
            "meta", "notes/block.md", "--add-tag", "four, five", "--remove-tag", "one",
            "--set", "title=2024: plans", "--set", "public=true", "--json"
        )
        #expect(second.status == 0)
        let note = try #require(try second.object()["note"] as? [String: Any])
        #expect(note["title"] as? String == "2024: plans")
        #expect(note["tags"] as? [String] == ["two", "three", "four", "five"])
        #expect(note["isPublic"] as? Bool == true)

        let content = try box.read("notes/block.md")
        #expect(content.contains("created: 2026-01-02T03:04:05+08:00\n"))
        #expect(content.contains("description: \"keep: me\"\n"))
        #expect(content.hasSuffix("---\n\nbody\n"))

        // Reading it back: metadata only for `meta`, body included for `show`.
        let meta = try box.mn("meta", "notes/block.md", "--json").object()
        #expect(meta["title"] as? String == "2024: plans")
        #expect(meta["body"] == nil)
        let show = try box.mn("show", "notes/block", "--json").object()
        #expect(show["body"] as? String == "\nbody\n")
        #expect(show["absolutePath"] as? String == box.vault.appendingPathComponent("notes/block.md").path)
    }

    @Test func metaRejectsBadChanges() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "Guard", "--collection", "notes")
        let before = try box.read("notes/guard.md")

        for (arguments, code) in [
            (["--set", "collection=x"], "managed_field"),
            (["--set", "tags=a"], "managed_field"),
            (["--set", "colour=red"], "unknown_field"),
            (["--set", "public=maybe"], "invalid_value"),
            (["--set", "novalue"], "invalid_arguments"),
            (["--unset", "title"], "managed_field"),
        ] {
            let process = try box.mn("meta", "notes/guard.md", arguments[0], arguments[1], "--json")
            #expect(process.status == 1, "\(arguments)")
            #expect(try process.error()["code"] as? String == code, "\(arguments)")
        }
        #expect(try box.read("notes/guard.md") == before)
    }

    // MARK: - Errors

    @Test func missingNoteReportsSuggestions() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "Kanji Basics", "--collection", "notes")

        let json = try box.mn("show", "notes/kanji-basic.md", "--json")
        #expect(json.status == 1)
        let error = try json.error()
        #expect(error["code"] as? String == "note_not_found")
        #expect(error["suggestions"] as? [String] == ["notes/kanji-basics.md"])

        // Without --json: nothing on stdout, a readable message on stderr.
        let text = try box.mn("show", "notes/kanji-basic.md")
        #expect(text.status == 1)
        #expect(text.stdout.isEmpty)
        #expect(text.stderr.contains("Error: Note not found: notes/kanji-basic.md"))
        #expect(text.stderr.contains("notes/kanji-basics.md"))
    }

    @Test func pathsOutsideTheVaultAreRejected() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let outside = box.root.appendingPathComponent("outside.md")
        let original = "---\ntitle: Outside\n---\n\nsecret\n"
        try original.write(to: outside, atomically: true, encoding: .utf8)

        let commands = [
            ["show"],
            ["delete", "--force"],
            ["write", "--body", "x"],
            ["edit", "--find", "secret", "--replace", "x"],
            ["meta", "--set", "title=x"],
            ["move", "--to", "notes"],
        ]
        for command in commands {
            for path in ["../outside.md", "notes/../../outside.md", outside.path] {
                let result = try box.run([command[0], path] + command.dropFirst() + ["--json"])
                #expect(result.status == 1, "\(command) \(path)")
                #expect(try result.error()["code"] as? String == "invalid_path", "\(command) \(path)")
            }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == original)
    }

    @Test func unknownVaultIsAStructuredError() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let result = try box.mn("list", "--json", vault: "no-such-vault")
        #expect(result.status == 1)
        #expect(try result.error()["code"] as? String == "vault_not_found")
    }

    @Test func usageErrorsKeepArgumentParserBehavior() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let result = try box.mn("new", "--collection", "notes")
        #expect(result.status == 64)
        #expect(result.stderr.contains("Usage: mn new"))

        // With --json the same mistake is reported as JSON, still with status 64.
        let json = try box.mn("list", "--sort", "bogus", "--json")
        #expect(json.status == 64)
        #expect(try json.error()["code"] as? String == "invalid_arguments")
        #expect((try json.error()["message"] as? String)?.contains("--sort") == true)

        // Help is never an error.
        let help = try box.mn("list", "--help", "--json")
        #expect(help.status == 0)
        #expect(help.stdout.contains("USAGE: mn list"))
    }

    // MARK: - Reading

    @Test func listJSONOmitsBodiesUnlessAsked() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "First", "--collection", "notes", "--body", "body text one", "--tags", "x")
        try box.mn("new", "Second", "--collection", "notes", "--body", "body text two")
        try box.mn("new", "Nested", "--collection", "notes/deep", "--create-collection")

        let list = try box.mn("list", "--json").array()
        #expect(list.map { $0["relativePath"] as? String } == ["notes/first.md", "notes/second.md", "notes/deep/nested.md"])
        #expect(list.allSatisfy { $0["body"] == nil })

        let withBodies = try box.mn("list", "--json", "--body").array()
        #expect((withBodies[0]["body"] as? String)?.contains("body text one") == true)

        #expect(try box.mn("list", "--collection", "notes/deep", "--json").array().count == 1)
        #expect(try box.mn("list", "--tag", "x", "--json").array().count == 1)
        #expect(try box.mn("list", "--limit", "2", "--json").array().count == 2)

        let unknown = try box.mn("list", "--collection", "nope", "--json")
        #expect(unknown.status == 1)
        #expect(try unknown.error()["code"] as? String == "collection_not_found")
    }

    @Test func listSortsByUpdatedNewestFirst() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        // Mixed timestamp spellings: +08:00 is earlier than it looks next to Z.
        try box.write("notes/a.md", "---\ntitle: A\nupdated: 2026-03-01T07:00:00+08:00\n---\n")
        try box.write("notes/b.md", "---\ntitle: B\nupdated: 2026-03-01T01:00:00Z\n---\n")
        try box.write("notes/c.md", "---\ntitle: C\nupdated: 2026-02-01T00:00:00Z\n---\n")

        let sorted = try box.mn("list", "--sort", "updated", "--json").array()
        #expect(sorted.map { $0["title"] as? String } == ["B", "A", "C"])
    }

    @Test func searchFindsNotesWrittenAMomentAgo() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "Alpha", "--collection", "notes", "--body", "about zebras")
        #expect(try box.mn("search", "zebras", "--json").array().map { $0["path"] as? String } == ["notes/alpha.md"])

        // The index exists now; a new note and an edit must still be found.
        try box.mn("new", "Beta", "--collection", "notes", "--body", "about quokkas")
        #expect(try box.mn("search", "quokkas", "--json").array().map { $0["path"] as? String } == ["notes/beta.md"])

        try box.mn("delete", "notes/alpha.md", "--force")
        #expect(try box.mn("search", "zebras", "--json").array().isEmpty)

        for i in 0..<4 {
            try box.mn("new", "Wombat \(i)", "--collection", "notes", "--body", "wombat facts")
        }
        #expect(try box.mn("search", "wombat", "--limit", "2", "--json").array().count == 2)
    }

    @Test func moveAndDelete() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.mn("new", "Mover", "--collection", "notes")
        try box.mn("new", "Stays", "--collection", "notes")

        let missingTarget = try box.mn("move", "notes/mover.md", "--to", "archive", "--json")
        #expect(missingTarget.status == 1)
        #expect(try missingTarget.error()["code"] as? String == "collection_not_found")

        let moved = try box.mn("move", "notes/mover.md", "--to", "archive", "--create-collection", "--json")
        #expect(moved.status == 0)
        let json = try moved.object()
        #expect(json["action"] as? String == "moved")
        #expect(json["from"] as? String == "notes/mover.md")
        #expect(json["path"] as? String == "archive/mover.md")
        #expect(try box.read("notes/_index.md").contains("stays.md"))
        #expect(!(try box.read("notes/_index.md").contains("mover.md")))

        let deleted = try box.mn("delete", "archive/mover.md", "--force", "--json")
        #expect(try deleted.object()["action"] as? String == "deleted")
        #expect(!FileManager.default.fileExists(atPath: box.vault.appendingPathComponent("archive/mover.md").path))
        #expect(!(try box.read("archive/_index.md").contains("mover.md")))
    }

    // MARK: - Guide

    @Test func skillGuideIsValidJSONAndMatchesTheVersion() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }

        let json = try Sandbox.launch(["skill", "--json"], home: box.home).object()
        let skill = try #require(json["skill"] as? String)
        #expect(skill.contains("AI Agent Guide"))
        #expect(try Sandbox.launch(["skill"], home: box.home).stdout == skill + "\n")

        let version = try Sandbox.launch(["--version"], home: box.home).stdout
        #expect(json["version"] as? String == version.trimmingCharacters(in: .whitespacesAndNewlines))

        // Every command the guide teaches exists.
        let help = try Sandbox.launch(["--help"], home: box.home).stdout
        for command in ["new", "write", "edit", "meta", "move", "delete", "list", "show", "search", "index", "sync", "publish", "vault"] {
            #expect(skill.contains("mn \(command)"), "guide should mention mn \(command)")
            #expect(help.contains("  \(command)"), "mn should have a \(command) command")
        }
    }
}
