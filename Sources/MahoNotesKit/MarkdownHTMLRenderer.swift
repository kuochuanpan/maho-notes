@preconcurrency import Markdown
import Foundation

/// Converts a Markdown string to HTML using swift-markdown
public struct MarkdownHTMLRenderer: Sendable {
    public init() {}

    public func render(_ markdown: String) -> String {
        let preprocessed = preprocessMath(markdown)
        let document = Document(parsing: preprocessed, options: [.parseBlockDirectives, .parseSymbolLinks])
        var visitor = HTMLVisitor()
        return visitor.visit(document)
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

/// Process ruby annotations: {base|annotation} -> <ruby> HTML
func processRubyAnnotations(_ text: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "\\{([^|\\}]+)\\|([^\\}]+)\\}", options: [])
    let nsRange = NSRange(text.startIndex..., in: text)
    var result = text
    let matches = pattern.matches(in: text, range: nsRange)
    for match in matches.reversed() {
        guard let range = Range(match.range, in: result),
              let baseRange = Range(match.range(at: 1), in: result),
              let annotRange = Range(match.range(at: 2), in: result) else { continue }
        let base = String(result[baseRange])
        let annotation = String(result[annotRange])
        result.replaceSubrange(range, with: "<ruby><rb>\(base)</rb><rp>(</rp><rt>\(annotation)</rt><rp>)</rp></ruby>")
    }
    return result
}

// MARK: - MarkupVisitor

private struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    // Track if we're inside a blockquote to detect admonitions
    private var insideBlockquote = false
    private var blockquoteContent = ""

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
        return processRubyAnnotations(escaped)
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
            let checked = checkbox == .checked ? " checked disabled" : " disabled"
            return "<li><input type=\"checkbox\"\(checked)> \(content)</li>\n"
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
        return html.rawHTML
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        return html.rawHTML
    }
}
