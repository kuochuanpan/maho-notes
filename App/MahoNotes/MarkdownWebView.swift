import SwiftUI
import WebKit
import MahoNotesKit

#if os(macOS)
struct MarkdownWebView: NSViewRepresentable, Equatable {
    let markdown: String
    /// Directory containing the note file — used to resolve relative `_assets/` paths.
    var noteDirectoryURL: URL?
    /// Called when a task-list checkbox is toggled in preview mode. (index, isChecked)
    var onCheckboxToggle: ((Int, Bool) -> Void)?

    nonisolated static func == (lhs: MarkdownWebView, rhs: MarkdownWebView) -> Bool {
        lhs.markdown == rhs.markdown && lhs.noteDirectoryURL == rhs.noteDirectoryURL
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "checkboxToggle")
        context.coordinator.onCheckboxToggle = onCheckboxToggle
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCheckboxToggle = onCheckboxToggle
        let html = buildHTML(from: markdown, noteDirectoryURL: noteDirectoryURL)
        let baseURL = Bundle.main.resourceURL
        // Skip reload if HTML hasn't changed — prevents scroll-to-top on unnecessary re-renders
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastBaseURL = baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#else
struct MarkdownWebView: UIViewRepresentable, Equatable {
    let markdown: String
    /// Directory containing the note file — used to resolve relative `_assets/` paths.
    var noteDirectoryURL: URL?
    /// Called when a task-list checkbox is toggled in preview mode. (index, isChecked)
    var onCheckboxToggle: ((Int, Bool) -> Void)?

