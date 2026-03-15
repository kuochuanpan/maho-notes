@preconcurrency import Markdown
import Foundation

/// Converts a Markdown string to HTML using swift-markdown
public struct MarkdownHTMLRenderer: Sendable {
    public init() {}

    public func render(_ markdown: String) -> String {
        let withRubyPlaceholders = preprocessRubyAnnotations(markdown)
        let withFootnotes = preprocessFootnotes(withRubyPlaceholders)
        let preprocessed = preprocessMath(withFootnotes.body)
        let document = Document(parsing: preprocessed, options: [.parseBlockDirectives, .parseSymbolLinks])
        var visitor = HTMLVisitor()
        let html = visitor.visit(document)
        return postprocessFootnotes(html, definitions: withFootnotes.definitions)
    }

    /// Replace ruby annotations {base|reading} with placeholders before markdown parsing.
    /// This prevents the `|` inside ruby syntax from being interpreted as a table column separator.
    private func preprocessRubyAnnotations(_ text: String) -> String {
        // Match {base|annotation} — base and annotation must not contain } or {
        let pattern = try! NSRegularExpression(pattern: "\\{([^|{}]+)\\|([^{}]+)\\}", options: [])
        let nsRange = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = pattern.matches(in: result, range: nsRange)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let baseRange = Range(match.range(at: 1), in: result),
                  let annotRange = Range(match.range(at: 2), in: result) else { continue }
            let base = String(result[baseRange])
            let annotation = String(result[annotRange])
            let encoded = Data("\(base)\t\(annotation)".utf8).base64EncodedString()
            result.replaceSubrange(range, with: "<!--RUBY:\(encoded)-->")
        }
        return result
    }

    /// Extract math blocks before markdown parsing to avoid interference
    private func preprocessMath(_ text: String) -> String {
        var result = text

        // Replace display math $$...$$ with placeholder
        let displayPattern = try! NSRegularExpression(pattern: "\\$\\$([\\s\\S]*?)\\$\\$", options: [])
        let nsRange = NSRange(result.startIndex..., in: result)
        let displayMatches = displayPattern.matches(in: result, range: nsRange)
        for match in displayMatches.reversed() {
            guard let range = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else { continue }
            let content = String(result[contentRange])
            let encoded = encodeMathContent(content)
            result.replaceSubrange(range, with: "<!--MATH_BLOCK:\(encoded)-->")
        }

        // Replace inline math $...$ (not $$)
        let inlinePattern = try! NSRegularExpression(pattern: "(?<!\\$)\\$(?!\\$)(.+?)(?<!\\$)\\$(?!\\$)", options: [])
        let nsRange2 = NSRange(result.startIndex..., in: result)
        let inlineMatches = inlinePattern.matches(in: result, range: nsRange2)
        for match in inlineMatches.reversed() {
            guard let range = Range(match.range, in: result),
                  let contentRange = Range(match.range(at: 1), in: result) else { continue }
            let content = String(result[contentRange])
            let encoded = encodeMathContent(content)
            result.replaceSubrange(range, with: "<!--MATH_INLINE:\(encoded)-->")
        }

        return result
    }

    /// Result of footnote preprocessing — body with placeholders + collected definitions.
    struct FootnoteResult {
        let body: String
        let definitions: [(id: String, content: String)]
    }

    /// Extract footnote definitions `[^id]: content` and replace references `[^id]` with placeholders.
    /// Definitions are removed from the body and collected for postprocessing.
    private func preprocessFootnotes(_ text: String) -> FootnoteResult {
        var lines = text.components(separatedBy: "\n")
        var definitions: [(id: String, content: String)] = []
        var definitionIds: Set<String> = []

        // Pass 1: Extract footnote definitions (lines starting with [^id]: )
        // Also handle multi-line definitions (continuation lines indented with 2+ spaces)
        let defPattern = try! NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:\s*(.*)$"#, options: [])
        var filteredLines: [String] = []
        var currentDefId: String? = nil
        var currentDefContent: String = ""

        for line in lines {
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = defPattern.firstMatch(in: line, range: nsRange),
               let idRange = Range(match.range(at: 1), in: line),
               let contentRange = Range(match.range(at: 2), in: line) {
                // Save previous definition if any
                if let prevId = currentDefId {
                    definitions.append((id: prevId, content: currentDefContent.trimmingCharacters(in: .whitespacesAndNewlines)))
                    definitionIds.insert(prevId)
                }
                currentDefId = String(line[idRange])
                currentDefContent = String(line[contentRange])
            } else if currentDefId != nil && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                // Continuation line for multi-line footnote
                currentDefContent += "\n" + line.trimmingCharacters(in: .init(charactersIn: " \t"))
            } else {
                // Save previous definition if any
                if let prevId = currentDefId {
                    definitions.append((id: prevId, content: currentDefContent.trimmingCharacters(in: .whitespacesAndNewlines)))
                    definitionIds.insert(prevId)
                    currentDefId = nil
                    currentDefContent = ""
                }
                filteredLines.append(line)
            }
        }
        // Don't forget the last definition
        if let prevId = currentDefId {
            definitions.append((id: prevId, content: currentDefContent.trimmingCharacters(in: .whitespacesAndNewlines)))
            definitionIds.insert(prevId)
        }

        guard !definitions.isEmpty else {
            return FootnoteResult(body: text, definitions: [])
        }

        // Pass 2: Replace footnote references [^id] with placeholders
        var body = filteredLines.joined(separator: "\n")
        let refPattern = try! NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#, options: [])
        let nsRange = NSRange(body.startIndex..., in: body)
        let matches = refPattern.matches(in: body, range: nsRange)
        for match in matches.reversed() {
            guard let range = Range(match.range, in: body),
                  let idRange = Range(match.range(at: 1), in: body) else { continue }
            let id = String(body[idRange])
            // Only replace if this id has a definition
            if definitionIds.contains(id) {
                let encoded = Data(id.utf8).base64EncodedString()
                body.replaceSubrange(range, with: "<!--FNREF:\(encoded)-->")
            }
        }

        return FootnoteResult(body: body, definitions: definitions)
    }

    /// Post-process HTML to convert footnote placeholders into proper HTML footnotes.
    private func postprocessFootnotes(_ html: String, definitions: [(id: String, content: String)]) -> String {
        guard !definitions.isEmpty else { return html }

        var result = html
        // Build ordered list of referenced footnotes (in order of appearance)
        var orderedIds: [String] = []
        var idToNumber: [String: Int] = [:]

        // Find all FNREF placeholders in order and assign numbers
        let refPattern = try! NSRegularExpression(
            pattern: "(?:&lt;!--|<!--)FNREF:([A-Za-z0-9+/=]+)(?:--&gt;|-->)",
            options: []
        )
        let nsRange = NSRange(result.startIndex..., in: result)
        let matches = refPattern.matches(in: result, range: nsRange)

        for match in matches {
            guard let encodedRange = Range(match.range(at: 1), in: result) else { continue }
            let encoded = String(result[encodedRange])
            guard let data = Data(base64Encoded: encoded),
                  let id = String(data: data, encoding: .utf8) else { continue }
            if idToNumber[id] == nil {
                orderedIds.append(id)
                idToNumber[id] = orderedIds.count
            }
        }

        // Replace FNREF placeholders with superscript links
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let encodedRange = Range(match.range(at: 1), in: result) else { continue }
            let encoded = String(result[encodedRange])
            guard let data = Data(base64Encoded: encoded),
                  let id = String(data: data, encoding: .utf8),
                  let num = idToNumber[id] else { continue }
            let sup = "<sup class=\"footnote-ref\"><a href=\"#fn-\(escapeHTML(id))\" id=\"fnref-\(escapeHTML(id))\">\(num)</a></sup>"
            result.replaceSubrange(range, with: sup)
        }

        // Build footnotes section at the end
        let defMap = Dictionary(definitions.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
        var footnotesHTML = "<section class=\"footnotes\"><hr><ol>\n"
        for id in orderedIds {
            let content = defMap[id] ?? ""
            let renderedContent = escapeHTML(content)
            footnotesHTML += "<li id=\"fn-\(escapeHTML(id))\">\(renderedContent) <a href=\"#fnref-\(escapeHTML(id))\" class=\"footnote-backref\">↩</a></li>\n"
        }
        footnotesHTML += "</ol></section>\n"

        // Insert before </body> if present, otherwise append
        if let bodyEnd = result.range(of: "</body>") {
            result.insert(contentsOf: footnotesHTML, at: bodyEnd.lowerBound)
        } else {
            result += footnotesHTML
        }

        return result
    }

    /// Post-process HTML to restore math placeholders
    static func postprocessMath(_ html: String) -> String {
        var result = html

        // Match both escaped (&lt;!--) and raw (<!--) variants
        for prefix in ["&lt;!--", "<!--"] {
            let suffix = prefix == "&lt;!--" ? "--&gt;" : "-->"

            // Display math
            let displayPattern = try! NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: prefix) + "MATH_BLOCK:([A-Za-z0-9+/=]+)" + NSRegularExpression.escapedPattern(for: suffix),
                options: []
            )
            var nsRange = NSRange(result.startIndex..., in: result)
            var matches = displayPattern.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let contentRange = Range(match.range(at: 1), in: result) else { continue }
                let content = decodeMathContent(String(result[contentRange]))
                result.replaceSubrange(range, with: "<div class=\"math-block\">$$\(content)$$</div>")
            }

            // Inline math
            let inlinePattern = try! NSRegularExpression(
                pattern: NSRegularExpression.escapedPattern(for: prefix) + "MATH_INLINE:([A-Za-z0-9+/=]+)" + NSRegularExpression.escapedPattern(for: suffix),
                options: []
            )
            nsRange = NSRange(result.startIndex..., in: result)
            matches = inlinePattern.matches(in: result, range: nsRange)
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let contentRange = Range(match.range(at: 1), in: result) else { continue }
                let content = decodeMathContent(String(result[contentRange]))
                result.replaceSubrange(range, with: "<span class=\"math-inline\">$\(content)$</span>")
            }
        }

        return result
    }
}

