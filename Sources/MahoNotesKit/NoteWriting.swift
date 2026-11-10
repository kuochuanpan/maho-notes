import Foundation
import Yams

// Note-writing operations used by the `mn` CLI (and safe for the app to call):
// path resolution that cannot leave the vault, note creation with a body, body
// edits that leave frontmatter untouched, and validated metadata updates.

// MARK: - Errors

/// Errors from note-level operations. Each has a stable `code` for `--json` output.
public enum NoteError: Error, LocalizedError, Equatable {
    case invalidPath(String, reason: String)
    case noteNotFound(String, suggestions: [String])
    case noteExists(String)
    case emptyTitle
    case invalidCollection(String, reason: String)
    case collectionNotFound(String, available: [String])
    case invalidFrontmatter(path: String, detail: String)
    case unknownField(String, valid: [String])
    case managedField(String, reason: String)
    case invalidValue(field: String, value: String, expected: String)
    case textNotFound(path: String)
    case ambiguousText(path: String, count: Int)
    case unreadable(path: String, detail: String)

    /// Machine-readable identifier, stable across releases.
    public var code: String {
        switch self {
        case .invalidPath: return "invalid_path"
        case .noteNotFound: return "note_not_found"
        case .noteExists: return "note_exists"
        case .emptyTitle: return "empty_title"
        case .invalidCollection: return "invalid_collection"
        case .collectionNotFound: return "collection_not_found"
        case .invalidFrontmatter: return "invalid_frontmatter"
        case .unknownField: return "unknown_field"
        case .managedField: return "managed_field"
        case .invalidValue: return "invalid_value"
        case .textNotFound: return "text_not_found"
        case .ambiguousText: return "ambiguous_text"
        case .unreadable: return "unreadable_note"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path, reason):
            return "Invalid note path '\(path)': \(reason)"
        case let .noteNotFound(path, _):
            return "Note not found: \(path)"
        case let .noteExists(path):
            return "A note already exists at \(path)"
        case .emptyTitle:
            return "Note title is empty"
        case let .invalidCollection(collection, reason):
            return "Invalid collection '\(collection)': \(reason)"
        case let .collectionNotFound(collection, _):
            return "Collection not found: \(collection)"
        case let .invalidFrontmatter(path, detail):
            return "Frontmatter of \(path) is not valid YAML (\(detail))"
        case let .unknownField(field, _):
            return "Unknown frontmatter field '\(field)'"
        case let .managedField(field, reason):
            return "'\(field)' cannot be set: \(reason)"
        case let .invalidValue(field, value, expected):
            return "Invalid value '\(value)' for '\(field)': expected \(expected)"
        case let .textNotFound(path):
            return "Text to replace was not found in the body of \(path)"
        case let .ambiguousText(path, count):
            return "Text to replace occurs \(count) times in the body of \(path)"
        case let .unreadable(path, detail):
            return "Cannot read \(path): \(detail)"
        }
    }

    /// What to do next, when there is something specific to suggest.
    public var hint: String? {
        switch self {
        case let .noteNotFound(_, suggestions):
            return suggestions.isEmpty
                ? "Run `mn list` to see note paths."
                : "Did you mean one of the suggestions?"
        case .noteExists:
            return "Pass `--if-exists suffix` to create a second note, or `--if-exists skip` to reuse the existing one."
        case let .collectionNotFound(_, available):
            let list = available.isEmpty ? "none yet" : available.joined(separator: ", ")
            return "Existing collections: \(list). Pass `--create-collection` to create a new one."
        case let .unknownField(_, valid):
            return "Valid fields: \(valid.joined(separator: ", "))"
        case .textNotFound:
            return "The match is exact and case-sensitive, and only the body (not frontmatter) is searched. Check it with `mn show <path> --body-only`."
        case .ambiguousText:
            return "Include more surrounding text to make the match unique, or pass `--all` to replace every occurrence."
        case .invalidFrontmatter:
            return "Fix the note's frontmatter by hand, or set the broken field again with `mn meta <path> --set`."
        default:
            return nil
        }
    }

    /// Candidate note paths for a `noteNotFound` error.
    public var suggestions: [String] {
        if case let .noteNotFound(_, suggestions) = self { return suggestions }
        return []
    }
}

