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

        // Measure the vertical extent of every text line / atomic block so we can break pages
        // between them instead of through them.
        let layout = await measureLayout(webView)

        let continuousPDF = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }

        return try Self.repaginate(continuousPDF, layout: layout)
    }

    // MARK: - Layout measurement

    /// One run of laid-out content that must not be split across a page boundary,
    /// in CSS-pixel document coordinates (top-down).
    private struct LayoutMeasurement: Decodable {
        let height: Double
        /// `[top, bottom]` pairs for each text line and atomic block.
        let atoms: [[Double]]
    }

    /// Collect the bounding boxes of every text line (via `Range.getClientRects`) plus atomic
    /// blocks (images, code blocks, tables, etc.) so pagination can avoid cutting through them.
    private func measureLayout(_ webView: WKWebView) async -> LayoutMeasurement? {
        let js = """
        (function () {
          var atoms = [];
          function push(t, b) { if (b > t) atoms.push([t, b]); }
          var y = window.scrollY;
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var n;
          while ((n = walker.nextNode())) {
            if (!n.nodeValue || !n.nodeValue.trim()) continue;
            var range = document.createRange();
            range.selectNodeContents(n);
            var rects = range.getClientRects();
            for (var i = 0; i < rects.length; i++) {
              if (rects[i].height > 0) push(rects[i].top + y, rects[i].bottom + y);
            }
          }
          var blocks = document.querySelectorAll("img, pre, table, svg, .mermaid, hr, blockquote, h1, h2, h3, h4, h5, h6, .admonition, .math-block");
          for (var j = 0; j < blocks.length; j++) {
            var r = blocks[j].getBoundingClientRect();
            if (r.height > 0) push(r.top + y, r.bottom + y);
          }
          return JSON.stringify({ height: document.body.scrollHeight, atoms: atoms });
        })();
        """
        return await withCheckedContinuation { (continuation: CheckedContinuation<LayoutMeasurement?, Never>) in
            webView.evaluateJavaScript(js) { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let measurement = try? JSONDecoder().decode(LayoutMeasurement.self, from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: measurement)
            }
        }
    }

    // MARK: - Pagination

    /// Slice the single tall PDF page into A4 pages with Core Graphics. Page breaks land in the
    /// gaps *between* text lines / atomic blocks (using `layout`) so no line is cut in half; the
    /// leftover space at the bottom of a page is simply left blank. Falls back to fixed-height
    /// slices if measurement is unavailable.
    private static func repaginate(_ pdfData: Data, layout: LayoutMeasurement?) throws -> Data {
        guard let srcDoc = PDFDocument(data: pdfData),
              let srcPage = srcDoc.page(at: 0),
              let cgPage = srcPage.pageRef else {
            throw PDFExportError.renderFailed
        }

        let srcBox = srcPage.bounds(for: .mediaBox)
        guard srcBox.width > 0, srcBox.height > 0 else { throw PDFExportError.renderFailed }

        let scale = printableWidth / srcBox.width
        // How much of the source page (in its own points) fits on one A4 page.
        let pageHeightSrc = printableHeight / scale

        // Map the CSS-pixel measurements onto source-PDF points (vertical scale is uniform).
        let forbidden = forbiddenRanges(layout: layout, srcHeight: srcBox.height)
        let spans = pageSpans(contentHeight: srcBox.height, pageHeight: pageHeightSrc, forbidden: forbidden)

        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else {
            throw PDFExportError.renderFailed
        }
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFExportError.renderFailed
        }

        for (start, end) in spans {
            let sliceHeight = (end - start) * scale
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // Clip to just this slice, top-aligned in the printable area — the rest of the page
            // (when a line wouldn't fully fit) stays blank.
            let clipY = (paperSize.height - margin) - sliceHeight
            ctx.clip(to: CGRect(x: margin, y: clipY, width: printableWidth, height: sliceHeight))
            // Align source distance-from-top `start` with the top of the printable area.
            let tyOffset = (paperSize.height - margin) - (srcBox.height - start) * scale
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

    /// Merge the measured line/block boxes into maximal non-overlapping vertical ranges (in
    /// source-PDF points, top-down) that a page break must not fall inside.
    private static func forbiddenRanges(layout: LayoutMeasurement?, srcHeight: CGFloat) -> [(lo: CGFloat, hi: CGFloat)] {
        guard let layout, layout.height > 0, !layout.atoms.isEmpty else { return [] }
        let ratio = srcHeight / CGFloat(layout.height)
        let mergeTolerance: CGFloat = 1.0

        let boxes = layout.atoms
            .compactMap { pair -> (lo: CGFloat, hi: CGFloat)? in
                guard pair.count == 2 else { return nil }
                return (CGFloat(pair[0]) * ratio, CGFloat(pair[1]) * ratio)
            }
            .sorted { $0.lo < $1.lo }

        var merged: [(lo: CGFloat, hi: CGFloat)] = []
        for box in boxes {
            if var last = merged.last, box.lo <= last.hi + mergeTolerance {
                last.hi = max(last.hi, box.hi)
                merged[merged.count - 1] = last
            } else {
                merged.append(box)
            }
        }
        return merged
    }

    /// Choose page boundaries (top-down, source-PDF points). Each page is at most `pageHeight`
    /// tall and never ends inside a `forbidden` range — it ends early at the range's top instead,
    /// pushing that whole line/block to the next page. A range taller than a full page is cut
    /// (unavoidable, e.g. an image or code block larger than the printable area).
    private static func pageSpans(contentHeight: CGFloat, pageHeight: CGFloat,
                                  forbidden: [(lo: CGFloat, hi: CGFloat)]) -> [(CGFloat, CGFloat)] {
        guard pageHeight > 0 else { return [(0, contentHeight)] }
        var spans: [(CGFloat, CGFloat)] = []
        var start: CGFloat = 0
        let eps: CGFloat = 0.5
        var safety = 0

        while start < contentHeight - eps {
            safety += 1
            if safety > 5000 { spans.append((start, contentHeight)); break }

            var end = start + pageHeight
            if end >= contentHeight - eps {
                spans.append((start, contentHeight))
                break
            }
            // If the break falls inside a line/block, pull it up to that block's top.
            for range in forbidden where range.lo < end - eps && end < range.hi - eps {
                if range.lo > start + eps { end = range.lo }
                // else: the block is taller than a page starting here → cut is unavoidable.
                break
            }
            if end <= start + eps { end = start + pageHeight } // guarantee forward progress
            spans.append((start, end))
            start = end
        }
        if spans.isEmpty { spans.append((0, contentHeight)) }
        return spans
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