// MARK: - Checkbox Toggle

extension MarkdownHTMLRenderer {
    /// Toggle the Nth task-list checkbox in a markdown string.
    ///
    /// Matches `- [ ]`, `- [x]`, `* [ ]`, `+ [x]`, `1. [ ]`, etc.
    /// Returns the updated markdown, or the original string if the index is out of range.
    public static func toggleCheckbox(at index: Int, checked: Bool, in markdown: String) -> String {
        // Pattern: list marker followed by [ ] or [x]/[X]
        let pattern = #"(?m)^(\s*(?:[-*+]|\d+[.)]) +)\[([ xX])\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
        let nsRange = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, range: nsRange)
        guard index >= 0 && index < matches.count else { return markdown }

        let match = matches[index]
        // Range of the checkbox character (the space or x between [ and ])
        guard let checkRange = Range(match.range(at: 2), in: markdown) else { return markdown }

        var result = markdown
        result.replaceSubrange(checkRange, with: checked ? "x" : " ")
        return result
    }
}

// MARK: - HTML Escaping

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func unescapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// Encode math content as base64 to avoid newline issues in HTML comments
private func encodeMathContent(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

/// Decode base64-encoded math content
private func decodeMathContent(_ encoded: String) -> String {
    guard let data = Data(base64Encoded: encoded),
          let text = String(data: data, encoding: .utf8) else { return encoded }
    return text
}

/// Process highlight markup: ==text== -> <mark>text</mark>
func processHighlight(_ text: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "==(.+?)==", options: [])
    let nsRange = NSRange(text.startIndex..., in: text)
    var result = text
    let matches = pattern.matches(in: text, range: nsRange)
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result),
              let contentRange = Range(match.range(at: 1), in: result) else { continue }
        let content = String(result[contentRange])
        result.replaceSubrange(range, with: "<mark>\(content)</mark>")
    }
    return result
}