// MARK: - Options and results

/// What `createNote` does when the collection already has a note with the same filename.
public enum ExistingNotePolicy: String, Sendable, CaseIterable {
    /// Create `slug-1.md`, `slug-2.md`, … (the default; matches the app).
    case suffix
    /// Fail with `NoteError.noteExists`.
    case error
    /// Leave the existing note alone and return its path.
    case skip
}

public struct NoteCreation: Sendable, Equatable {
    /// Vault-relative path of the note.
    public let relativePath: String
    /// False when `ExistingNotePolicy.skip` returned an existing note.
    public let created: Bool
}

public enum NoteBodyWriteMode: String, Sendable {
    case replace
    case append
}

/// Frontmatter changes for `Vault.updateNoteMetadata`. Values are strings as typed
/// on the command line; they are validated and converted per field.
public struct NoteMetadataChanges: Sendable {
    public var set: [(field: String, value: String)]
    public var unset: [String]
    public var addTags: [String]
    public var removeTags: [String]

    public init(
        set: [(field: String, value: String)] = [],
        unset: [String] = [],
        addTags: [String] = [],
        removeTags: [String] = []
    ) {
        self.set = set
        self.unset = unset
        self.addTags = addTags
        self.removeTags = removeTags
    }

    public var isEmpty: Bool {
        self.set.isEmpty && unset.isEmpty && addTags.isEmpty && removeTags.isEmpty
    }

    /// Fields `set` accepts.
    public static let settableFields = ["author", "draft", "order", "public", "series", "slug", "title"]
}

// MARK: - Vault extension

extension Vault {

    // MARK: Paths

    /// Absolute path of a vault-relative path.
    public func absolutePath(for relativePath: String) -> String {
        (path as NSString).appendingPathComponent(relativePath)
    }

    /// Turn a path typed by a user or agent into the vault-relative path of an existing note.
    ///
    /// Accepts a vault-relative path with or without `.md`, a leading `./`, or an absolute
    /// path inside the vault. Rejects anything that leaves the vault, hidden files and
    /// `_index.md`. A path that does not exist throws `noteNotFound` with near matches.
    public func resolveNotePath(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NoteError.invalidPath(input, reason: "path is empty")
        }

