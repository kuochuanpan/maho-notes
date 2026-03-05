import SwiftUI
import WebKit
import MahoNotesKit

#if os(macOS)
struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = buildHTML(from: markdown)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#else
struct MarkdownWebView: UIViewRepresentable {
    let markdown: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = buildHTML(from: markdown)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif

// MARK: - Shared

extension MarkdownWebView {
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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
    }

    func buildHTML(from markdown: String) -> String {
        let renderer = MarkdownHTMLRenderer()
        let body = renderer.render(markdown)
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
        ul, ol { padding-left: 1.5em; margin: 0.8em 0; }
        li { margin: 0.3em 0; }
        li > p { margin: 0.2em 0; }
        input[type="checkbox"] {
            margin-right: 0.4em;
            transform: scale(1.1);
            vertical-align: middle;
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
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
