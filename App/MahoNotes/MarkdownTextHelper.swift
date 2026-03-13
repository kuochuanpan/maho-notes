import Foundation

/// Pure text-manipulation helpers for markdown formatting.
/// All methods are pure functions: (text, selectedRange) → (newText, newSelectedRange).
enum MarkdownTextHelper {

    struct Result {
        let text: String
        let selectedRange: NSRange
    }

    // MARK: - Wrap Selection

    /// Wraps the selected text with prefix/suffix (e.g. `**bold**`).
    /// If there's a selection, wraps it and keeps the selection on the inner text.
    /// If no selection (cursor), inserts empty wrapper and places cursor between.
    static func wrapSelection(
        text: String,
        selectedRange: NSRange,
        prefix: String,
        suffix: String
    ) -> Result {
        let nsText = text as NSString
        let selected = nsText.substring(with: selectedRange)

        // Check if already wrapped — if so, unwrap
        let beforeStart = selectedRange.location - prefix.count
        let afterEnd = selectedRange.location + selectedRange.length
        if beforeStart >= 0 && afterEnd + suffix.count <= nsText.length {
            let beforeText = nsText.substring(with: NSRange(location: beforeStart, length: prefix.count))
            let afterText = nsText.substring(with: NSRange(location: afterEnd, length: suffix.count))
            if beforeText == prefix && afterText == suffix {
                // Unwrap: remove prefix and suffix
                let fullRange = NSRange(location: beforeStart, length: prefix.count + selectedRange.length + suffix.count)
                let newText = nsText.replacingCharacters(in: fullRange, with: selected)
                let newRange = NSRange(location: beforeStart, length: selected.count)
                return Result(text: newText, selectedRange: newRange)
            }
        }

        let replacement = prefix + selected + suffix
        let newText = nsText.replacingCharacters(in: selectedRange, with: replacement)

        if selectedRange.length == 0 {
            // No selection: place cursor between prefix and suffix
            let cursorPos = selectedRange.location + prefix.count
            return Result(text: newText, selectedRange: NSRange(location: cursorPos, length: 0))
        } else {
            // Has selection: select the inner text
            let newRange = NSRange(location: selectedRange.location + prefix.count, length: selected.count)
            return Result(text: newText, selectedRange: newRange)
        }
    }

    // MARK: - Toggle Line Prefix

    /// Adds or removes a prefix at the start of the line containing the cursor/selection.
    /// The prefix should include trailing space (e.g. `"- "`, `"> "`).
    static func toggleLinePrefix(
        text: String,
        selectedRange: NSRange,
        prefix: String
    ) -> Result {
        let nsText = text as NSString

        // Find line start
        let lineRange = nsText.lineRange(for: selectedRange)
        let line = nsText.substring(with: lineRange)

        if line.hasPrefix(prefix) {
            // Remove prefix
            let newLine = String(line.dropFirst(prefix.count))
            let newText = nsText.replacingCharacters(in: lineRange, with: newLine)
            let newCursor = max(selectedRange.location - prefix.count, lineRange.location)
            let newLength = max(0, selectedRange.length - max(0, prefix.count - (selectedRange.location - lineRange.location)))
            return Result(text: newText, selectedRange: NSRange(location: newCursor, length: max(0, min(newLength, selectedRange.length))))
        } else {
            // Remove any other conflicting line prefix before adding
            let stripped = stripLinePrefix(line)
            let newLine = prefix + stripped.text
            let newText = nsText.replacingCharacters(in: lineRange, with: newLine)
            let offset = prefix.count - stripped.removedCount
            let newCursor = selectedRange.location + offset
            return Result(text: newText, selectedRange: NSRange(location: max(lineRange.location, newCursor), length: selectedRange.length))
        }
    }

    // MARK: - Cycle Heading

    /// Cycles heading level: no heading → # → ## → ### → remove.
    static func cycleHeading(text: String, selectedRange: NSRange) -> Result {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: selectedRange)
        let line = nsText.substring(with: lineRange)

        // Determine current heading level
        let trimmed = line.drop(while: { $0 == "#" })
        let hashCount = line.count - trimmed.count

        let newLine: String
        let prefixDelta: Int

        if hashCount == 0 {
            // No heading → add #
            let stripped = stripLinePrefix(line)
            newLine = "# " + stripped.text
            prefixDelta = 2 - stripped.removedCount
        } else if hashCount < 3 {
            // Add one more #
            let body = String(trimmed.drop(while: { $0 == " " }))
            let newPrefix = String(repeating: "#", count: hashCount + 1) + " "
            newLine = newPrefix + body
            prefixDelta = newPrefix.count - (hashCount + (trimmed.first == " " ? 1 : 0))
        } else {
            // ### → remove heading
            let body = String(trimmed.drop(while: { $0 == " " }))
            newLine = body
            prefixDelta = -(hashCount + (trimmed.first == " " ? 1 : 0))
        }

