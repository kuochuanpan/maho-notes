import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Note writing")
struct NoteWritingTests {
    private func makeVault() throws -> (Vault, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("note-writing-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let yaml = """
        title: Test
        collections:
          - id: notes
            name: Notes
        """
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)
        return (Vault(path: tmp.path), tmp)
    }

    private func read(_ vault: Vault, _ relativePath: String) throws -> String {
        try String(contentsOfFile: vault.absolutePath(for: relativePath), encoding: .utf8)
    }

    private func write(_ vault: Vault, _ relativePath: String, _ content: String) throws {
        let path = vault.absolutePath(for: relativePath)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - createNote

    @Test func titleAndTagsWithYAMLSyntaxSurvive() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try vault.createNote(
            title: "Plan: Q4 #1 [draft]",
            collection: "notes",
            tags: ["a:b", "c#d", "with, comma", "true"],
            author: "O'Brien: PI",
            series: "2026: plans",
            body: nil
        )
        let note = try #require(try vault.showNote(relativePath: created.relativePath))
        #expect(note.title == "Plan: Q4 #1 [draft]")
        #expect(note.tags == ["a:b", "c#d", "with, comma", "true"])
        #expect(note.author == "O'Brien: PI")
        #expect(note.series == "2026: plans")
        #expect(!note.created.isEmpty)
    }

    @Test(arguments: ["2024", "true", "null", "- dash", "漢字: かんじ", "\"quoted\""])
    func awkwardTitlesStayStrings(_ title: String) throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try vault.createNote(title: title, collection: "notes", body: nil)
        #expect(try vault.showNote(relativePath: created.relativePath)?.title == title)
    }

    @Test func stubBodyMatchesAppTemplate() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let path = try vault.createNote(title: "Hello World", collection: "notes", tags: [])
        #expect(path == "notes/hello-world.md")
        let content = try read(vault, path)
        #expect(content.hasSuffix("---\n\n# Hello World\n\n"))
        #expect(content.contains("\ntags: []\n"))
        #expect(!content.contains("author:"))
    }

    @Test func bodyIsWrittenUnderAHeading() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = try vault.createNote(title: "With Body", collection: "notes", body: "First paragraph.\n\n- item\n")
        #expect(try read(vault, a.relativePath).hasSuffix("---\n\n# With Body\n\nFirst paragraph.\n\n- item\n"))

        // A body that already opens with a level-1 heading is left alone.
        let b = try vault.createNote(title: "Own Heading", collection: "notes", body: "# Custom\n\ntext")
        #expect(try read(vault, b.relativePath).hasSuffix("---\n\n# Custom\n\ntext\n"))

        let c = try vault.createNote(title: "No Heading", collection: "notes", body: "text only", addHeading: false)
        #expect(try read(vault, c.relativePath).hasSuffix("---\n\ntext only\n"))
    }

    @Test func titleWithoutSlugCharactersGetsAFilename() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try vault.createNote(title: "🎉🎉", collection: "notes", body: nil)
        #expect(created.relativePath == "notes/untitled.md")
        #expect(try vault.showNote(relativePath: created.relativePath)?.title == "🎉🎉")
        // The note is visible — not a hidden `.md` file.
        #expect(try vault.allNotes().count == 1)
    }

    @Test func veryLongTitleStillFitsAFilename() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let title = String(repeating: "漢字かな", count: 60)
        let created = try vault.createNote(title: title, collection: "notes", body: nil)
        let filename = (created.relativePath as NSString).lastPathComponent
        #expect(filename.utf8.count <= 255)
        #expect(try vault.showNote(relativePath: created.relativePath)?.title == title)
    }

    @Test func emptyTitleIsRejected() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: NoteError.emptyTitle) {
            try vault.createNote(title: "  \n ", collection: "notes", body: nil)
        }
    }

    @Test func multiLineTitleIsCollapsed() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try vault.createNote(title: "Line one\nline two", collection: "notes", body: nil)
        #expect(try vault.showNote(relativePath: created.relativePath)?.title == "Line one line two")
    }

    @Test(arguments: ["../escape", "/tmp/escape", "notes/../../escape", ".hidden", "_assets", "~/x", ""])
    func collectionCannotLeaveTheVault(_ collection: String) throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: NoteError.self) {
            try vault.createNote(title: "X", collection: collection, body: nil, createCollection: true)
        }
        #expect(throws: NoteError.self) {
            try vault.createNote(title: "X", collection: collection, tags: [])
        }
        // Nothing was written next to the vault.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tmp.deletingLastPathComponent().path)
        #expect(!siblings.contains("escape"))
    }

    @Test func missingCollectionIsAnErrorUnlessAskedFor() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: NoteError.collectionNotFound("nots", available: ["notes"])) {
            try vault.createNote(title: "Typo", collection: "nots", body: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: vault.absolutePath(for: "nots")))

        let created = try vault.createNote(title: "First", collection: "inbox", body: nil, createCollection: true)
        #expect(created.relativePath == "inbox/first.md")
        // The new top-level collection is registered in maho.yaml, and existing keys are kept.
        let collections = try loadCollections(from: vault.path)
        #expect(collections.map(\.id) == ["notes", "inbox"])
        #expect(try Config(vaultPath: vault.path).loadVaultConfig()["title"] as? String == "Test")

        // A nested collection under an existing one is created without touching maho.yaml.
        let nested = try vault.createNote(title: "Deep", collection: "notes/drafts", body: nil, createCollection: true)
        #expect(nested.relativePath == "notes/drafts/deep.md")
        #expect(try loadCollections(from: vault.path).count == 2)
    }

    @Test func existingNotePolicies() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = try vault.createNote(title: "Same", collection: "notes", body: "one")
        #expect(first == NoteCreation(relativePath: "notes/same.md", created: true))

        let skipped = try vault.createNote(title: "Same", collection: "notes", body: "two", ifExists: .skip)
        #expect(skipped == NoteCreation(relativePath: "notes/same.md", created: false))
        #expect(try read(vault, "notes/same.md").contains("one"))

        #expect(throws: NoteError.noteExists("notes/same.md")) {
            try vault.createNote(title: "Same", collection: "notes", body: "three", ifExists: .error)
        }

        let suffixed = try vault.createNote(title: "Same", collection: "notes", body: "four")
        #expect(suffixed.relativePath == "notes/same-1.md")

        // Each created note is listed once in the collection's order.
        #expect(readDirectoryOrder(at: vault.absolutePath(for: "notes")).notes == ["same.md", "same-1.md"])
    }

    // MARK: - resolveNotePath

    @Test func resolvesTheWaysAPathGetsTyped() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try vault.createNote(title: "My Note", collection: "notes", body: nil)

        #expect(try vault.resolveNotePath("notes/my-note.md") == "notes/my-note.md")
        #expect(try vault.resolveNotePath("notes/my-note") == "notes/my-note.md")
        #expect(try vault.resolveNotePath("./notes//my-note.md ") == "notes/my-note.md")
        #expect(try vault.resolveNotePath(vault.absolutePath(for: "notes/my-note.md")) == "notes/my-note.md")
    }

    @Test func rejectsPathsThatAreNotNotes() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try vault.createNote(title: "My Note", collection: "notes", body: nil)

        for bad in ["../outside.md", "notes/../../outside.md", "/etc/hosts", "notes/_index.md", "notes", ".maho/config.yaml", "", "maho.yaml"] {
            #expect(throws: NoteError.self, "path: \(bad)") { try vault.resolveNotePath(bad) }
        }
        do {
            _ = try vault.resolveNotePath("/etc/hosts")
            Issue.record("expected an error")
        } catch let error as NoteError {
            #expect(error.code == "invalid_path")
        }
    }

    @Test func missingNoteSuggestsNearMatches() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try vault.createNote(title: "Kanji Basics", collection: "notes", body: nil)
        _ = try vault.createNote(title: "Unrelated", collection: "notes", body: nil)
        _ = try vault.createNote(title: "Kanji Basics", collection: "archive", body: nil, createCollection: true)

        func suggestions(_ input: String) -> [String] {
            do {
                _ = try vault.resolveNotePath(input)
                return ["<resolved>"]
            } catch let error as NoteError {
                #expect(error.code == "note_not_found")
                return error.suggestions
            } catch {
                return ["<other error>"]
            }
        }
        // Right filename, wrong or missing collection.
        #expect(Set(suggestions("kanji-basics.md")) == ["notes/kanji-basics.md", "archive/kanji-basics.md"])
        // A title instead of a filename.
        #expect(Set(suggestions("Kanji Basics")) == ["notes/kanji-basics.md", "archive/kanji-basics.md"])
        // A typo.
        #expect(suggestions("notes/kanji-basic.md").contains("notes/kanji-basics.md"))
        #expect(suggestions("notes/kanij-basics").contains("notes/kanji-basics.md"))
        #expect(suggestions("notes/zzzzzz.md").isEmpty)
    }

    // MARK: - Body

    @Test func replaceBodyKeepsFrontmatterExactly() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = """
            ---
            title: "Keep: me"
            tags:
              - one
            created: 2026-01-02T03:04:05+08:00
            updated: 2026-01-02T03:04:05+08:00
            custom_key: {a: 1}
            ---

            # Old

            old body

            """
        try write(vault, "notes/n.md", original)

        try vault.writeNoteBody(relativePath: "notes/n.md", text: "# New\n\nnew body", mode: .replace)
        let content = try read(vault, "notes/n.md")
        #expect(content.hasSuffix("---\n\n# New\n\nnew body\n"))
        #expect(content.contains("title: \"Keep: me\"\ntags:\n  - one\ncreated: 2026-01-02T03:04:05+08:00\n"))
        #expect(content.contains("custom_key: {a: 1}\n"))
        #expect(!content.contains("updated: 2026-01-02T03:04:05+08:00"))

        let note = try #require(try vault.showNote(relativePath: "notes/n.md"))
        #expect(note.title == "Keep: me")
        #expect(note.tags == ["one"])
    }

    @Test func appendStartsAParagraphOrContinuesAList() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = try vault.createNote(title: "Log", collection: "notes", body: "Intro.").relativePath

        try vault.writeNoteBody(relativePath: path, text: "- first", mode: .append)
        try vault.writeNoteBody(relativePath: path, text: "- second\n", mode: .append)
        try vault.writeNoteBody(relativePath: path, text: "Closing words.", mode: .append)
        #expect(try read(vault, path).hasSuffix("---\n\n# Log\n\nIntro.\n\n- first\n- second\n\nClosing words.\n"))
    }

    @Test func appendToEmptyBody() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/e.md", "---\ntitle: E\n---\n")

        try vault.writeNoteBody(relativePath: "notes/e.md", text: "hello", mode: .append)
        let content = try read(vault, "notes/e.md")
        #expect(content.hasPrefix("---\ntitle: E\nupdated: "))
        #expect(content.hasSuffix("\n---\n\nhello\n"))
    }

    @Test func bodyWritesWorkWithoutFrontmatter() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/plain.md", "plain text\n")

        try vault.writeNoteBody(relativePath: "notes/plain.md", text: "more", mode: .append)
        #expect(try read(vault, "notes/plain.md") == "plain text\n\nmore\n")
        try vault.writeNoteBody(relativePath: "notes/plain.md", text: "replaced", mode: .replace)
        #expect(try read(vault, "notes/plain.md") == "replaced\n")
    }

    @Test func repeatedBodyWritesKeepTheNoteReadable() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = try vault.createNote(title: "Stable: note", collection: "notes", tags: ["x"], body: "start").relativePath

        for i in 0..<6 {
            try vault.writeNoteBody(relativePath: path, text: "line \(i)", mode: .append)
            try vault.updateNoteMetadata(relativePath: path, changes: .init(addTags: ["t\(i)"]))
            try setFrontmatterPublic(filePath: vault.absolutePath(for: path), isPublic: i % 2 == 0)
        }
        let note = try #require(try vault.showNote(relativePath: path))
        #expect(note.title == "Stable: note")
        #expect(note.tags == ["x", "t0", "t1", "t2", "t3", "t4", "t5"])
        #expect(note.body.hasPrefix("\n# Stable: note\n\nstart\n\nline 0\n"))
        #expect(note.body.hasSuffix("line 5\n"))
    }

    @Test func replaceInBodyNeedsExactlyOneMatch() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = try vault.createNote(title: "Edit", collection: "notes", body: "alpha beta\nalpha gamma").relativePath

        #expect(throws: NoteError.ambiguousText(path: path, count: 2)) {
            try vault.replaceInNoteBody(relativePath: path, find: "alpha", replace: "x")
        }
        #expect(throws: NoteError.textNotFound(path: path)) {
            try vault.replaceInNoteBody(relativePath: path, find: "delta", replace: "x")
        }
        // The frontmatter is not searched: `title` appears there but not in this body text.
        #expect(throws: NoteError.textNotFound(path: path)) {
            try vault.replaceInNoteBody(relativePath: path, find: "title: Edit", replace: "x")
        }
        let before = try read(vault, path)

        #expect(try vault.replaceInNoteBody(relativePath: path, find: "alpha beta", replace: "ALPHA") == 1)
        #expect(try vault.replaceInNoteBody(relativePath: path, find: "a", replace: "4", all: true) == 4)
        let after = try read(vault, path)
        #expect(after.hasSuffix("---\n\n# Edit\n\nALPHA\n4lph4 g4mm4\n"))
        // Failed edits wrote nothing.
        #expect(before.contains("alpha beta\nalpha gamma"))
    }

    // MARK: - Metadata

    @Test func metadataChangesAreTypedAndReadBack() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = try vault.createNote(title: "Meta", collection: "notes", tags: ["a"], body: nil).relativePath

        let note = try vault.updateNoteMetadata(relativePath: path, changes: .init(
            set: [("title", "2024"), ("public", "true"), ("order", "7"), ("series", "S: one"), ("slug", "meta-slug")],
            addTags: ["b", "a", "c: d"],
            removeTags: ["a"]
        ))
        #expect(note.title == "2024")
        #expect(note.isPublic)
        #expect(note.order == 7)
        #expect(note.series == "S: one")
        #expect(note.slug == "meta-slug")
        #expect(note.tags == ["b", "c: d"])

        let cleared = try vault.updateNoteMetadata(relativePath: path, changes: .init(unset: ["series", "order"]))
        #expect(cleared.series == nil)
        #expect(cleared.order == nil)
        #expect(cleared.title == "2024")
    }

    @Test func blockStyleTagsAreRewrittenWhole() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Regression: `mn meta --add-tag` used to leave the `- item` lines behind, rewrite
        // `created` in another format, and strip the quotes from every other value.
        try write(vault, "notes/b.md", """
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

        let note = try vault.updateNoteMetadata(relativePath: "notes/b.md", changes: .init(addTags: ["three"]))
        #expect(note.tags == ["one", "two", "three"])
        let content = try read(vault, "notes/b.md")
        #expect(content.contains("tags: [one, two, three]\ncreated: 2026-01-02T03:04:05+08:00\n"))
        #expect(content.contains("description: \"keep: me\"\n"))
        #expect(content.hasSuffix("---\n\nbody\n"))
    }

    @Test func invalidChangesAreRejectedBeforeWriting() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = try vault.createNote(title: "Guard", collection: "notes", body: nil).relativePath
        let before = try read(vault, path)

        func code(_ changes: NoteMetadataChanges) -> String? {
            do {
                try vault.updateNoteMetadata(relativePath: path, changes: changes)
                return nil
            } catch let error as NoteError {
                return error.code
            } catch {
                return "other"
            }
        }
        #expect(code(.init(set: [("collection", "x")])) == "managed_field")
        #expect(code(.init(set: [("tags", "x")])) == "managed_field")
        #expect(code(.init(set: [("updated", "2020-01-01")])) == "managed_field")
        #expect(code(.init(set: [("colour", "red")])) == "unknown_field")
        #expect(code(.init(set: [("public", "maybe")])) == "invalid_value")
        #expect(code(.init(set: [("order", "first")])) == "invalid_value")
        #expect(code(.init(set: [("title", "  ")])) == "invalid_value")
        #expect(code(.init(unset: ["title"])) == "managed_field")
        // A valid change mixed with an invalid one changes nothing.
        #expect(code(.init(set: [("title", "New"), ("order", "x")])) == "invalid_value")
        #expect(try read(vault, path) == before)
    }

