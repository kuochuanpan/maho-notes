import SwiftUI
import WebKit
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

/// Renders a note's markdown to a paginated PDF by loading the *same* HTML the live preview
/// uses (`MarkdownWebView.buildHTML`) into an offscreen `WKWebView`, then driving the platform
/// print system to produce A4 pages.
///
/// We use the print system (`NSPrintOperation` / `UIPrintPageRenderer`) rather than
/// `WKWebView.createPDF`, because `createPDF` emits a single page as tall as the whole note —
/// the print path paginates content into real A4 pages suitable for printing.
@MainActor
final class NotePDFExporter: NSObject, WKNavigationDelegate {
    /// A4 in PostScript points (210mm × 297mm at 72dpi).
    private static let paperSize = CGSize(width: 595.28, height: 841.89)
    /// 0.5in margin on every side.
    private static let margin: CGFloat = 36
    private static var printableWidth: CGFloat { paperSize.width - margin * 2 }

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Generate paginated A4 PDF data for the given markdown. Throws if the page fails to load.
    func generatePDF(markdown: String, noteDirectoryURL: URL?) async throws -> Data {
        let config = WKWebViewConfiguration()
        // Lay the content out at the printable width so text wraps the way it will print.
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

        return try Self.renderPaginatedPDF(from: webView)
    }

    // MARK: - Paginated rendering

    #if os(macOS)
    private static func renderPaginatedPDF(from webView: WKWebView) throws -> Data {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = paperSize
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmpURL

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        guard operation.run() else { throw PDFExportError.renderFailed }
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        return try Data(contentsOf: tmpURL)
    }
    #else
    private static func renderPaginatedPDF(from webView: WKWebView) throws -> Data {
        let paperRect = CGRect(origin: .zero, size: paperSize)
        let printableRect = paperRect.insetBy(dx: margin, dy: margin)

        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        // UIPrintPageRenderer reads paper/printable rects via KVC.
        renderer.setValue(paperRect, forKey: "paperRect")
        renderer.setValue(printableRect, forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paperRect, nil)
        let pageCount = max(renderer.numberOfPages, 1)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pageCount))
        for page in 0..<pageCount {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: paperRect)
        }
        UIGraphicsEndPDFContext()

        guard data.length > 0 else { throw PDFExportError.renderFailed }
        return data as Data
    }
    #endif

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