        let newText = nsText.replacingCharacters(in: lineRange, with: newLine)
        let newCursor = max(lineRange.location, selectedRange.location + prefixDelta)
        return Result(text: newText, selectedRange: NSRange(location: newCursor, length: selectedRange.length))
    }

    // MARK: - Insert Link

    /// Inserts `[selected](url)` or `[](url)` if no selection.
    /// With selection: `[hello](│)` — cursor in URL position.
    /// Without: `[│](url)` — cursor in label position.
    static func insertLink(text: String, selectedRange: NSRange) -> Result {
        let nsText = text as NSString
        let selected = nsText.substring(with: selectedRange)

        if selectedRange.length == 0 {
            let insertion = "[](url)"
            let newText = nsText.replacingCharacters(in: selectedRange, with: insertion)
            // Cursor inside []
            let cursorPos = selectedRange.location + 1
            return Result(text: newText, selectedRange: NSRange(location: cursorPos, length: 0))
        } else {
            let insertion = "[\(selected)]()"
            let newText = nsText.replacingCharacters(in: selectedRange, with: insertion)
            // Cursor inside ()
            let cursorPos = selectedRange.location + 1 + selected.count + 2
            return Result(text: newText, selectedRange: NSRange(location: cursorPos, length: 0))
        }
    }

    // MARK: - Insert Ruby

    /// Inserts `{selected|reading}` or `{|reading}` if no selection.
    /// With selection: `{hello|│}` — cursor in reading position.
    /// Without: `{│|reading}` — cursor in kanji position.
    static func insertRuby(text: String, selectedRange: NSRange) -> Result {
        let nsText = text as NSString
        let selected = nsText.substring(with: selectedRange)

        if selectedRange.length == 0 {
            let insertion = "{|reading}"
            let newText = nsText.replacingCharacters(in: selectedRange, with: insertion)
            // Cursor inside {} before |
            let cursorPos = selectedRange.location + 1
            return Result(text: newText, selectedRange: NSRange(location: cursorPos, length: 0))
        } else {
            let insertion = "{\(selected)|}"
            let newText = nsText.replacingCharacters(in: selectedRange, with: insertion)
            // Cursor after |
            let cursorPos = selectedRange.location + 1 + selected.count + 1
            return Result(text: newText, selectedRange: NSRange(location: cursorPos, length: 0))
        }
    }

    // MARK: - Apply Action

    /// Apply a toolbar action to the given text and selection.
    /// Returns nil for complex actions (table, photo, file) that need UI.
    static func applyAction(
        _ action: MarkdownToolbarAction,
        text: String,
        selectedRange: NSRange
    ) -> Result? {
        switch action {
        case .bold:
            return wrapSelection(text: text, selectedRange: selectedRange, prefix: "**", suffix: "**")
        case .italic:
            return wrapSelection(text: text, selectedRange: selectedRange, prefix: "*", suffix: "*")
        case .strikethrough:
            return wrapSelection(text: text, selectedRange: selectedRange, prefix: "~~", suffix: "~~")
        case .code:
            return wrapSelection(text: text, selectedRange: selectedRange, prefix: "`", suffix: "`")
        case .heading:
            return cycleHeading(text: text, selectedRange: selectedRange)
        case .quote:
            return toggleLinePrefix(text: text, selectedRange: selectedRange, prefix: "> ")
        case .bulletList:
            return toggleLinePrefix(text: text, selectedRange: selectedRange, prefix: "- ")
        case .numberedList:
            return toggleLinePrefix(text: text, selectedRange: selectedRange, prefix: "1. ")
        case .checkbox:
            return toggleLinePrefix(text: text, selectedRange: selectedRange, prefix: "- [ ] ")
        case .link:
            return insertLink(text: text, selectedRange: selectedRange)
        case .ruby:
            return insertRuby(text: text, selectedRange: selectedRange)
        case .table, .insertPhoto, .insertFile:
            return nil // Complex actions need dedicated UI
        }
    }

    // MARK: - Private Helpers

    /// Strips known line prefixes (list markers, quotes, checkboxes, headings).
    /// Returns the stripped text and how many characters were removed.
    private static func stripLinePrefix(_ line: String) -> (text: String, removedCount: Int) {
        let prefixes = ["- [ ] ", "- [x] ", "- ", "1. ", "> "]
        for p in prefixes {
            if line.hasPrefix(p) {
                return (String(line.dropFirst(p.count)), p.count)
            }
        }
        // Also strip heading prefixes
        let trimmed = line.drop(while: { $0 == "#" })
        let hashCount = line.count - trimmed.count
        if hashCount > 0 {
            let body = String(trimmed.drop(while: { $0 == " " }))
            return (body, hashCount + (trimmed.first == " " ? 1 : 0))
        }
        return (line, 0)
    }
}
