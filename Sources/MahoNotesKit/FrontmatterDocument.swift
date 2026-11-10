import Foundation
import Yams

// MARK: - YAML value formatting

/// Formats values for hand-written YAML frontmatter.
///
/// Frontmatter is written line by line (not dumped through Yams) so key order,
/// comments and untouched lines survive an edit. That only works if every value
/// written is valid YAML on its own — a title like `Plan: Q4` or a tag like `c#`
/// must be quoted, and `2024` or `true` must be quoted to stay a string.
public enum YAMLFormat {
    /// A string as a single-line YAML scalar: plain when that reads back as the
    /// same string, double-quoted otherwise.
    public static func scalar(_ value: String) -> String {
        isPlainSafe(value) ? value : quoted(value)
    }

    /// A list of strings as a single-line flow sequence: `[a, "b, c"]`.
    public static func flowSequence(_ items: [String]) -> String {
        let parts = items.map { item -> String in
            guard isPlainSafe(item),
                  let loaded = try? Yams.load(yaml: "k: [\(item)]") as? [String: Any],
                  let array = loaded["k"] as? [String], array == [item]
            else { return quoted(item) }
            return item
        }
        return "[" + parts.joined(separator: ", ") + "]"
    }

    /// A double-quoted YAML scalar with every special character escaped.
    public static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{85}": out += "\\N"
            case "\u{2028}": out += "\\L"
            case "\u{2029}": out += "\\P"
            case "\u{FEFF}": out += "\\uFEFF"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// True when `value`, written bare after `key: `, loads back as the same string.
    private static func isPlainSafe(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F || $0 == "\u{85}" || $0 == "\u{2028}" || $0 == "\u{2029}"
              }),
              let loaded = try? Yams.load(yaml: "k: \(value)") as? [String: Any],
              loaded.count == 1,
              let string = loaded["k"] as? String
        else { return false }
        return string == value
    }
}

/// Timestamp for `created:` / `updated:` frontmatter fields, e.g. `2026-11-10T09:30:00+08:00`.
///
/// Uses a fixed POSIX locale: a `DateFormatter` with only a format string follows the
/// user's calendar, so a Buddhist or Japanese calendar setting would write year 2569 or 8.
public func noteTimestamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
    return formatter.string(from: date)
}

// MARK: - Frontmatter location

/// Line indexes of the opening and closing `---` delimiters, or nil when the
/// content has no frontmatter block. Shared by `splitFrontmatter` and
/// `FrontmatterDocument` so both always agree on where frontmatter ends.
func locateFrontmatter(in lines: [String], content: String) -> (open: Int, close: Int)? {
    guard content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") else { return nil }
    func isDelimiter(_ line: String) -> Bool {
        // `\r` is trimmed too, so notes saved with CRLF line endings still parse.
        line.trimmingCharacters(in: frontmatterDelimiterTrim) == "---"
    }
    // The closing delimiter starts at column zero. An indented `---` is content — for
    // example a line of a `description: |` block — and must not end the frontmatter.
    guard let open = lines.firstIndex(where: isDelimiter),
          open + 1 < lines.count,
          let close = lines[(open + 1)...].firstIndex(where: { $0.hasPrefix("---") && isDelimiter($0) })
    else { return nil }

    // A note with no frontmatter can open with a `---` rule and have another further down.
    // The text between them is frontmatter only if it starts like YAML: a `key:` line,
    // a comment, or a flow mapping. Otherwise the whole file is body.
    if let first = lines[(open + 1)..<close].first(where: {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
        // Leading whitespace is dropped first: a mapping indented as a whole is still YAML.
        let start = String(first.drop(while: { $0 == " " || $0 == "\t" }))
        guard start.hasPrefix("#") || start.hasPrefix("{") || isTopLevelYAMLKeyLine(start) else { return nil }
    }
    return (open, close)
}

private let frontmatterDelimiterTrim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))

/// True for a line that starts a top-level mapping entry: `key: value`, `key:`, `"key": value`.
func isTopLevelYAMLKeyLine(_ line: String) -> Bool {
    line.range(of: topLevelKeyPattern, options: .regularExpression) != nil
}

