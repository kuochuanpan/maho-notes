import Testing
import Foundation
@testable import MahoNotesKit

@Suite("CollectionIndexMerge")
struct CollectionIndexMergeTests {

    private func index(title: String = "Plans", order: [String], children: [String] = [], extra: String = "", body: String = "") -> String {
        var text = "---\ntitle: \(title)\n\(extra)"
        if !order.isEmpty {
            text += "order:\n" + order.map { "  - \($0)\n" }.joined()
        }
        if !children.isEmpty {
            text += "children:\n" + children.map { "  - \($0)\n" }.joined()
        }
        return text + "---\n" + body
    }

    private func merged(_ outcome: CollectionIndexMerge.Outcome, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        guard case .merged(let text) = outcome else {
            Issue.record("expected a merge, got \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return text
    }

    private func order(in text: String?, key: String = "order") -> [String] {
        guard let text, let yaml = try? FrontmatterDocument(text).yaml() else { return [] }
        return (yaml[key] as? [Any])?.map { "\($0)" } ?? []
    }

    // MARK: Lists

    @Test func concurrentAdditionsOfDifferentNotesKeepBoth() {
        let base = index(order: ["a.md", "b.md"])
        let local = index(order: ["a.md", "b.md", "c.md"])
        let remote = index(order: ["a.md", "b.md", "d.md"])

        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        #expect(order(in: result) == ["a.md", "b.md", "c.md", "d.md"])
        // Deterministic: the same inputs give the same file.
        #expect(result == merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote)))
    }

    @Test func sameNoteAddedOnBothSidesIsListedOnce() {
        let base = index(order: ["a.md"])
        let local = index(order: ["a.md", "x.md"])
        let remote = index(order: ["x.md", "a.md"])
        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        #expect(order(in: result).sorted() == ["a.md", "x.md"])
    }

    @Test func additionVersusReorderKeepsTheReorderAndTheNewNote() {
        let base = index(order: ["a.md", "b.md", "c.md"])
        let local = index(order: ["c.md", "a.md", "b.md"])            // reordered here
        let remote = index(order: ["a.md", "b.md", "c.md", "d.md"])   // d added after c elsewhere

        let result = order(in: merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote)))
        #expect(result.filter { $0 != "d.md" } == ["c.md", "a.md", "b.md"])
        #expect(result.firstIndex(of: "d.md") == result.firstIndex(of: "c.md").map { $0 + 1 })
    }

    @Test func removalVersusAdditionDoesNotBringBackTheRemovedNote() {
        let base = index(order: ["a.md", "b.md"])
        let local = index(order: ["a.md"])                    // b removed here
        let remote = index(order: ["a.md", "b.md", "c.md"])   // c added elsewhere
        #expect(order(in: merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))) == ["a.md", "c.md"])
        // And the other way round.
        #expect(order(in: merged(CollectionIndexMerge.merge(base: base, local: remote, remote: local))) == ["a.md", "c.md"])
    }

    @Test func removalOfTheLastEntriesRemovesTheKey() {
        let base = index(order: ["a.md", "b.md"])
        let local = index(order: ["a.md"])
        let remote = index(order: ["b.md"])
        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        #expect(order(in: result).isEmpty)
        #expect(result?.contains("order:") == false)
    }

    @Test func contradictoryReordersAreAConflict() {
        let base = index(order: ["a.md", "b.md", "c.md"])
        let local = index(order: ["b.md", "a.md", "c.md"])
        let remote = index(order: ["a.md", "c.md", "b.md"])
        guard case .conflict = CollectionIndexMerge.merge(base: base, local: local, remote: remote) else {
            Issue.record("expected a conflict")
            return
        }
    }