    nonisolated static func == (lhs: MarkdownWebView, rhs: MarkdownWebView) -> Bool {
        lhs.markdown == rhs.markdown && lhs.noteDirectoryURL == rhs.noteDirectoryURL
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "checkboxToggle")
        context.coordinator.onCheckboxToggle = onCheckboxToggle
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onCheckboxToggle = onCheckboxToggle
        let html = buildHTML(from: markdown, noteDirectoryURL: noteDirectoryURL)
        let baseURL = Bundle.main.resourceURL
        // Skip reload if HTML hasn't changed — prevents scroll-to-top on unnecessary re-renders
        if html == context.coordinator.lastHTML {
            return
        }
        context.coordinator.lastHTML = html
        context.coordinator.lastBaseURL = baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif

// MARK: - Shared

extension MarkdownWebView {
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Last-loaded HTML, used to restore content after web content process termination.
        var lastHTML: String?
        var lastBaseURL: URL?
        /// Callback for checkbox toggle events from JavaScript.
        var onCheckboxToggle: ((Int, Bool) -> Void)?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #else
                UIApplication.shared.open(url)
                #endif
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        /// iOS may terminate WKWebView's web content process while the app is suspended.
        /// When the app resumes, the web view shows stale/blank content.
        /// Reload the last HTML to restore the preview.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if let html = lastHTML {
                webView.loadHTMLString(html, baseURL: lastBaseURL)
            }
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "checkboxToggle",
                  let body = message.body as? [String: Any],
                  let index = body["index"] as? Int,
                  let checked = body["checked"] as? Bool else { return }
            onCheckboxToggle?(index, checked)
        }
    }

    // MARK: - Bundled vendor assets

    /// Resolve a bundled resource file URL. XcodeGen flattens resources into the bundle root.
    private static func bundleURL(_ name: String, ext: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url.absoluteString
        }
        return ""
    }

    /// <head> tags for KaTeX and highlight.js
    static var vendorHead: String {
        let katexCSS = bundleURL("katex.min", ext: "css")
        let katexJS = bundleURL("katex.min", ext: "js")
        let autoRenderJS = bundleURL("auto-render.min", ext: "js")
        let hljsJS = bundleURL("highlight.min", ext: "js")
        let hljsLight = bundleURL("github.min", ext: "css")
        let hljsDark = bundleURL("github-dark.min", ext: "css")

        return """
        <link rel="stylesheet" href="\(katexCSS)">
        <script defer src="\(katexJS)"></script>
        <script defer src="\(autoRenderJS)"></script>
        <link rel="stylesheet" href="\(hljsLight)" media="(prefers-color-scheme: light)">
        <link rel="stylesheet" href="\(hljsDark)" media="(prefers-color-scheme: dark)">
        <script defer src="\(hljsJS)"></script>
        """
    }

    /// Post-body initialization script
    static let vendorScript = """
    <script>
    document.addEventListener("DOMContentLoaded", function() {
        if (typeof hljs !== "undefined") {
            document.querySelectorAll("pre code").forEach(function(block) {
                hljs.highlightElement(block);
            });
        }
        if (typeof renderMathInElement !== "undefined") {
            renderMathInElement(document.body, {
                delimiters: [
                    {left: "$$", right: "$$", display: true},
                    {left: "$", right: "$", display: false}
                ],
                throwOnError: false
            });
        }
        // Interactive checkbox toggle — notify Swift when a task-list checkbox is clicked
        document.addEventListener("change", function(e) {
            if (e.target.type === "checkbox" && e.target.dataset.cbIndex !== undefined) {
                window.webkit.messageHandlers.checkboxToggle.postMessage({
                    index: parseInt(e.target.dataset.cbIndex),
                    checked: e.target.checked
                });
            }
        });
    });
    </script>
    """

    /// Replace relative `_assets/` image paths with base64 `data:` URLs so WKWebView can display them.
    /// Non-image `_assets/` links are converted to `file://` URLs (for "Open in..." via link click).
    private func resolveAssetPaths(in markdown: String, noteDirectoryURL: URL?) -> String {
        guard let dirURL = noteDirectoryURL else { return markdown }

        // Match image references: ![...](_assets/...)
        let imgPattern = #"(\!\[[^\]]*\]\()(_assets/[^)]+)(\))"#
        guard let imgRegex = try? NSRegularExpression(pattern: imgPattern) else { return markdown }
        var result = markdown
        let nsRange = NSRange(result.startIndex..., in: result)
        let imgMatches = imgRegex.matches(in: result, range: nsRange)
        for match in imgMatches.reversed() {
            guard let pathRange = Range(match.range(at: 2), in: result) else { continue }
            let relativePath = String(result[pathRange])
            let fileURL = dirURL.appendingPathComponent(relativePath)
            // Convert to base64 data: URL for WKWebView compatibility
            if let data = try? Data(contentsOf: fileURL) {
                let ext = fileURL.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "webp": mime = "image/webp"
                case "svg": mime = "image/svg+xml"
                case "heic": mime = "image/heic"
                default: mime = "application/octet-stream"
                }
                let b64 = data.base64EncodedString()
                result.replaceSubrange(pathRange, with: "data:\(mime);base64,\(b64)")
            }
        }

        // Non-image links: [text](_assets/file.pdf) → file:// URL
        let linkPattern = #"(?<!\!)(\[[^\]]*\]\()(_assets/[^)]+)(\))"#
        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern) else { return result }
        let nsRange2 = NSRange(result.startIndex..., in: result)
        let linkMatches = linkRegex.matches(in: result, range: nsRange2)
        for match in linkMatches.reversed() {
            guard let pathRange = Range(match.range(at: 2), in: result) else { continue }
            let relativePath = String(result[pathRange])
            let absoluteURL = dirURL.appendingPathComponent(relativePath)
            result.replaceSubrange(pathRange, with: absoluteURL.absoluteString)
        }
        return result
    }

    func buildHTML(from markdown: String, noteDirectoryURL: URL? = nil) -> String {
        let resolved = resolveAssetPaths(in: markdown, noteDirectoryURL: noteDirectoryURL)
        let renderer = MarkdownHTMLRenderer()
        let body = renderer.render(resolved)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            --bg: #ffffff;
            --fg: #1d1d1f;
            --fg-secondary: #6e6e73;
            --code-bg: #f5f5f7;
            --border: #d2d2d7;
            --accent: #0066cc;
            --blockquote-border: #d2d2d7;
            --table-stripe: #f5f5f7;
            --admonition-note: #0066cc;
            --admonition-tip: #34c759;
            --admonition-warning: #ff9500;
            --admonition-info: #5856d6;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: transparent;
                --fg: #f5f5f7;
                --fg-secondary: #98989d;
                --code-bg: #2c2c2e;
                --border: #48484a;
                --accent: #2997ff;
                --blockquote-border: #48484a;
                --table-stripe: #2c2c2e;
                --admonition-note: #2997ff;
                --admonition-tip: #30d158;
                --admonition-warning: #ff9f0a;
                --admonition-info: #5e5ce6;
            }
        }
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans", "Hiragino Kaku Gothic ProN", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif;
            font-size: 15px;
            line-height: 1.7;
            color: var(--fg);
            background: var(--bg);
            max-width: 720px;
            margin: 0 auto;
            padding: 0 20px 40px;
            -webkit-text-size-adjust: 100%;
        }
        h1, h2, h3, h4, h5, h6 {
            font-weight: 600;
            line-height: 1.3;
            margin-top: 1.5em;
            margin-bottom: 0.5em;
        }
        h1 { font-size: 1.8em; }
        h2 { font-size: 1.4em; }
        h3 { font-size: 1.2em; }
        h4, h5, h6 { font-size: 1em; }
        p { margin: 0.8em 0; }
        a { color: var(--accent); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong { font-weight: 600; }
        code {
            font-family: "SF Mono", SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 0.88em;
            background: var(--code-bg);
            padding: 0.15em 0.4em;
            border-radius: 4px;
        }
        pre {
            background: var(--code-bg);
            border-radius: 8px;
            padding: 14px 16px;
            overflow-x: auto;
            margin: 1em 0;
        }
        pre code {
            background: none;
            padding: 0;
            font-size: 0.85em;
            line-height: 1.5;
        }
        blockquote {
            border-left: 3px solid var(--blockquote-border);
            margin: 1em 0;
            padding: 0.5em 1em;
            color: var(--fg-secondary);
        }
        blockquote p { margin: 0.4em 0; }
        hr {
            border: none;
            border-top: 1px solid var(--border);
            margin: 2em 0;
        }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        /* Image layout: figure wrapper for alignment */
        figure.img-left,
        figure.img-right,
        figure.img-center {
            margin: 12px 0;
            padding: 0;
            max-width: 100%;
        }
        figure.img-left img,
        figure.img-right img,
        figure.img-center img {
            width: 100%;
            height: auto;
            border-radius: 6px;
        }
        figure.img-left {
            float: left;
            margin: 4px 16px 12px 0;
        }
        figure.img-right {
            float: right;
            margin: 4px 0 12px 16px;
        }
        figure.img-center {
            margin-left: auto;
            margin-right: auto;
        }
        /* Clear float after floated images */
        p:has(+ figure.img-left),
        p:has(+ figure.img-right),
        figure.img-left + *:not(p),
        figure.img-right + *:not(p) {
            clear: both;
        }
        /* Phone: cancel float, force full width */
        @media (max-width: 480px) {
            figure.img-left,
            figure.img-right {
                float: none;
                width: 100% !important;
                margin: 12px 0;
            }
        }
        ul, ol { padding-left: 1.5em; margin: 0.8em 0; }
        li { margin: 0.3em 0; }
        li > p { margin: 0.2em 0; }
        input[type="checkbox"] {
            margin-right: 0.4em;
            transform: scale(1.1);
            vertical-align: middle;
        }
        li.task-item {
            list-style: none;
            margin-left: -1.5em;
        }
        li.task-item > p {
            display: inline;
            margin: 0;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            margin: 1em 0;
            font-size: 0.92em;
        }
        th, td {
            border: 1px solid var(--border);
            padding: 8px 12px;
            text-align: left;
        }
        th {
            font-weight: 600;
            background: var(--code-bg);
        }
        tbody tr:nth-child(even) { background: var(--table-stripe); }
        del { color: var(--fg-secondary); }
        mark {
            background: rgba(255, 230, 0, 0.35);
            color: inherit;
            padding: 0.1em 0.2em;
            border-radius: 3px;
        }
        @media (prefers-color-scheme: dark) {
            mark { background: rgba(255, 210, 0, 0.25); }
        }
        .admonition {
            border-left: 3px solid var(--admonition-note);
            border-radius: 4px;
            padding: 0.5em 1em;
            margin: 1em 0;
        }
        .admonition-title {
            font-weight: 600;
            margin-bottom: 0.3em;
        }
        .admonition-note { border-left-color: var(--admonition-note); }
        .admonition-tip { border-left-color: var(--admonition-tip); }
        .admonition-warning { border-left-color: var(--admonition-warning); }
        .admonition-info { border-left-color: var(--admonition-info); }
        ruby { ruby-align: center; }
        rt { font-size: 0.6em; color: var(--fg-secondary); }
        .math-block {
            overflow-x: auto;
            margin: 1em 0;
            padding: 0.5em;
            text-align: center;
            font-family: "SF Mono", SFMono-Regular, Menlo, Monaco, monospace;
            font-size: 0.9em;
        }
        .math-inline {
            font-family: "SF Mono", SFMono-Regular, Menlo, Monaco, monospace;
            font-size: 0.9em;
        }
        /* highlight.js overrides */
        pre code.hljs {
            background: none;
            padding: 0;
        }
        </style>
        \(Self.vendorHead)
        </head>
        <body>
        \(body)
        \(Self.vendorScript)
        </body>
        </html>
        """
    }
}