// Second alternative: an explicit `? key` entry, whose value follows on a `: value` line.
private let topLevelKeyPattern = #"^(("[^"]*"|'[^']*'|[^\s\-#\[\]{},&*!|>%@`"'?:][^:]*?)[ \t]*:([ \t\r]|$)|\?([ \t\r]|$))"#

// MARK: - FrontmatterDocument

public enum FrontmatterError: Error, LocalizedError, Equatable {
    /// The frontmatter block is not a YAML mapping (after an edit, or before one that needs to read it).
    case invalidYAML(String)

    public var errorDescription: String? {
        switch self {
        case .invalidYAML(let detail): return "Frontmatter is not valid YAML: \(detail)"
        }
    }
}

/// A markdown file split into frontmatter lines and body, editable one key at a time.
///
/// Editing replaces only the lines of the key being changed (including a multi-line
/// value such as a block list) and leaves every other line byte-for-byte as it was.
/// `rendered()` puts the file back together without dropping or adding blank lines.
public struct FrontmatterDocument: Sendable {
    /// YAML lines between the two `---` delimiters.
    public private(set) var lines: [String]
    /// Everything after the closing delimiter's line break.
    public var body: String
    /// Whether the file has (or, after a `set`, will have) a frontmatter block.
    public private(set) var hasFrontmatter: Bool

    /// Text before the opening delimiter (a BOM, blank lines), kept as-is.
    private let leading: String
    /// The two delimiter lines exactly as written (`---`, possibly with trailing spaces or `\r`).
    private let openDelimiter: String
    private let closeDelimiter: String
    /// False only when the closing delimiter was the very last thing in the file.
    private let hasBodySeparator: Bool
    /// True when the file uses CRLF line endings; lines written by an edit match.
    public let usesCRLF: Bool

    public init(_ content: String) {
        var text = content
        var prefix = ""
        if text.hasPrefix("\u{FEFF}") {
            prefix = "\u{FEFF}"
            text.removeFirst()
        }
        let all = text.components(separatedBy: "\n")
        if let (open, close) = locateFrontmatter(in: all, content: text) {
            leading = prefix + all[..<open].map { $0 + "\n" }.joined()
            lines = Array(all[(open + 1)..<close])
            body = all[(close + 1)...].joined(separator: "\n")
            hasBodySeparator = close + 1 < all.count
            hasFrontmatter = true
            usesCRLF = all[open].hasSuffix("\r")
            openDelimiter = all[open]
            closeDelimiter = all[close]
        } else {
            openDelimiter = "---"
            closeDelimiter = "---"
            leading = prefix
            lines = []
            body = text
            hasBodySeparator = true
            hasFrontmatter = false
            usesCRLF = false
        }
    }

