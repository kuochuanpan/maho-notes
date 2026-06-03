import SwiftUI
import WebKit
import UniformTypeIdentifiers
import MahoNotesKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Renders a note's markdown to a PDF by loading the *same* HTML the live preview uses
/// (`MarkdownWebView.buildHTML`) into an offscreen `WKWebView`, then capturing it via
/// `createPDF`. Works on both macOS and iOS — `WKWebView.createPDF` is cross-platform.
///
/// The web view is attached to the key window (fully transparent) while loading so layout
/// and the vendor scripts (KaTeX, highlight.js, Mermaid) run reliably, then removed.
@MainActor
final class NotePDFExporter: NSObject, WKNavigationDelegate {
    /// US Letter width in points (8.5in × 72). Controls line wrapping in the rendered PDF.
    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Generate PDF data for the given markdown. Throws if the page fails to load.
    func generatePDF(markdown: String, noteDirectoryURL: URL?) async throws -> Data {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: Self.pageWidth, height: Self.pageHeight),
            configuration: config
        )
        webView.navigationDelegate = self
        self.webView = webView

        // Force a light appearance so the export has a white background regardless of the
        // app's current color scheme (the preview CSS uses a transparent bg in dark mode).
        #if os(macOS)
        webView.appearance = NSAppearance(named: .aqua)
        #else
        webView.overrideUserInterfaceStyle = .light
        #endif

        attachOffscreen(webView)
        defer {
            removeFromSuperview(webView)
            self.webView = nil
        }

        let html = MarkdownWebView.buildHTML(from: markdown, noteDirectoryURL: noteDirectoryURL)
        let baseURL = Bundle.main.resourceURL

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        // `didFinish` fires before deferred vendor scripts (KaTeX auto-render, Mermaid,
        // syntax highlighting) finish mutating the DOM. Give them a moment before capture.
        try? await Task.sleep(for: .milliseconds(500))

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Offscreen attachment

    private func attachOffscreen(_ webView: WKWebView) {
        #if os(macOS)
        guard let contentView = NSApplication.shared.windows.first(where: { $0.isVisible })?.contentView
            ?? NSApplication.shared.windows.first?.contentView else { return }
        webView.alphaValue = 0
        contentView.addSubview(webView)
        #else
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        webView.alpha = 0
        window.addSubview(webView)
        #endif
    }

    private func removeFromSuperview(_ webView: WKWebView) {
        webView.removeFromSuperview()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

/// Minimal `FileDocument` wrapper so SwiftUI's `.fileExporter` can write generated PDF data.
/// Used on iOS to save into Files / iCloud Drive; macOS saves via `NSSavePanel` directly.
struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