    @Test func brokenFrontmatterCanBeRepairedBySettingTheField() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // What older versions wrote for a title containing a colon.
        try write(vault, "notes/broken.md", "---\ntitle: Plan: Q4\ntags: [a]\n---\n\nbody\n")
        #expect(try vault.showNote(relativePath: "notes/broken.md")?.title == "broken")

        // Tags can't be edited while the YAML is unreadable…
        #expect(throws: NoteError.self) {
            try vault.updateNoteMetadata(relativePath: "notes/broken.md", changes: .init(addTags: ["b"]))
        }
        // …but setting the broken field again fixes the note.
        let note = try vault.updateNoteMetadata(relativePath: "notes/broken.md", changes: .init(set: [("title", "Plan: Q4")]))
        #expect(note.title == "Plan: Q4")
        #expect(note.tags == ["a"])
    }

    @Test func metadataCanBeAddedToAPlainFile() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/plain.md", "Just text\n")

        let note = try vault.updateNoteMetadata(relativePath: "notes/plain.md", changes: .init(set: [("title", "Titled")], addTags: ["x"]))
        #expect(note.title == "Titled")
        #expect(note.tags == ["x"])
        #expect(note.body == "\nJust text\n")
    }

    // MARK: - Delete

    @Test func deleteRemovesTheNoteFromItsOrder() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try vault.createNote(title: "Keep", collection: "notes", body: nil)
        let path = try vault.createNote(title: "Gone", collection: "notes", body: nil).relativePath

        #expect(try vault.deleteNote(relativePath: path, permanently: true) == false)
        #expect(!FileManager.default.fileExists(atPath: vault.absolutePath(for: path)))
        #expect(readDirectoryOrder(at: vault.absolutePath(for: "notes")).notes == ["keep.md"])
        #expect(throws: NoteError.self) { try vault.deleteNote(relativePath: path, permanently: true) }
    }

    // MARK: - Titles written by other code paths

    @Test func renamingToATitleWithAColonKeepsTheNoteReadable() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = try vault.createNote(title: "Before", collection: "notes", tags: ["t"])

        vault.renameNote(relativePath: path, newTitle: "After: the rename")
        let note = try #require(try vault.showNote(relativePath: path))
        #expect(note.title == "After: the rename")
        #expect(note.tags == ["t"])
    }

    // MARK: - _index.md

    @Test func indexWithBodySurvivesRepeatedOrderWrites() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Regression: each write dropped the line break after the closing `---`. By the third
        // write the collection's title and order were gone.
        try write(vault, "idx/_index.md", "---\ntitle: \"Index: with colon\"\ndescription: \"About #1\"\n---\nCollection description here.\n")

        for title in ["One", "Two", "Three", "Four"] {
            _ = try vault.createNote(title: title, collection: "idx", body: nil)
        }
        let dir = vault.absolutePath(for: "idx")
        #expect(readDirectoryOrder(at: dir).notes == ["one.md", "two.md", "three.md", "four.md"])

        let content = try read(vault, "idx/_index.md")
        #expect(content.hasSuffix("---\nCollection description here.\n"))
        let (yaml, body) = splitFrontmatter(content)
        #expect(body == "Collection description here.\n")
        let parsed = FrontmatterDocument(content)
        #expect(try parsed.yaml()["title"] as? String == "Index: with colon")
        #expect(try parsed.yaml()["description"] as? String == "About #1")
        #expect(yaml != nil)
    }

    @Test func orderEntriesWithYAMLSyntaxSurvive() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = vault.absolutePath(for: "notes")
        let names = ["2024: plan.md", "#hash.md", "plain.md", "- dash.md"]

        try writeDirectoryOrder(at: dir, notes: names)
        try writeDirectoryOrder(at: dir, children: ["sub: one"])
        let (notes, children) = readDirectoryOrder(at: dir)
        #expect(notes == names)
        #expect(children == ["sub: one"])
    }

    // MARK: - Awkward but legal files

    @Test func bodyIsWrittenToAFileThatEndsAtTheClosingDelimiter() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/x.md", "---\ntitle: X\n---")

        try vault.writeNoteBody(relativePath: "notes/x.md", text: "hello world", mode: .append)
        #expect(try read(vault, "notes/x.md").hasSuffix("\n---\n\nhello world\n"))
        try vault.writeNoteBody(relativePath: "notes/x.md", text: "replaced", mode: .replace)
        #expect(try read(vault, "notes/x.md").hasSuffix("\n---\n\nreplaced\n"))
        #expect(try vault.showNote(relativePath: "notes/x.md")?.title == "X")
    }

    @Test func dashesInsideABlockScalarDoNotEndTheFrontmatter() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/bs.md", "---\ntitle: BS\ndescription: |\n  line one\n  ---\n  line three\ntags: [keep]\n---\n\nold body\n")

        try vault.writeNoteBody(relativePath: "notes/bs.md", text: "NEW", mode: .replace)
        let content = try read(vault, "notes/bs.md")
        #expect(content.contains("description: |\n  line one\n  ---\n  line three\ntags: [keep]\n"))
        #expect(content.hasSuffix("---\n\nNEW\n"))
        let note = try #require(try vault.showNote(relativePath: "notes/bs.md"))
        #expect(note.title == "BS")
        #expect(note.tags == ["keep"])
    }

    @Test func proseBetweenTwoRulesIsNotFrontmatter() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = "---\nIntro prose, no frontmatter here.\n---\nRest of the note.\n"
        try write(vault, "notes/hr.md", original)

        #expect(splitFrontmatter(original).yaml == nil)
        #expect(try vault.showNote(relativePath: "notes/hr.md")?.body == original)

        try vault.writeNoteBody(relativePath: "notes/hr.md", text: "more", mode: .append)
        #expect(try read(vault, "notes/hr.md") == original + "\nmore\n")
    }

    @Test func quotedKeysAreEditedNotDuplicated() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/q.md", "---\n\"title\": Quoted Key\n\"updated\": 2024-01-01\n'tags': [a]\n---\n\nbody\n")

        try vault.writeNoteBody(relativePath: "notes/q.md", text: "more", mode: .append)
        let note = try vault.updateNoteMetadata(relativePath: "notes/q.md", changes: .init(set: [("title", "Renamed")], addTags: ["b"]))
        #expect(note.title == "Renamed")
        #expect(note.tags == ["a", "b"])
        let content = try read(vault, "notes/q.md")
        #expect(content.components(separatedBy: "updated").count == 2)
        #expect(content.components(separatedBy: "title").count == 2)
    }

    @Test func multiLineValuesAreReplacedWhole() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A flow sequence closed at column zero, and a comment between block-list items.
        try write(vault, "notes/flow.md", "---\ntitle: Flow\ntags: [\n  one,\n  two\n]\nseries: S\n---\n\nbody\n")
        try write(vault, "notes/comment.md", "---\ntitle: Comment\ntags:\n  - one\n# keep in mind\n  - two\n\n# about the series\nseries: S\n---\n\nbody\n")

        let flow = try vault.updateNoteMetadata(relativePath: "notes/flow.md", changes: .init(addTags: ["three"]))
        #expect(flow.tags == ["one", "two", "three"])
        #expect(flow.series == "S")
        #expect(try read(vault, "notes/flow.md").contains("title: Flow\ntags: [one, two, three]\nseries: S\n"))

        let comment = try vault.updateNoteMetadata(relativePath: "notes/comment.md", changes: .init(addTags: ["three"]))
        #expect(comment.tags == ["one", "two", "three"])
        // The comment above the next key stays with that key.
        #expect(try read(vault, "notes/comment.md").contains("tags: [one, two, three]\n\n# about the series\nseries: S\n"))
    }

    @Test func settingAndUnsettingTheSameFieldIsRejected() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = try vault.createNote(title: "Both", collection: "notes", body: nil).relativePath
        let before = try read(vault, path)

        #expect(throws: NoteError.self) {
            try vault.updateNoteMetadata(relativePath: path, changes: .init(set: [("series", "S")], unset: ["series"]))
        }
        #expect(try read(vault, path) == before)
    }

    @Test func crlfNoteStaysCRLFWhenAppendedTo() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/win.md", "---\r\ntitle: Win\r\n---\r\n\r\n- one\r\n- two\r\n")

        try vault.writeNoteBody(relativePath: "notes/win.md", text: "- three", mode: .append)
        let content = try read(vault, "notes/win.md")
        #expect(content.hasSuffix("---\r\n\r\n- one\r\n- two\r\n- three\r\n"))
        #expect(!content.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(try vault.showNote(relativePath: "notes/win.md")?.title == "Win")
    }

    @Test func noteTitledReadmeIsStillListed() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try vault.createNote(title: "README", collection: "notes", body: "important")
        #expect(created.relativePath == "notes/readme-note.md")
        #expect(try vault.allNotes().map(\.title) == ["README"])
    }

    @Test func indentedFrontmatterIsStillFrontmatter() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/t.md", "---\n  title: T\n  tags: [important]\n---\nBody\n")
        #expect(try vault.showNote(relativePath: "notes/t.md")?.title == "T")

        try vault.writeNoteBody(relativePath: "notes/t.md", text: "Replacement", mode: .replace)
        #expect(try read(vault, "notes/t.md") == "---\n  title: T\n  tags: [important]\n---\n\nReplacement\n")
        let note = try #require(try vault.showNote(relativePath: "notes/t.md"))
        #expect(note.title == "T")
        #expect(note.tags == ["important"])

        // A field can't be added in place here; the change is refused, not half-applied.
        #expect(throws: NoteError.self) {
            try vault.updateNoteMetadata(relativePath: "notes/t.md", changes: .init(set: [("series", "S")]))
        }
        #expect(try vault.showNote(relativePath: "notes/t.md")?.tags == ["important"])
    }

    @Test func addingAFieldLeavesAKeptBlockScalarAlone() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // `|+` keeps trailing blank lines as part of the value.
        let content = "---\ntitle: T\ndescription: |+\n  text\n\n\n---\n\nbody\n"
        try write(vault, "notes/keep.md", content)
        let before = try FrontmatterDocument(content).yaml()["description"] as? String

        try vault.updateNoteMetadata(relativePath: "notes/keep.md", changes: .init(set: [("series", "S")]))
        let after = try FrontmatterDocument(try read(vault, "notes/keep.md")).yaml()
        #expect(after["description"] as? String == before)
        #expect(after["series"] as? String == "S")
    }

    @Test func renamingANoteWithAMultiLineTitle() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(vault, "notes/ml.md", "---\ntitle: |\n  Old title\ntags: [important]\n---\n\nbody\n")

        vault.renameNote(relativePath: "notes/ml.md", newTitle: "2024")
        let note = try #require(try vault.showNote(relativePath: "notes/ml.md"))
        #expect(note.title == "2024")
        #expect(note.tags == ["important"])
        #expect(try read(vault, "notes/ml.md") == "---\ntitle: \"2024\"\ntags: [important]\n---\n\nbody\n")
    }

    @Test func noHeadingWithoutABodyWritesNoStub() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let created = try vault.createNote(title: "Bare", collection: "notes", body: nil, addHeading: false)
        #expect(try read(vault, created.relativePath).hasSuffix("\n---\n\n"))
        #expect(!(try read(vault, created.relativePath).contains("# Bare")))
    }

    @Test func kitCallsCannotLeaveTheVaultEither() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = tmp.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).md")
        let secret = "---\ntitle: Outside\n---\n\nsecret\n"
        try secret.write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escape = "../" + outside.lastPathComponent

        #expect(throws: NoteError.self) { try vault.writeNoteBody(relativePath: escape, text: "x", mode: .replace) }
        #expect(throws: NoteError.self) { try vault.replaceInNoteBody(relativePath: escape, find: "secret", replace: "x") }
        #expect(throws: NoteError.self) { try vault.updateNoteMetadata(relativePath: escape, changes: .init(set: [("title", "x")])) }
        #expect(throws: NoteError.self) { try vault.deleteNote(relativePath: escape, permanently: true) }
        #expect(throws: NoteError.self) { try vault.deleteNote(relativePath: outside.path, permanently: true) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == secret)
    }

    @Test func assetReferencesThatClimbOutAreIgnored() {
        let markdown = "![ok](_assets/pic.png) [bad](_assets/../../../outside.txt) ![also bad](_assets/a/../../b.png)"
        #expect(AssetManager.referencedAssets(in: markdown) == ["_assets/pic.png"])
    }

    @Test func movingANoteDoesNotCarryOffFilesOutsideTheVault() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = tmp.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "mine".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(atPath: vault.absolutePath(for: "notes/_assets"), withIntermediateDirectories: true)
        try write(vault, "notes/m.md", "---\ntitle: M\n---\n\n[file](_assets/../../../\(outside.lastPathComponent))\n")

        _ = try vault.moveNote(relativePath: "notes/m.md", toCollection: "archive")
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: vault.absolutePath(for: "archive/_assets/\(outside.lastPathComponent)")))
    }

    // MARK: - Paths on a real filesystem

    @Test func indexFileIsProtectedWhateverItsCase() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try vault.createNote(title: "A", collection: "notes", body: nil)

        for path in ["notes/_INDEX.md", "notes/_Index", "notes/_index.MD"] {
            #expect(throws: NoteError.self, "path: \(path)") { try vault.resolveNotePath(path) }
        }
        #expect(FileManager.default.fileExists(atPath: vault.absolutePath(for: "notes/_index.md")))
    }

    @Test func pathsAreSpelledAsOnDisk() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try vault.createNote(title: "My Note", collection: "notes", body: nil)
        // Only meaningful where the filesystem ignores case (the macOS default).
        guard FileManager.default.fileExists(atPath: vault.absolutePath(for: "NOTES/MY-NOTE.md")) else { return }

        #expect(try vault.resolveNotePath("Notes/My-Note.md") == "notes/my-note.md")
        #expect(try vault.resolveNotePath("NOTES/my-note") == "notes/my-note.md")
        #expect(try vault.normalizedCollectionPath("Notes") == "notes")
        #expect(try vault.normalizedCollectionPath("NOTES/new-sub") == "notes/new-sub")

        let created = try vault.createNote(title: "Second", collection: "Notes", body: nil)
        #expect(created.relativePath == "notes/second.md")
    }

    @Test func symlinkedFolderCannotLeadOutOfTheVault() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = tmp.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = "---\ntitle: Outside\n---\n\nsecret\n"
        try secret.write(to: outside.appendingPathComponent("o.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: vault.absolutePath(for: "notes/link"), withDestinationPath: outside.path)

        #expect(throws: NoteError.self) { try vault.resolveNotePath("notes/link/o.md") }
        #expect(throws: NoteError.self) {
            try vault.createNote(title: "Planted", collection: "notes/link", body: "x")
        }
        #expect(throws: NoteError.self) {
            try vault.createNote(title: "Planted", collection: "notes/link/deeper", body: "x", createCollection: true)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["o.md"])
        #expect(try String(contentsOf: outside.appendingPathComponent("o.md"), encoding: .utf8) == secret)
    }

    // MARK: - _index.md under stress

    @Test func duplicateOrderEntriesDoNotTrap() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = vault.absolutePath(for: "notes")
        try write(vault, "notes/_index.md", "---\norder:\n  - a.md\n  - b.md\n  - a.md\n---\n")

        struct Item { let name: String }
        let sorted = sortByOrder([Item(name: "b.md"), Item(name: "a.md")], order: readDirectoryOrder(at: dir).notes) { $0.name }
        #expect(sorted.map(\.name) == ["a.md", "b.md"])

        // Moving a note into a folder whose order still lists that filename leaves one entry.
        try write(vault, "other/c.md", "---\ntitle: C\n---\n")
        try write(vault, "notes/_index.md", "---\norder:\n  - c.md\n  - b.md\n---\n")
        _ = try vault.moveNote(relativePath: "other/c.md", toCollection: "notes")
        #expect(readDirectoryOrder(at: dir).notes == ["b.md", "c.md"])
    }

    @Test func unreadableIndexKeepsItsFieldsAndOrder() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // `title: Plans: 2026` is what older versions wrote; the frontmatter as a whole
        // no longer parses, but the lists do.
        try write(vault, "plans/_index.md", "---\ntitle: Plans: 2026\n# pinned first\norder:\n  - a.md\n  - b.md\nchildren:\n  - sub\nicon: star\n---\nAbout these plans.\n")
        try write(vault, "plans/a.md", "---\ntitle: A\n---\n")
        try write(vault, "plans/b.md", "---\ntitle: B\n---\n")
        let dir = vault.absolutePath(for: "plans")
        #expect(readDirectoryOrder(at: dir).notes == ["a.md", "b.md"])
        #expect(readDirectoryOrder(at: dir).children == ["sub"])

        _ = try vault.createNote(title: "C", collection: "plans", body: nil)
        #expect(readDirectoryOrder(at: dir).notes == ["a.md", "b.md", "c.md"])
        #expect(readDirectoryOrder(at: dir).children == ["sub"])
        #expect(try read(vault, "plans/_index.md") == "---\ntitle: Plans: 2026\n# pinned first\norder:\n  - a.md\n  - b.md\n  - c.md\nchildren:\n  - sub\nicon: star\n---\nAbout these plans.\n")
    }

    @Test func orderWritesLeaveOtherLinesAlone() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = vault.absolutePath(for: "notes")
        try write(vault, "notes/_index.md", "---\nicon: \"star\"   # chosen by hand\ntitle: 'Notes'\ncustom:\n  nested: [1, 2]\n---\n\nBody.\n")

        try writeDirectoryOrder(at: dir, notes: ["a.md", "b.md"])
        try writeDirectoryOrder(at: dir, children: ["sub"])
        try writeDirectoryOrder(at: dir, notes: ["b.md", "a.md"])
        #expect(try read(vault, "notes/_index.md") == "---\nicon: \"star\"   # chosen by hand\ntitle: 'Notes'\ncustom:\n  nested: [1, 2]\norder:\n  - b.md\n  - a.md\nchildren:\n  - sub\n---\n\nBody.\n")

        try writeDirectoryOrder(at: dir, notes: [], children: [])
        #expect(try read(vault, "notes/_index.md") == "---\nicon: \"star\"   # chosen by hand\ntitle: 'Notes'\ncustom:\n  nested: [1, 2]\n---\n\nBody.\n")

        // Clearing the order of a folder with no _index.md does not create one.
        let empty = vault.absolutePath(for: "empty")
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        try writeDirectoryOrder(at: empty, notes: [])
        #expect(!FileManager.default.fileExists(atPath: empty + "/_index.md"))
    }

    @Test func indexFrontmatterInOtherYAMLStylesSurvivesOrderWrites() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A flow mapping can't be edited line by line; it is regenerated from its values.
        try write(vault, "flow/_index.md", "---\n{title: Collection, order: [a.md]}\n---\nAbout.\n")
        try write(vault, "flow/a.md", "---\ntitle: A\n---\n")
        _ = try vault.createNote(title: "B", collection: "flow", body: nil)
        #expect(readDirectoryOrder(at: vault.absolutePath(for: "flow")).notes == ["a.md", "b.md"])
        let flow = FrontmatterDocument(try read(vault, "flow/_index.md"))
        #expect(try flow.yaml()["title"] as? String == "Collection")
        #expect(flow.body == "About.\n")

        // An explicit `? key` entry next to the list is not swallowed by the edit.
        try write(vault, "explicit/_index.md", "---\norder: [a.md]\n? description\n: keep me\ntitle: Collection\n---\n")
        try write(vault, "explicit/a.md", "---\ntitle: A\n---\n")
        _ = try vault.createNote(title: "B", collection: "explicit", body: nil)
        let explicit = try FrontmatterDocument(try read(vault, "explicit/_index.md")).yaml()
        #expect(explicit["description"] as? String == "keep me")
        #expect(explicit["title"] as? String == "Collection")
        #expect(readDirectoryOrder(at: vault.absolutePath(for: "explicit")).notes == ["a.md", "b.md"])

        // A key written twice: the write is what the next read returns.
        try write(vault, "twice/_index.md", "---\norder: [a.md]\ntitle: T\norder: [b.md]\n---\n")
        try writeDirectoryOrder(at: vault.absolutePath(for: "twice"), notes: ["b.md", "c.md"])
        #expect(readDirectoryOrder(at: vault.absolutePath(for: "twice")).notes == ["b.md", "c.md"])
        #expect(try read(vault, "twice/_index.md").components(separatedBy: "order:").count == 2)
    }

    // MARK: - Search index refresh

    @Test func refreshIndexesOnlyWhatChanged() throws {
        let (vault, tmp) = try makeVault()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try vault.createNote(title: "Alpha", collection: "notes", body: "about zebras").relativePath
        let b = try vault.createNote(title: "Beta", collection: "notes", body: "about otters").relativePath

        let index = try SearchIndex(vaultPath: vault.path)
        var stats = try index.refresh(from: vault)
        #expect(stats.added == 2)
        #expect(stats.total == 2)
        #expect(try index.search(query: "zebras").map(\.path) == [a])

        stats = try index.refresh(from: vault)
        #expect(stats.added == 0)
        #expect(stats.updated == 0)
        #expect(stats.deleted == 0)
        // The full-list path skips unchanged notes too.
        #expect(try index.buildIndex(notes: try vault.allNotes()).updated == 0)

        // Change one note (with a later mtime), add one, delete one.
        try vault.writeNoteBody(relativePath: a, text: "now about quokkas", mode: .replace)
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: vault.absolutePath(for: a))
        let c = try vault.createNote(title: "Gamma", collection: "notes", body: "about wombats").relativePath
        try vault.deleteNote(relativePath: b, permanently: true)

        stats = try index.refresh(from: vault)
        #expect(stats.added == 1)
        #expect(stats.updated == 1)
        #expect(stats.deleted == 1)
        #expect(try index.search(query: "quokkas").map(\.path) == [a])
        #expect(try index.search(query: "wombats").map(\.path) == [c])
        #expect(try index.search(query: "zebras").isEmpty)
        #expect(try index.search(query: "otters").isEmpty)

        // A file replaced by one with an *older* timestamp (restored, checked out) is re-read too.
        try vault.writeNoteBody(relativePath: c, text: "now about numbats", mode: .replace)
        let earlier = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: vault.absolutePath(for: c))
        #expect(try index.refresh(from: vault).updated == 1)
        #expect(try index.search(query: "numbats").map(\.path) == [c])
        #expect(try index.search(query: "wombats").isEmpty)
    }
}