    /// The frontmatter parsed as a YAML mapping. An empty block is an empty mapping.
    public func yaml() throws -> [String: Any] {
        // With the line break that precedes the closing delimiter: it is part of the YAML,
        // and a trailing block scalar's value depends on it.
        let text = lines.joined(separator: "\n") + "\n"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: text)
        } catch {
            throw FrontmatterError.invalidYAML("\(error)")
        }
        guard let dict = loaded as? [String: Any] else {
            throw FrontmatterError.invalidYAML("expected `key: value` lines")
        }
        return dict
    }

    // MARK: Editing

    public mutating func set(_ key: String, string value: String) {
        setRaw(key, YAMLFormat.scalar(value))
    }

    public mutating func set(_ key: String, bool value: Bool) {
        setRaw(key, value ? "true" : "false")
    }

    public mutating func set(_ key: String, int value: Int) {
        setRaw(key, String(value))
    }

    public mutating func set(_ key: String, strings value: [String]) {
        setRaw(key, YAMLFormat.flowSequence(value))
    }

    /// Set `key` to a value that is already formatted as single-line YAML.
    public mutating func setRaw(_ key: String, _ rawValue: String) {
        replaceBlock(of: key, with: ["\(key): \(rawValue)"])
    }

    /// Set `key` to a block list, one `  - item` line per entry.
    public mutating func set(_ key: String, blockList items: [String]) {
        replaceBlock(of: key, with: ["\(key):"] + items.map { "  - \(YAMLFormat.scalar($0))" })
    }

    /// Set `key` to an entry copied from another document: its lines exactly as written there
    /// (see `rawBlock(of:)`), so a block scalar or a comment inside a list survives.
    mutating func setBlock(_ key: String, rawLines: [String]) {
        // Line endings are normalised to this file's by `replaceBlock`.
        replaceBlock(of: key, with: rawLines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 })
    }

    private mutating func replaceBlock(of key: String, with newLines: [String]) {
        let newLines = usesCRLF ? newLines.map { $0 + "\r" } : newLines
        if !hasFrontmatter, !body.isEmpty, !body.hasPrefix("\n") {
            // First key of a file that had no frontmatter: keep a blank line before the body.
            body = "\n" + body
        }
        if let range = blockRange(of: key) {
            lines.replaceSubrange(range, with: newLines)
            // A key written twice: keep the entry just written as the only one, so the
            // change is what the next read sees whichever duplicate the parser prefers.
            removeBlocks(of: key, after: range.lowerBound + newLines.count)
        } else {
            // At the very end: inserting above trailing blank lines could cut them off a
            // block scalar (`description: |+`) they belong to.
            lines.append(contentsOf: newLines)
        }
        hasFrontmatter = true
    }

    private mutating func removeBlocks(of key: String, after index: Int) {
        var searchFrom = index
        while searchFrom < lines.count,
              let start = lines[searchFrom...].firstIndex(where: { Self.line($0, startsKey: key) }) {
            let range = blockRange(startingAt: start)
            lines.removeSubrange(range)
            searchFrom = start
        }
    }

    /// Remove `key` and its value. Returns false when the key was not present.
    @discardableResult
    public mutating func remove(_ key: String) -> Bool {
        guard let range = blockRange(of: key) else { return false }
        lines.removeSubrange(range)
        removeBlocks(of: key, after: range.lowerBound)
        return true
    }

    /// Lines occupied by a top-level key: its own line and everything up to the next
    /// top-level key — a block list, a block scalar, a flow sequence spread over several
    /// lines, comments between list items. Blank lines and comments that sit directly above
    /// the next key are left out; they belong with that key.
    private func blockRange(of key: String) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { Self.line($0, startsKey: key) }) else { return nil }
        return blockRange(startingAt: start)
    }

    private func blockRange(startingAt start: Int) -> Range<Int> {
        var end = lines[(start + 1)...].firstIndex(where: isTopLevelYAMLKeyLine) ?? lines.count
        while end > start + 1 {
            let previous = lines[end - 1]
            guard previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || previous.hasPrefix("#") else { break }
            end -= 1
        }
        return start..<end
    }

    /// The lines of `key`'s entry as written in the file, or nil when the key is absent.
    public func rawBlock(of key: String) -> [String]? {
        blockRange(of: key).map { Array(lines[$0]) }
    }

    /// Whether `line` is the first line of `key`'s entry. The key may be quoted in the file.
    private static func line(_ line: String, startsKey key: String) -> Bool {
        for spelling in [key, "\"\(key)\"", "'\(key)'"] where line.hasPrefix(spelling) {
            let rest = line.dropFirst(spelling.count).drop(while: { $0 == " " || $0 == "\t" })
            guard rest.first == ":" else { continue }
            let after = rest.dropFirst()
            if after.isEmpty || after.first == " " || after.first == "\t" || after.first == "\r" {
                return true
            }
        }
        return false
    }

    // MARK: Rendering

    /// The whole file. A document that was never edited renders to its original text.
    public func rendered() -> String {
        guard hasFrontmatter else { return leading + body }
        var out = leading + openDelimiter + "\n"
        if !lines.isEmpty {
            out += lines.joined(separator: "\n") + "\n"
        }
        out += closeDelimiter
        // A file that ended at the closing delimiter has no line break after it — unless a
        // body has been written since.
        if hasBodySeparator || !body.isEmpty {
            out += "\n" + body
        }
        return out
    }
}
