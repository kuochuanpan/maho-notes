import SwiftUI
import WebKit
import PDFKit
import UniformTypeIdentifiers
import MahoNotesKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum PDFExportError: Error {
    case renderFailed
}

/// Renders a note's markdown to a paginated A4 PDF.
///
/// The note's HTML — the *same* HTML the live preview uses (`MarkdownWebView.buildHTML`) — is
/// loaded into an offscreen `WKWebView` and captured with `WKWebView.createPDF`, which produces
/// a single page as tall as the whole note. That continuous page is then sliced into A4 pages
/// with Core Graphics (`repaginate`).
///
/// We deliberately avoid the platform print system (`NSPrintOperation` / `UIPrintPageRenderer`):
/// `WKWebView` + `NSPrintOperation` crashes on macOS ("WKPrintingView frame was not initialized")
/// and can emit a multi-gigabyte file. The createPDF + slice path is deterministic and shared by
/// both platforms.
@MainActor
final class NotePDFExporter: NSObject, WKNavigationDelegate {
    /// A4 in PostScript points (210mm × 297mm at 72dpi).
    private static let paperSize = CGSize(width: 595.28, height: 841.89)
    /// 0.5in margin on every side.
    private static let margin: CGFloat = 36
    private static var printableWidth: CGFloat { paperSize.width - margin * 2 }
    private static var printableHeight: CGFloat { paperSize.height - margin * 2 }

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Generate paginated A4 PDF data for the given markdown. Throws if the page fails to load.
    func generatePDF(markdown: String, noteDirectoryURL: URL?) async throws -> Data {
        let config = WKWebViewConfiguration()
        // Lay the content out at the printable width so text wraps the way it will print and the
        // captured page needs no horizontal scaling (scale factor stays 1).
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: Self.printableWidth, height: Self.paperSize.height),
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
            webView.removeFromSuperview()
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

        let continuousPDF = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }

        return try Self.repaginate(continuousPDF)
    }

    // MARK: - Pagination

    /// Slice a single tall PDF page into A4 pages with Core Graphics. Content is scaled to the
    /// printable width and split vertically; page breaks are positional (a line may straddle a
    /// boundary), the standard tradeoff for slicing a continuous web render.
    private static func repaginate(_ pdfData: Data) throws -> Data {
        guard let srcDoc = PDFDocument(data: pdfData),
              let srcPage = srcDoc.page(at: 0),
              let cgPage = srcPage.pageRef else {
            throw PDFExportError.renderFailed
        }

        let srcBox = srcPage.bounds(for: .mediaBox)
        guard srcBox.width > 0, srcBox.height > 0 else { throw PDFExportError.renderFailed }

        let scale = printableWidth / srcBox.width
        let scaledHeight = srcBox.height * scale
        let pageCount = max(1, Int(ceil(scaledHeight / printableHeight)))

        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else {
            throw PDFExportError.renderFailed
        }
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFExportError.renderFailed
        }

        for page in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Keep content inside the page margins.
            ctx.clip(to: CGRect(x: margin, y: margin, width: printableWidth, height: printableHeight))
            // Position slice `page` so its top aligns with the top of the printable area.
            let tyOffset = (paperSize.height - margin) - scaledHeight + CGFloat(page) * printableHeight
            ctx.translateBy(x: margin, y: tyOffset)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -srcBox.origin.x, y: -srcBox.origin.y)
            ctx.drawPDFPage(cgPage)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()

        guard out.length > 0 else { throw PDFExportError.renderFailed }
        return out as Data
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