/// Restore ruby annotation placeholders (<!--RUBY:base64-->) to <ruby> HTML.
/// Used in visitText and visitInlineHTML to convert preprocessed placeholders.
func restoreRubyPlaceholders(_ text: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "<!--RUBY:([A-Za-z0-9+/=]+)-->", options: [])
    let nsRange = NSRange(text.startIndex..., in: text)
    var result = text
    let matches = pattern.matches(in: result, range: nsRange)
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result),
              let encodedRange = Range(match.range(at: 1), in: result) else { continue }
        let encoded = String(result[encodedRange])
        if let data = Data(base64Encoded: encoded),
           let decoded = String(data: data, encoding: .utf8) {
            let parts = decoded.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 {
                let base = escapeHTML(String(parts[0]))
                let annotation = escapeHTML(String(parts[1]))
                result.replaceSubrange(range, with: "<ruby><rb>\(base)</rb><rp>(</rp><rt>\(annotation)</rt><rp>)</rp></ruby>")
            }
        }
    }
    return result
}

// MARK: - MarkupVisitor

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    // Track if we're inside a blockquote to detect admonitions
    private var insideBlockquote = false
    private var blockquoteContent = ""

    /// Sequential index for task list checkboxes — used by interactive toggle in preview mode.
    private var checkboxIndex = 0

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        let html = document.children.map { visit($0) }.joined()
        return MarkdownHTMLRenderer.postprocessMath(html)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = heading.level
        let content = heading.children.map { visit($0) }.joined()
        return "<h\(level)>\(content)</h\(level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let content = paragraph.children.map { visit($0) }.joined()
        return "<p>\(content)</p>\n"
    }

    mutating func visitText(_ text: Markdown.Text) -> String {
        let escaped = escapeHTML(text.string)
        let withRuby = restoreRubyPlaceholders(escaped)
        return processHighlight(withRuby)
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        let content = strong.children.map { visit($0) }.joined()
        return "<strong>\(content)</strong>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        let content = emphasis.children.map { visit($0) }.joined()
        return "<em>\(content)</em>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        let content = strikethrough.children.map { visit($0) }.joined()
        return "<del>\(content)</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        return "<code>\(escapeHTML(inlineCode.code))</code>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let code = escapeHTML(codeBlock.code)
        let lang = codeBlock.language ?? ""

        if lang.lowercased() == "mermaid" {
            return "<div class=\"mermaid\">\(codeBlock.code)</div>\n"
        }

        let langAttr = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
        return "<pre><code\(langAttr)>\(code)</code></pre>\n"
    }

    mutating func visitLink(_ link: Markdown.Link) -> String {
        let content = link.children.map { visit($0) }.joined()
        let dest = link.destination ?? ""
        return "<a href=\"\(escapeHTML(dest))\">\(content)</a>"
    }

    mutating func visitImage(_ image: Markdown.Image) -> String {
        let rawAlt = image.children.map { visit($0) }.joined()
        let src = image.source ?? ""

        // Parse custom attributes: ![alt|alignment|width](url)
        let parts = rawAlt.split(separator: "|", maxSplits: 3).map { $0.trimmingCharacters(in: .whitespaces) }
        let alt = parts.first ?? rawAlt
        var alignment: String? = nil
        var width: String? = nil

        for part in parts.dropFirst() {
            let lower = part.lowercased()
            if lower == "left" || lower == "right" || lower == "center" {
                alignment = lower
            } else if lower.hasSuffix("%") || lower.hasSuffix("px") {
                width = part
            }
        }

        // No custom attributes → simple img tag (backward compatible)
        guard alignment != nil || width != nil else {
            return "<img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(alt))\">"
        }

        let align = alignment ?? "center"
        let cssClass = "img-\(align)"
        let styleAttr = width.map { " style=\"width:\($0)\"" } ?? ""
        return "<figure class=\"\(cssClass)\"\(styleAttr)><img src=\"\(escapeHTML(src))\" alt=\"\(escapeHTML(alt))\"></figure>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        // Check for admonition pattern: first paragraph starts with [!type]
        if let firstPara = blockQuote.children.first(where: { $0 is Paragraph }) as? Paragraph {
            let firstText = firstPara.children.compactMap { $0 as? Markdown.Text }.first?.string ?? ""
            let admonitionPattern = try! NSRegularExpression(pattern: "^\\[!(tip|warning|note|info)\\]", options: [.caseInsensitive])
            let nsRange = NSRange(firstText.startIndex..., in: firstText)
            if let match = admonitionPattern.firstMatch(in: firstText, range: nsRange),
               let typeRange = Range(match.range(at: 1), in: firstText) {
                let type = String(firstText[typeRange]).lowercased()
                // Render remaining content
                var modifiedChildren: [String] = []
                for (i, child) in blockQuote.children.enumerated() {
                    if i == 0, let para = child as? Paragraph {
                        // Remove the [!type] prefix from first paragraph
                        let fullText = para.children.map { visit($0) }.joined()
                        let cleaned = fullText.replacingOccurrences(
                            of: "\\[!(tip|warning|note|info)\\]\\s*",
                            with: "",
                            options: .regularExpression,
                            range: fullText.startIndex..<fullText.endIndex
                        )
                        if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            modifiedChildren.append("<p>\(cleaned)</p>\n")
                        }
                    } else {
                        modifiedChildren.append(visit(child))
                    }
                }
                let title = type.prefix(1).uppercased() + type.dropFirst()
                let body = modifiedChildren.joined()
                return "<div class=\"admonition admonition-\(type)\"><p class=\"admonition-title\">\(title)</p>\(body)</div>\n"
            }
        }

        let content = blockQuote.children.map { visit($0) }.joined()
        return "<blockquote>\(content)</blockquote>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        let items = unorderedList.children.map { visit($0) }.joined()
        return "<ul>\(items)</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let items = orderedList.children.map { visit($0) }.joined()
        return "<ol>\(items)</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        let content = listItem.children.map { visit($0) }.joined()
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            let idx = checkboxIndex
            checkboxIndex += 1
            return "<li class=\"task-item\"><input type=\"checkbox\"\(checked) data-cb-index=\"\(idx)\"> \(content)</li>\n"
        }
        return "<li>\(content)</li>\n"
    }

    mutating func visitTable(_ table: Table) -> String {
        var html = "<table>\n"

        // Header
        html += "<thead>\n<tr>\n"
        for cell in table.head.cells {
            let content = cell.children.map { visit($0) }.joined()
            html += "<th>\(content)</th>\n"
        }
        html += "</tr>\n</thead>\n"

        // Body
        let bodyRows = Array(table.body.rows)
        if !bodyRows.isEmpty {
            html += "<tbody>\n"
            for row in bodyRows {
                html += "<tr>\n"
                for cell in row.cells {
                    let content = cell.children.map { visit($0) }.joined()
                    html += "<td>\(content)</td>\n"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }

        html += "</table>\n"
        return html
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        return "<hr>\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        return "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        return "\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        return restoreRubyPlaceholders(html.rawHTML)
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        return restoreRubyPlaceholders(html.rawHTML)
    }
}