    @Test func sameReorderOnBothSidesMerges() {
        let base = index(order: ["a.md", "b.md", "c.md"])
        let local = index(order: ["c.md", "b.md", "a.md", "l.md"])
        let remote = index(order: ["c.md", "b.md", "a.md", "r.md"])
        #expect(order(in: merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote)))
                == ["c.md", "b.md", "a.md", "l.md", "r.md"])
    }

    @Test func nestedChildrenOrderMergesLikeNotes() {
        let base = index(order: ["a.md"], children: ["x", "y"])
        let local = index(order: ["a.md"], children: ["x", "y", "z"])
        let remote = index(order: ["a.md", "b.md"], children: ["y"])     // x removed, b added
        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        #expect(order(in: result) == ["a.md", "b.md"])
        #expect(order(in: result, key: "children") == ["y", "z"])
    }

    // MARK: Other fields

    @Test func independentFieldChangesMerge() {
        let base = index(order: ["a.md"], extra: "description: Old\nicon: folder\n")
        let local = index(order: ["a.md", "c.md"], extra: "description: Old\nicon: star\n")
        let remote = index(title: "Plans: 2027", order: ["a.md"], extra: "description: |\n  New text\n  two lines\nicon: folder\n")
            .replacingOccurrences(of: "title: Plans: 2027", with: "title: \"Plans: 2027\"")

        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        let yaml = try? FrontmatterDocument(result ?? "").yaml()
        #expect(yaml?["title"] as? String == "Plans: 2027")
        #expect(yaml?["description"] as? String == "New text\ntwo lines\n")
        #expect(yaml?["icon"] as? String == "star")
        #expect(order(in: result) == ["a.md", "c.md"])
    }

    @Test func fieldRemovedOnOneSideStaysRemoved() {
        let base = index(order: ["a.md"], extra: "description: Old\n")
        let local = index(order: ["a.md", "b.md"], extra: "description: Old\n")
        let remote = index(order: ["a.md"])
        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        #expect(result?.contains("description") == false)
        #expect(order(in: result) == ["a.md", "b.md"])
    }

    @Test func sameFieldChangedDifferentlyIsAConflict() {
        let base = index(order: ["a.md"])
        let local = index(title: "Local", order: ["a.md"])
        let remote = index(title: "Remote", order: ["a.md", "b.md"])
        guard case .conflict(let reason) = CollectionIndexMerge.merge(base: base, local: local, remote: remote) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(reason.contains("title"))
    }

    @Test func bodyMergesWhenOnlyOneSideChangedIt() {
        let base = index(order: ["a.md"], body: "About this collection.\n")
        let local = index(order: ["a.md", "b.md"], body: "About this collection.\n")
        let remote = index(order: ["a.md"], body: "Rewritten.\n")
        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        #expect(result?.hasSuffix("---\nRewritten.\n") == true)

        let bothChanged = index(order: ["a.md", "b.md"], body: "Mine.\n")
        guard case .conflict = CollectionIndexMerge.merge(base: base, local: bothChanged, remote: remote) else {
            Issue.record("expected a conflict")
            return
        }
    }

    // MARK: Limits

    @Test func oneSidedChangeIsTakenAsIs() {
        let base = index(order: ["a.md"])
        let changed = index(order: ["b.md", "a.md"])
        #expect(CollectionIndexMerge.merge(base: base, local: base, remote: changed) == .merged(changed))
        #expect(CollectionIndexMerge.merge(base: base, local: changed, remote: base) == .merged(changed))
        #expect(CollectionIndexMerge.merge(base: nil, local: changed, remote: changed) == .merged(changed))
    }

    @Test func withoutABaseDifferentVersionsAreAConflict() {
        // No way to tell an addition from a removal: do not guess by uniting the lists.
        let local = index(order: ["a.md", "b.md"])
        let remote = index(order: ["a.md"])
        guard case .conflict = CollectionIndexMerge.merge(base: nil, local: local, remote: remote) else {
            Issue.record("expected a conflict")
            return
        }
    }

    @Test func unreadableFrontmatterIsAConflictNotAGuess() {
        let base = index(order: ["a.md"])
        let local = "---\ntitle: Plans: 2027\norder:\n  - a.md\n  - b.md\n---\n"   // invalid YAML
        let remote = index(order: ["a.md", "c.md"])
        guard case .conflict = CollectionIndexMerge.merge(base: base, local: local, remote: remote) else {
            Issue.record("expected a conflict")
            return
        }
    }

    @Test func mergeIsStableWhenRepeated() {
        // After a merge is pushed, merging the result again with either input changes nothing:
        // a second sync must not produce new conflicts or reorder the list.
        let base = index(order: ["a.md", "b.md"])
        let local = index(order: ["a.md", "b.md", "c.md"])
        let remote = index(order: ["b.md", "a.md", "d.md"])
        guard let once = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote)) else { return }
        #expect(CollectionIndexMerge.merge(base: base, local: once, remote: remote) == .merged(once))
        #expect(CollectionIndexMerge.merge(base: remote, local: once, remote: remote) == .merged(once))
    }

    @Test func untouchedLinesSurviveByteForByte() {
        let base = "---\ntitle: Plans\n# keep me\nicon: folder   \norder:\n  - a.md\n---\n\nBody\n"
        let local = base.replacingOccurrences(of: "  - a.md\n", with: "  - a.md\n  - c.md\n")
        let remote = base.replacingOccurrences(of: "  - a.md\n", with: "  - a.md\n  - d.md\n")
        let result = merged(CollectionIndexMerge.merge(base: base, local: local, remote: remote))
        #expect(result == "---\ntitle: Plans\n# keep me\nicon: folder   \norder:\n  - a.md\n  - c.md\n  - d.md\n---\n\nBody\n")
    }

    @Test func conflictCopyPaths() {
        #expect(isConflictCopyPath("notes/hello.conflict-Mahos-Mac.md"))
        #expect(isConflictCopyPath("notes/_index.conflict-2026-11-10T08-00-00Z-local.md"))
        #expect(!isConflictCopyPath("notes/hello.md"))
        #expect(!isConflictCopyPath("a.conflict-x/hello.md"))
    }
}
