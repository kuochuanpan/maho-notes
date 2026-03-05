import Foundation

/// Configuration for static site generation, parsed from maho.yaml
public struct SiteConfig: Sendable {
    public let title: String
    public let domain: String
    public let author: String

    public init(title: String = "Maho Notes", domain: String = "", author: String = "") {
        self.title = title
        self.domain = domain
        self.author = author
    }
}

/// Result of site generation
public struct GenerationResult: Sendable {
    public let generated: Int
    public let skipped: Int
    public let errors: Int

    public init(generated: Int, skipped: Int, errors: Int) {
        self.generated = generated
        self.skipped = skipped
        self.errors = errors
    }
}

/// Generates a complete static site from public notes in a vault
public struct SiteGenerator: Sendable {
    public let vault: Vault
    public let config: SiteConfig

    public init(vault: Vault, config: SiteConfig) {
        self.vault = vault
        self.config = config
    }

    /// Generate the static site to the given output directory
    public func generate(to outputPath: String, notes: [Note]? = nil) throws -> GenerationResult {
        let fm = FileManager.default
        let allNotes = try notes ?? vault.allNotes()

        // Filter to public, non-draft notes
        let publicNotes = allNotes.filter { $0.isPublic && !$0.draft }
        let skipped = allNotes.count - publicNotes.count

        // Create output directory
        try fm.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        var generated = 0
        var errors = 0
        let renderer = MarkdownHTMLRenderer()

        // Group notes by collection
        var notesByCollection: [String: [Note]] = [:]
        for note in publicNotes {
            let col = note.collection
            notesByCollection[col, default: []].append(note)
        }

        // Sort notes within each collection by order, then title
        for key in notesByCollection.keys {
            notesByCollection[key]?.sort { a, b in
                if let oa = a.order, let ob = b.order { return oa < ob }
                if a.order != nil { return true }
                if b.order != nil { return false }
                return a.title < b.title
            }
        }

        // Load collection metadata
        let collections = (try? vault.collections()) ?? []
        let collectionMap = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })

        // Generate individual note pages
        for note in publicNotes {
            do {
                let slug = note.slug ?? makeSlug(from: note.title)
                let col = note.collection
                let dir = "\(outputPath)/c/\(col)"
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

                let htmlBody = renderer.render(note.body)
                let readingTime = Self.readingTime(for: note.body)
                let description = Self.plainTextExcerpt(from: note.body, maxLength: 160)
                let url = "\(config.domain)/c/\(col)/\(slug).html"

                let page = Self.notePage(
                    note: note,
                    htmlBody: htmlBody,
                    readingTime: readingTime,
                    description: description,
                    url: url,
                    config: config
                )

                try page.write(toFile: "\(dir)/\(slug).html", atomically: true, encoding: .utf8)
                generated += 1
            } catch {
                errors += 1
            }
        }

        // Generate collection index pages
        for (colId, colNotes) in notesByCollection {
            do {
                let dir = "\(outputPath)/c/\(colId)"
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let colMeta = collectionMap[colId]
                let colName = colMeta?.name ?? colId
                let page = Self.collectionPage(
                    collectionId: colId,
                    collectionName: colName,
                    notes: colNotes,
                    config: config
                )
                try page.write(toFile: "\(dir)/index.html", atomically: true, encoding: .utf8)
                generated += 1
            } catch {
                errors += 1
            }
        }

        // Generate site index page
        do {
            let indexPage = Self.indexPage(
                notesByCollection: notesByCollection,
                collectionMap: collectionMap,
                config: config
            )
            try indexPage.write(toFile: "\(outputPath)/index.html", atomically: true, encoding: .utf8)
            generated += 1
        } catch {
            errors += 1
        }

        // Generate RSS feed
        do {
            let sortedNotes = publicNotes.sorted { ($0.updated) > ($1.updated) }
            let feedNotes = Array(sortedNotes.prefix(20))
            let feed = Self.rssFeed(notes: feedNotes, config: config)
            try feed.write(toFile: "\(outputPath)/feed.xml", atomically: true, encoding: .utf8)
            generated += 1
        } catch {
            errors += 1
        }

        // Copy _assets/ if it exists
        let assetsSource = (vault.path as NSString).appendingPathComponent("_assets")
        let assetsDest = (outputPath as NSString).appendingPathComponent("_assets")
        if fm.fileExists(atPath: assetsSource) {
            if fm.fileExists(atPath: assetsDest) {
                try fm.removeItem(atPath: assetsDest)
            }
            try fm.copyItem(atPath: assetsSource, toPath: assetsDest)
        }

        return GenerationResult(generated: generated, skipped: skipped, errors: errors)
    }

    // MARK: - Reading Time

    static func readingTime(for text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return max(1, (words + 199) / 200)
    }

    // MARK: - Excerpt

    static func plainTextExcerpt(from body: String, maxLength: Int) -> String {
        let stripped = body
            .replacingOccurrences(of: "\\n#+\\s", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[*_`~\\[\\]()#>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count <= maxLength { return stripped }
        let truncated = stripped.prefix(maxLength)
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }
        return String(truncated) + "..."
    }

    // MARK: - Templates

    static func baseLayout(title: String, description: String, url: String, config: SiteConfig, content: String, needsMath: Bool = false, needsMermaid: Bool = false) -> String {
        let mathHead = needsMath ? """
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"></script>
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js" onload="renderMathInElement(document.body)"></script>
        """ : ""

        let mermaidHead = needsMermaid ? """
        <script type="module">import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs';mermaid.initialize({startOnLoad:true});</script>
        """ : ""

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <meta property="og:title" content="\(escapeHTML(title))">
        <meta property="og:description" content="\(escapeHTML(description))">
        <meta property="og:url" content="\(escapeHTML(url))">
        <meta property="og:type" content="article">
        <link rel="alternate" type="application/rss+xml" title="\(escapeHTML(config.title))" href="\(escapeHTML(config.domain))/feed.xml">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github.min.css" media="(prefers-color-scheme: light)">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github-dark.min.css" media="(prefers-color-scheme: dark)">
        <script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>
        <script>hljs.highlightAll();</script>
        \(mathHead)\(mermaidHead)\(css)
        </head>
        <body>
        <nav><a href="/">\(escapeHTML(config.title))</a></nav>
        <main>
        \(content)
        </main>
        <footer><p>\(escapeHTML(config.author.isEmpty ? config.title : "© " + config.author))</p></footer>
        </body>
        </html>
        """
    }

    static func notePage(note: Note, htmlBody: String, readingTime: Int, description: String, url: String, config: SiteConfig) -> String {
        let needsMath = note.body.contains("$")
        let needsMermaid = note.body.contains("```mermaid")
        let tagsHTML = note.tags.map { "<span class=\"tag\">\(escapeHTML($0))</span>" }.joined(separator: " ")
        let meta = [
            note.author.map { "By \(escapeHTML($0))" },
            note.updated.isEmpty ? nil : escapeHTML(String(note.updated.prefix(10))),
            "\(readingTime) min read",
        ].compactMap { $0 }.joined(separator: " · ")

        let content = """
        <article>
        <h1>\(escapeHTML(note.title))</h1>
        <div class="meta">\(meta)</div>
        \(tagsHTML.isEmpty ? "" : "<div class=\"tags\">\(tagsHTML)</div>")
        <div class="content">\(htmlBody)</div>
        </article>
        """

        return baseLayout(
            title: "\(note.title) — \(config.title)",
            description: description,
            url: url,
            config: config,
            content: content,
            needsMath: needsMath,
            needsMermaid: needsMermaid
        )
    }

    static func collectionPage(collectionId: String, collectionName: String, notes: [Note], config: SiteConfig) -> String {
        var items = ""
        for note in notes {
            let slug = note.slug ?? makeSlug(from: note.title)
            let date = String(note.updated.prefix(10))
            items += """
            <li><a href="/c/\(escapeHTML(collectionId))/\(escapeHTML(slug)).html">\(escapeHTML(note.title))</a> <span class="date">\(escapeHTML(date))</span></li>\n
            """
        }

        let content = """
        <h1>\(escapeHTML(collectionName))</h1>
        <ul class="note-list">\(items)</ul>
        """

        return baseLayout(
            title: "\(collectionName) — \(config.title)",
            description: "Notes in \(collectionName)",
            url: "\(config.domain)/c/\(collectionId)/",
            config: config,
            content: content
        )
    }

    static func indexPage(notesByCollection: [String: [Note]], collectionMap: [String: Collection], config: SiteConfig) -> String {
        let sortedCollections = notesByCollection.keys.sorted()
        var sections = ""
        for colId in sortedCollections {
            guard let notes = notesByCollection[colId] else { continue }
            let colName = collectionMap[colId]?.name ?? colId
            sections += "<section>\n<h2><a href=\"/c/\(escapeHTML(colId))/\">\(escapeHTML(colName))</a></h2>\n<ul class=\"note-list\">\n"
            for note in notes {
                let slug = note.slug ?? makeSlug(from: note.title)
                sections += "<li><a href=\"/c/\(escapeHTML(colId))/\(escapeHTML(slug)).html\">\(escapeHTML(note.title))</a></li>\n"
            }
            sections += "</ul>\n</section>\n"
        }

        let content = """
        <h1>\(escapeHTML(config.title))</h1>
        \(sections)
        """

        return baseLayout(
            title: config.title,
            description: config.title,
            url: config.domain,
            config: config,
            content: content
        )
    }

    static func rssFeed(notes: [Note], config: SiteConfig) -> String {
        var items = ""
        for note in notes {
            let slug = note.slug ?? makeSlug(from: note.title)
            let col = note.collection
            let link = "\(config.domain)/c/\(col)/\(slug).html"
            let description = plainTextExcerpt(from: note.body, maxLength: 300)
            items += """
            <item>
            <title>\(xmlEscape(note.title))</title>
            <link>\(xmlEscape(link))</link>
            <description>\(xmlEscape(description))</description>
            <pubDate>\(xmlEscape(note.updated))</pubDate>
            <guid>\(xmlEscape(link))</guid>
            </item>\n
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
        <channel>
        <title>\(xmlEscape(config.title))</title>
        <link>\(xmlEscape(config.domain))</link>
        <description>\(xmlEscape(config.title))</description>
        \(items)</channel>
        </rss>
        """
    }

    // MARK: - CSS

    static let css = """
    <style>
    :root{--bg:#fff;--fg:#1a1a1a;--muted:#666;--border:#e0e0e0;--code-bg:#f5f5f5;--link:#0066cc;--accent:#0066cc}
    @media(prefers-color-scheme:dark){:root{--bg:#1a1a1a;--fg:#e0e0e0;--muted:#999;--border:#333;--code-bg:#2d2d2d;--link:#6ab0ff;--accent:#6ab0ff}}
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;line-height:1.7;color:var(--fg);background:var(--bg);max-width:48rem;margin:0 auto;padding:1rem}
    nav{padding:1rem 0;border-bottom:1px solid var(--border);margin-bottom:2rem}
    nav a{font-weight:700;color:var(--fg);text-decoration:none;font-size:1.2rem}
    main{min-height:60vh}
    footer{margin-top:3rem;padding:1rem 0;border-top:1px solid var(--border);color:var(--muted);font-size:.85rem}
    h1{font-size:2rem;margin:1rem 0 .5rem;line-height:1.2}
    h2{font-size:1.5rem;margin:1.5rem 0 .5rem}
    h3{font-size:1.25rem;margin:1.2rem 0 .4rem}
    h4,h5,h6{font-size:1.1rem;margin:1rem 0 .3rem}
    p{margin:.8rem 0}
    a{color:var(--link)}
    img{max-width:100%;height:auto}
    pre{background:var(--code-bg);padding:1rem;border-radius:.4rem;overflow-x:auto;margin:1rem 0}
    code{font-family:"SF Mono",Menlo,Monaco,monospace;font-size:.9em}
    :not(pre)>code{background:var(--code-bg);padding:.15em .3em;border-radius:.25rem}
    blockquote{border-left:3px solid var(--border);padding-left:1rem;margin:1rem 0;color:var(--muted)}
    table{border-collapse:collapse;width:100%;margin:1rem 0}
    th,td{border:1px solid var(--border);padding:.5rem .75rem;text-align:left}
    th{background:var(--code-bg)}
    ul,ol{margin:.5rem 0 .5rem 1.5rem}
    li{margin:.2rem 0}
    hr{border:none;border-top:1px solid var(--border);margin:2rem 0}
    .meta{color:var(--muted);font-size:.9rem;margin-bottom:1rem}
    .tags{margin:.5rem 0 1.5rem}
    .tag{display:inline-block;background:var(--code-bg);padding:.1rem .5rem;border-radius:1rem;font-size:.8rem;margin-right:.3rem}
    .date{color:var(--muted);font-size:.85rem}
    .note-list{list-style:none;padding:0}
    .note-list li{padding:.4rem 0;border-bottom:1px solid var(--border)}
    .note-list a{text-decoration:none;font-weight:500}
    .admonition{border-left:4px solid var(--accent);padding:.75rem 1rem;margin:1rem 0;border-radius:0 .4rem .4rem 0;background:var(--code-bg)}
    .admonition-title{font-weight:700;margin-bottom:.3rem}
    .admonition-tip{border-left-color:#22c55e}
    .admonition-warning{border-left-color:#f59e0b}
    .admonition-note{border-left-color:#3b82f6}
    .admonition-info{border-left-color:#06b6d4}
    ruby{ruby-position:over}
    rt{font-size:.6em;color:var(--muted)}
    .mermaid{margin:1rem 0}
    .math-block{margin:1rem 0;text-align:center;overflow-x:auto}
    @media(max-width:600px){body{padding:.5rem}h1{font-size:1.5rem}h2{font-size:1.25rem}}
    </style>
    """
}

// MARK: - XML Escaping

private func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