        var relative: String
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let absolute = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
            let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard absolute.hasPrefix(root + "/") else {
                throw NoteError.invalidPath(input, reason: "path is outside the vault")
            }
            relative = String(absolute.dropFirst(root.count + 1))
        } else {
            relative = trimmed
        }

        var components: [String] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            guard component != ".." else {
                throw NoteError.invalidPath(input, reason: "path must stay inside the vault ('..' is not allowed)")
            }
            guard !component.hasPrefix(".") else {
                throw NoteError.invalidPath(input, reason: "hidden files are not notes")
            }
            components.append(component)
        }
        guard let last = components.last else {
            throw NoteError.invalidPath(input, reason: "path is empty")
        }
        func isIndexFile(_ name: String) -> Bool {
            // Case-insensitive: on APFS `_INDEX.md` opens the same file as `_index.md`.
            ["_index.md", "_index"].contains(name.lowercased())
        }
        guard !isIndexFile(last) else {
            throw NoteError.invalidPath(input, reason: "_index.md holds a collection's ordering, it is not a note")
        }
        relative = components.joined(separator: "/")

        let fm = FileManager.default
        let candidates = relative.lowercased().hasSuffix(".md") ? [relative] : [relative + ".md", relative]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: absolutePath(for: candidate), isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                throw NoteError.invalidPath(input, reason: "that is a collection, not a note")
            }
            // Spell the path the way the disk does, so `Notes/A.md` and `notes/a.md`
            // are the same note everywhere (ordering, search index, results).
            let actual = canonicalPath(candidate)
            guard actual.hasSuffix(".md"), !isIndexFile((actual as NSString).lastPathComponent) else {
                throw NoteError.invalidPath(input, reason: "notes are .md files")
            }
            guard isInsideVault(actual) else {
                throw NoteError.invalidPath(input, reason: "path leads outside the vault through a symbolic link")
            }
            return actual
        }
        throw NoteError.noteNotFound(input, suggestions: noteSuggestions(for: relative))
    }

    /// A vault-relative path with each existing component spelled as it is on disk.
    /// Components that don't exist yet are kept as typed.
    func canonicalPath(_ relativePath: String) -> String {
        func fold(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
        let fm = FileManager.default
        var directory = path
        var result: [String] = []
        for component in relativePath.split(separator: "/").map(String.init) {
            var actual = component
            if let names = try? fm.contentsOfDirectory(atPath: directory), !names.contains(component) {
                let matches = names.filter { fold($0) == fold(component) }
                if matches.count == 1 { actual = matches[0] }
            }
            result.append(actual)
            directory = (directory as NSString).appendingPathComponent(actual)
        }
        return result.joined(separator: "/")
    }

    /// Whether a vault-relative path, with symbolic links followed, is still inside the vault.
    /// For a path that doesn't exist yet, its deepest existing folder is checked.
    func isInsideVault(_ relativePath: String) -> Bool {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        var probe = relativePath
        while !probe.isEmpty, !fm.fileExists(atPath: absolutePath(for: probe)) {
            probe = (probe as NSString).deletingLastPathComponent
        }
        if probe.isEmpty { return true }
        let resolved = URL(fileURLWithPath: absolutePath(for: probe)).standardizedFileURL.resolvingSymlinksInPath().path
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    /// Existing notes that a mistyped path most likely meant, best first.
    public func noteSuggestions(for input: String, limit: Int = 5) -> [String] {
        guard let files = try? allNoteFiles() else { return [] }
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        let all = files.map { file -> String in
            let standardized = URL(fileURLWithPath: file).standardizedFileURL.path
            return standardized.hasPrefix(root + "/") ? String(standardized.dropFirst(root.count + 1)) : file
        }

        func stem(_ value: String) -> String {
            let name = (value as NSString).lastPathComponent.lowercased()
            return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        }
        let wanted = stem(input)
        guard !wanted.isEmpty else { return [] }
        let wantedSlug = makeSlug(from: wanted)

        // Same filename in another collection first, then names containing the input,
        // then names within a couple of typos of it.
        var exact: [String] = []
        var containing: [String] = []
        var typos: [(distance: Int, path: String)] = []
        let allowedDistance = max(1, min(3, wanted.count / 4))
        for candidate in all {
            let name = stem(candidate)
            if name == wanted || (!wantedSlug.isEmpty && name == wantedSlug) {
                exact.append(candidate)
            } else if name.contains(wanted) || wanted.contains(name)
                        || (!wantedSlug.isEmpty && name.contains(wantedSlug)) {
                containing.append(candidate)
            } else if abs(name.count - wanted.count) <= allowedDistance {
                let distance = Self.editDistance(name, wanted)
                if distance <= allowedDistance { typos.append((distance, candidate)) }
            }
        }
        let fuzzy = typos.sorted { $0.distance < $1.distance }.map(\.path)
        return Array((exact + containing + fuzzy).prefix(limit))
    }

    /// Levenshtein distance between two short strings.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Check a collection path typed by a user: relative, inside the vault, no hidden
    /// or `_`-prefixed components (those are reserved for assets and site output).
    /// Returns the normalized path (no leading, trailing or doubled slashes).
    public func normalizedCollectionPath(_ collection: String) throws -> String {
        let trimmed = collection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NoteError.invalidCollection(collection, reason: "collection is empty")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw NoteError.invalidCollection(collection, reason: "use a path relative to the vault, such as 'notes' or 'notes/drafts'")
        }
        var components: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            guard component != ".." else {
                throw NoteError.invalidCollection(collection, reason: "collection must stay inside the vault ('..' is not allowed)")
            }
            guard !component.hasPrefix("."), !component.hasPrefix("_") else {
                throw NoteError.invalidCollection(collection, reason: "names starting with '.' or '_' are reserved")
            }
            guard !component.contains("\n"), !component.contains("\0") else {
                throw NoteError.invalidCollection(collection, reason: "name contains characters a folder can't have")
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            throw NoteError.invalidCollection(collection, reason: "collection is empty")
        }
        // Spelled as on disk, so `Notes` and `notes` name the same collection.
        let normalized = canonicalPath(components.joined(separator: "/"))
        guard isInsideVault(normalized) else {
            throw NoteError.invalidCollection(collection, reason: "collection leads outside the vault through a symbolic link")
        }
        return normalized
    }

    /// Top-level collection ids, for error messages.
    private func topLevelCollectionIds() -> [String] {
        ((try? collections()) ?? []).map(\.id)
    }

    // MARK: Create

    /// Create a note, optionally with its body, in one step.
    ///
    /// - Parameters:
    ///   - title: Display title. Line breaks are collapsed; an empty title throws.
    ///   - collection: Collection path relative to the vault (`notes`, `notes/drafts`).
    ///   - body: Markdown body. Nil writes the `# Title` stub the app's editor starts from.
    ///   - addHeading: When the body does not open with a level-1 heading, put `# Title` above it.
    ///   - ifExists: What to do when a note with the same filename is already in the collection.
    ///   - createCollection: Create the collection when it is missing (a new top-level one is
    ///     also added to `maho.yaml`). When false a missing collection throws `collectionNotFound`,
    ///     so a typo cannot quietly start a new collection.
    public func createNote(
        title: String,
        collection: String,
        tags: [String] = [],
        author: String? = nil,
        series: String? = nil,
        isPublic: Bool = false,
        body: String?,
        addHeading: Bool = true,
        ifExists: ExistingNotePolicy = .suffix,
        createCollection: Bool = false
    ) throws -> NoteCreation {
        let cleanTitle = title
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleanTitle.isEmpty else { throw NoteError.emptyTitle }

        let collectionPath = try normalizedCollectionPath(collection)
        let collectionDir = absolutePath(for: collectionPath)
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: collectionDir, isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue {
            throw NoteError.invalidCollection(collection, reason: "a file with that name is in the way")
        }
        if !exists {
            guard createCollection else {
                throw NoteError.collectionNotFound(collectionPath, available: topLevelCollectionIds())
            }
            try fm.createDirectory(atPath: collectionDir, withIntermediateDirectories: true)
            // A new top-level collection is listed in maho.yaml, like one made in the app.
            let topLevel = String(collectionPath.split(separator: "/")[0])
            let mahoYaml = absolutePath(for: "maho.yaml")
            if fm.fileExists(atPath: mahoYaml),
               !((try? loadCollections(from: path)) ?? []).contains(where: { $0.id == topLevel }) {
                try? addCollection(vaultPath: path, id: topLevel, name: topLevel)
            }
        }

        // Filename: the title's slug, never empty or hidden, short enough for any filesystem.
        var slug = makeSlug(from: cleanTitle)
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.utf8.count > 200 { slug.removeLast() }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "untitled" }
        // `readme.md` is skipped when notes are listed, so a note titled "README" needs another name.
        if slug == "readme" { slug = "readme-note" }

        var filename = "\(slug).md"
        var filePath = (collectionDir as NSString).appendingPathComponent(filename)
        if fm.fileExists(atPath: filePath) {
            switch ifExists {
            case .error:
                throw NoteError.noteExists("\(collectionPath)/\(filename)")
            case .skip:
                return NoteCreation(relativePath: "\(collectionPath)/\(filename)", created: false)
            case .suffix:
                var counter = 1
                repeat {
                    filename = "\(slug)-\(counter).md"
                    filePath = (collectionDir as NSString).appendingPathComponent(filename)
                    counter += 1
                } while fm.fileExists(atPath: filePath)
            }
        }

        let now = noteTimestamp()
        let cleanTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var frontmatter = [
            "title: \(YAMLFormat.scalar(cleanTitle))",
            "tags: \(YAMLFormat.flowSequence(cleanTags))",
            "created: \(now)",
            "updated: \(now)",
            "public: \(isPublic)",
        ]
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            frontmatter.append("author: \(YAMLFormat.scalar(author))")
        }
        if let series = series?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            frontmatter.append("series: \(YAMLFormat.scalar(series))")
        }

        let bodyText: String
        if let body {
            var text = body.trimmingCharacters(in: .newlines)
            let opensWithHeading = text
                .components(separatedBy: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                .hasPrefix("# ") ?? false
            if addHeading && !opensWithHeading {
                text = text.isEmpty ? "# \(cleanTitle)\n" : "# \(cleanTitle)\n\n\(text)"
            }
            bodyText = text.isEmpty ? "" : text + "\n"
        } else {
            bodyText = addHeading ? "# \(cleanTitle)\n\n" : ""
        }

        let content = "---\n" + frontmatter.joined(separator: "\n") + "\n---\n\n" + bodyText
        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        // Append to the collection's order unless it is already listed.
        let (existingOrder, _) = readDirectoryOrder(at: collectionDir)
        if !existingOrder.contains(filename) {
            try writeDirectoryOrder(at: collectionDir, notes: existingOrder + [filename])
        }

        return NoteCreation(relativePath: "\(collectionPath)/\(filename)", created: true)
    }

    // MARK: Body

    /// Refuse a path that is absolute or climbs out of the vault. The CLI resolves what the
    /// user typed with `resolveNotePath`; this covers code that calls the Kit directly.
    private func requireInsideVault(_ relativePath: String) throws {
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~"),
              !relativePath.split(separator: "/").contains("..") else {
            throw NoteError.invalidPath(relativePath, reason: "path must be relative to the vault and stay inside it")
        }
        guard isInsideVault(relativePath) else {
            throw NoteError.invalidPath(relativePath, reason: "path leads outside the vault through a symbolic link")
        }
    }

    private func readNoteFile(_ relativePath: String) throws -> String {
        try requireInsideVault(relativePath)
        do {
            return try String(contentsOfFile: absolutePath(for: relativePath), encoding: .utf8)
        } catch {
            throw NoteError.unreadable(path: relativePath, detail: error.localizedDescription)
        }
    }

    private func writeNoteFile(_ document: FrontmatterDocument, to relativePath: String) throws {
        try document.rendered().write(toFile: absolutePath(for: relativePath), atomically: true, encoding: .utf8)
    }

    /// Replace a note's body, or append to it. Frontmatter is left as it is except for `updated`.
    ///
    /// Appended text starts a new paragraph, unless the body ends in a list item or table row
    /// and the text starts with one — then it continues that list or table on the next line.
    public func writeNoteBody(relativePath: String, text: String, mode: NoteBodyWriteMode) throws {
        var document = FrontmatterDocument(try readNoteFile(relativePath))
        // Work in `\n` and convert at the end, so a CRLF note stays CRLF throughout.
        let usesCRLF = document.usesCRLF || document.body.contains("\r\n")
        let incoming = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        let current = document.body.replacingOccurrences(of: "\r\n", with: "\n")
        var newBody = current

        switch mode {
        case .replace:
            newBody = incoming.isEmpty ? "" : incoming + "\n"
            // Keep the blank line that separates frontmatter from the body.
            if document.hasFrontmatter, !newBody.isEmpty { newBody = "\n" + newBody }
        case .append:
            guard !incoming.isEmpty else { break }
            let existing = String(current.reversed().drop(while: { $0.isWhitespace }).reversed())
            if existing.isEmpty {
                newBody = (document.hasFrontmatter ? "\n" : "") + incoming + "\n"
            } else {
                let lastLine = existing.components(separatedBy: "\n").last ?? ""
                let firstLine = incoming.components(separatedBy: "\n").first ?? ""
                let continues = (Self.isListItem(lastLine) && Self.isListItem(firstLine))
                    || (Self.isTableRow(lastLine) && Self.isTableRow(firstLine))
                newBody = existing + (continues ? "\n" : "\n\n") + incoming + "\n"
            }
        }

        document.body = usesCRLF ? newBody.replacingOccurrences(of: "\n", with: "\r\n") : newBody
        Self.bumpUpdated(&document)
        try writeNoteFile(document, to: relativePath)
    }

    /// Set `updated` to now — unless that would turn readable frontmatter into unreadable
    /// frontmatter (the key written in a form the line editor doesn't recognise, giving a
    /// duplicate). A stale timestamp is better than a note that lost its metadata.
    private static func bumpUpdated(_ document: inout FrontmatterDocument) {
        guard document.hasFrontmatter else { return }
        var bumped = document
        bumped.setRaw("updated", noteTimestamp())
        if (try? document.yaml()) != nil, (try? bumped.yaml()) == nil { return }
        document = bumped
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^\s*([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    /// Replace exact text in a note's body (frontmatter is never searched or changed).
    ///
    /// - Parameter all: Replace every occurrence. When false the text must occur exactly once.
    /// - Returns: The number of replacements made.
    @discardableResult
    public func replaceInNoteBody(relativePath: String, find: String, replace: String, all: Bool = false) throws -> Int {
        guard !find.isEmpty else {
            throw NoteError.invalidValue(field: "find", value: "", expected: "non-empty text")
        }
        var document = FrontmatterDocument(try readNoteFile(relativePath))
        let count = document.body.components(separatedBy: find).count - 1
        guard count > 0 else { throw NoteError.textNotFound(path: relativePath) }
        guard count == 1 || all else { throw NoteError.ambiguousText(path: relativePath, count: count) }

        document.body = document.body.replacingOccurrences(of: find, with: replace)
        Self.bumpUpdated(&document)
        try writeNoteFile(document, to: relativePath)
        return count
    }

    // MARK: Metadata

    /// Apply frontmatter changes to a note and return the note as it now parses.
    ///
    /// Only the changed keys are rewritten. The result is parsed and checked before anything
    /// is written, so a change that would leave the frontmatter unreadable throws instead.
    @discardableResult
    public func updateNoteMetadata(relativePath: String, changes: NoteMetadataChanges) throws -> Note {
        var document = FrontmatterDocument(try readNoteFile(relativePath))

        // Validate everything before touching the document.
        enum Value { case string(String), bool(Bool), int(Int) }
        var assignments: [(field: String, value: Value)] = []
        for (field, raw) in changes.set {
            try Self.checkSettable(field)
            switch field {
            case "public", "draft":
                switch raw.lowercased() {
                case "true": assignments.append((field, .bool(true)))
                case "false": assignments.append((field, .bool(false)))
                default: throw NoteError.invalidValue(field: field, value: raw, expected: "true or false")
                }
            case "order":
                guard let number = Int(raw.trimmingCharacters(in: .whitespaces)) else {
                    throw NoteError.invalidValue(field: field, value: raw, expected: "a whole number")
                }
                assignments.append((field, .int(number)))
            default:
                let text = raw
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard !text.isEmpty else {
                    throw NoteError.invalidValue(field: field, value: raw, expected: "non-empty text (use --unset to remove a field)")
                }
                assignments.append((field, .string(text)))
            }
        }
        for field in changes.unset {
            try Self.checkSettable(field)
            if let clash = changes.set.first(where: { $0.field == field }) {
                throw NoteError.invalidValue(field: field, value: clash.value, expected: "either --set or --unset for a field, not both")
            }
            guard field != "title" else {
                throw NoteError.managedField("title", reason: "a note needs a title; set a new one instead")
            }
        }

        let addTags = changes.addTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let removeTags = changes.removeTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let bad = addTags.first(where: { $0.contains("\n") || $0.contains("\r") }) {
            throw NoteError.invalidValue(field: "tags", value: bad, expected: "a single-line tag")
        }

        var expectedTags: [String]?
        if !addTags.isEmpty || !removeTags.isEmpty {
            // Editing tags needs the current list, so the frontmatter has to be readable.
            let current: [String: Any]
            do {
                current = try document.yaml()
            } catch let FrontmatterError.invalidYAML(detail) {
                throw NoteError.invalidFrontmatter(path: relativePath, detail: detail)
            }
            var tags = Self.tagList(from: current["tags"])
            for tag in addTags where !tags.contains(tag) { tags.append(tag) }
            tags.removeAll { removeTags.contains($0) }
            document.set("tags", strings: tags)
            expectedTags = tags
        }

        for (field, value) in assignments {
            switch value {
            case .string(let text): document.set(field, string: text)
            case .bool(let flag): document.set(field, bool: flag)
            case .int(let number): document.set(field, int: number)
            }
        }
        for field in changes.unset {
            document.remove(field)
        }
        document.setRaw("updated", noteTimestamp())

        // Read the result back before writing it.
        let result: [String: Any]
        do {
            result = try document.yaml()
        } catch let FrontmatterError.invalidYAML(detail) {
            throw NoteError.invalidFrontmatter(path: relativePath, detail: detail)
        }
        for (field, value) in assignments {
            let matches: Bool
            switch value {
            case .string(let text): matches = result[field] as? String == text
            case .bool(let flag): matches = result[field] as? Bool == flag
            case .int(let number): matches = result[field] as? Int == number
            }
            guard matches else {
                throw NoteError.invalidFrontmatter(path: relativePath, detail: "'\(field)' did not read back as written")
            }
        }
        if let expectedTags, Self.tagList(from: result["tags"]) != expectedTags {
            throw NoteError.invalidFrontmatter(path: relativePath, detail: "'tags' did not read back as written")
        }
        for field in changes.unset where result[field] != nil {
            throw NoteError.invalidFrontmatter(path: relativePath, detail: "'\(field)' could not be removed")
        }

        try writeNoteFile(document, to: relativePath)

        let filePath = absolutePath(for: relativePath)
        guard let note = try parseNote(at: filePath, relativeTo: path) else {
            throw NoteError.unreadable(path: relativePath, detail: "note could not be parsed after the update")
        }
        return note
    }

    private static func checkSettable(_ field: String) throws {
        switch field {
        case "collection":
            throw NoteError.managedField(field, reason: "a note's collection is its folder; move the note with `mn move` instead")
        case "tags":
            throw NoteError.managedField(field, reason: "use --add-tag / --remove-tag")
        case "created", "updated":
            throw NoteError.managedField(field, reason: "timestamps are managed automatically")
        default:
            guard NoteMetadataChanges.settableFields.contains(field) else {
                throw NoteError.unknownField(field, valid: NoteMetadataChanges.settableFields)
            }
        }
    }

    private static func tagList(from value: Any?) -> [String] {
        if let array = value as? [String] { return array }
        if let array = value as? [Any] { return array.map { "\($0)" } }
        if let string = value as? String {
            return string.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    // MARK: Delete

    /// Delete a note and drop it from its collection's `_index.md` order.
    ///
    /// - Parameter permanently: Remove the file outright. When false the note goes to the
    ///   Trash on macOS (other platforms have no Trash for this and remove the file).
    /// - Returns: True when the note was moved to the Trash, false when it was removed.
    @discardableResult
    public func deleteNote(relativePath: String, permanently: Bool = false) throws -> Bool {
        try requireInsideVault(relativePath)
        let filePath = absolutePath(for: relativePath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else {
            throw NoteError.noteNotFound(relativePath, suggestions: [])
        }

        var trashed = false
        #if os(macOS)
        if !permanently {
            try fm.trashItem(at: URL(fileURLWithPath: filePath), resultingItemURL: nil)
            trashed = true
        }
        #endif
        if !trashed {
            try fm.removeItem(atPath: filePath)
        }

        let filename = (relativePath as NSString).lastPathComponent
        let directory = absolutePath(for: (relativePath as NSString).deletingLastPathComponent)
        let (order, _) = readDirectoryOrder(at: directory)
        if order.contains(filename) {
            try? writeDirectoryOrder(at: directory, notes: order.filter { $0 != filename })
        }
        return trashed
    }
}
