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
/// loaded into an offscreen `WKWebView` and captured with `WKWebView.createPDF` using an explicit
/// full-content rect. That continuous page is then sliced into A4 pages with Core Graphics
/// (`repaginate`).
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
        // syntax highlighting), images, and fonts may finish changing layout. Wait for a stable
        // layout before measuring and capturing, otherwise page-break coordinates can drift.
        await waitForStableLayout(webView)

        // Measure the vertical extent of every text line / atomic block so we can break pages
        // between them instead of through them.
        let layout = await measureLayout(webView)
        let documentHeight: CGFloat
        if let layout, layout.height > 0 {
            documentHeight = CGFloat(layout.height)
        } else {
            documentHeight = await measureDocumentHeight(webView)
        }
        let contentHeight = measuredContentHeight(webView, documentHeight: documentHeight)

        let continuousPDF = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: Self.printableWidth, height: contentHeight)
            webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }

        return try Self.repaginate(continuousPDF, layout: layout)
    }

    // MARK: - Layout measurement

    /// A compact signature used to wait until async DOM work has stopped changing page geometry.
    private struct LayoutSignature: Decodable, Equatable {
        let ready: Bool
        let fontsReady: Bool
        let pendingImages: Int
        let height: Double
        let checksum: Int

        var isReady: Bool {
            ready && fontsReady && pendingImages == 0
        }
    }

    /// One run of laid-out content that must not be split across a page boundary,
    /// in CSS-pixel document coordinates (top-down).
    struct LayoutMeasurement: Decodable, Equatable {
        let height: Double
        /// `[top, bottom]` pairs for laid-out text lines.
        let lines: [[Double]]
        /// `[top, bottom]` pairs for blocks that should stay together when they fit on a page.
        let blocks: [[Double]]
    }

    /// Wait for the rendered document to become stable. This avoids measuring a layout that later
    /// shifts when deferred scripts, images, or bundled fonts complete.
    private func waitForStableLayout(_ webView: WKWebView) async {
        var previous: LayoutSignature?
        var stableSamples = 0

        // Keep the timeout short: the exporter should not hang forever if a resource fails to load.
        for _ in 0..<30 {
            if let signature = await layoutSignature(webView), signature.isReady {
                if signature == previous {
                    stableSamples += 1
                    if stableSamples >= 2 { return }
                } else {
                    stableSamples = 0
                    previous = signature
                }
            } else {
                stableSamples = 0
                previous = nil
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func layoutSignature(_ webView: WKWebView) async -> LayoutSignature? {
        let js = """
        (function () {
          var root = document.documentElement;
          var body = document.body;
          var y = window.scrollY || 0;
          var height = Math.max(
            body ? body.scrollHeight : 0,
            root ? root.scrollHeight : 0,
            body ? body.offsetHeight : 0,
            root ? root.offsetHeight : 0
          );
          var checksum = Math.round(height * 10);
          var elements = document.body ? document.body.querySelectorAll("*") : [];
          for (var i = 0; i < elements.length; i++) {
            var el = elements[i];
            var r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) continue;
            checksum = (checksum + Math.round((r.top + y) * 10) * 31 + Math.round((r.bottom + y) * 10) * 17) % 2147483647;
          }
          var pendingImages = 0;
          var images = document.images || [];
          for (var j = 0; j < images.length; j++) {
            if (!images[j].complete) pendingImages++;
          }
          return JSON.stringify({
            ready: document.readyState === "complete",
            fontsReady: !document.fonts || document.fonts.status === "loaded",
            pendingImages: pendingImages,
            height: height,
            checksum: checksum
          });
        })();
        """
        return await withCheckedContinuation { (continuation: CheckedContinuation<LayoutSignature?, Never>) in
            webView.evaluateJavaScript(js) { result, _ in
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let signature = try? JSONDecoder().decode(LayoutSignature.self, from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: signature)
            }
        }
    }

    /// Collect the bounding boxes of every text line (via `Range.getClientRects`) plus atomic
    /// blocks (images, code blocks, tables, etc.) so pagination can avoid cutting through them.
    private func measureLayout(_ webView: WKWebView) async -> LayoutMeasurement? {
        let js = """
        (function () {
          var lines = [];
          var blocks = [];
          function push(list, t, b) {
            if (Number.isFinite(t) && Number.isFinite(b) && b > t) list.push([t, b]);
          }
          var y = window.scrollY || 0;
          var root = document.documentElement;
          var body = document.body;
          var height = Math.max(
            body ? body.scrollHeight : 0,
            root ? root.scrollHeight : 0,
            body ? body.offsetHeight : 0,
            root ? root.offsetHeight : 0
          );
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var n;
          while ((n = walker.nextNode())) {
            if (!n.nodeValue || !n.nodeValue.trim()) continue;
            if (n.parentElement && n.parentElement.closest("script, style, noscript")) continue;
            var range = document.createRange();
            range.selectNodeContents(n);
            var rects = range.getClientRects();
            for (var i = 0; i < rects.length; i++) {
              if (rects[i].height > 0) push(lines, rects[i].top + y, rects[i].bottom + y);
            }
          }
          var avoidBlocks = document.querySelectorAll("img, figure, pre, table, svg, .mermaid, hr, blockquote, h1, h2, h3, h4, h5, h6, .admonition, .math-block");
          for (var j = 0; j < avoidBlocks.length; j++) {
            var r = avoidBlocks[j].getBoundingClientRect();
            if (r.height > 0) push(blocks, r.top + y, r.bottom + y);
          }
          return JSON.stringify({ height: height, lines: lines, blocks: blocks });
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

    private func measureDocumentHeight(_ webView: WKWebView) async -> CGFloat {
        let js = """
        (function () {
          var root = document.documentElement;
          var body = document.body;
          return Math.max(
            body ? body.scrollHeight : 0,
            root ? root.scrollHeight : 0,
            body ? body.offsetHeight : 0,
            root ? root.offsetHeight : 0
          );
        })();
        """
        return await withCheckedContinuation { (continuation: CheckedContinuation<CGFloat, Never>) in
            webView.evaluateJavaScript(js) { result, _ in
                if let value = result as? NSNumber {
                    continuation.resume(returning: CGFloat(truncating: value))
                } else if let value = result as? Double {
                    continuation.resume(returning: CGFloat(value))
                } else {
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    private func measuredContentHeight(_ webView: WKWebView, documentHeight: CGFloat) -> CGFloat {
        #if os(macOS)
        let scrollContentHeight: CGFloat = 0
        #else
        let scrollContentHeight = webView.scrollView.contentSize.height
        #endif
        return max(
            documentHeight,
            scrollContentHeight,
            webView.bounds.height,
            Self.paperSize.height
        )
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
        let avoidance = breakAvoidanceRanges(layout: layout, srcHeight: srcBox.height, pageHeight: pageHeightSrc)
        let spans = pageSpans(
            contentHeight: srcBox.height,
            pageHeight: pageHeightSrc,
            lineRanges: avoidance.lines,
            blockRanges: avoidance.blocks
        )

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

    /// Merge the measured line and block boxes into non-overlapping vertical ranges (in
    /// source-PDF points, top-down) that page breaks should avoid.
    static func breakAvoidanceRanges(
        layout: LayoutMeasurement?,
        srcHeight: CGFloat,
        pageHeight: CGFloat
    ) -> (lines: [(lo: CGFloat, hi: CGFloat)], blocks: [(lo: CGFloat, hi: CGFloat)]) {
        guard let layout, layout.height > 0 else { return ([], []) }
        let ratio = srcHeight / CGFloat(layout.height)
        let lineMergeTolerance: CGFloat = 0.1
        let blockMergeTolerance: CGFloat = 0.5

        let lines = mergeRanges(
            layout.lines
                .compactMap { scaledRange($0, ratio: ratio, limit: srcHeight) }
                .sorted { $0.lo < $1.lo },
            tolerance: lineMergeTolerance
        )

        // Avoid keeping blocks together only when they can fit on a page. Long code blocks,
        // tables, or quotes still need line-safe breaks inside them.
        let blocks = mergeRanges(
            layout.blocks
                .compactMap { scaledRange($0, ratio: ratio, limit: srcHeight) }
                .filter { ($0.hi - $0.lo) < pageHeight }
                .sorted { $0.lo < $1.lo },
            tolerance: blockMergeTolerance
        )

        return (lines, blocks)
    }

    private static func scaledRange(_ pair: [Double], ratio: CGFloat, limit: CGFloat) -> (lo: CGFloat, hi: CGFloat)? {
        guard pair.count == 2 else { return nil }
        let lo = max(0, CGFloat(pair[0]) * ratio)
        let hi = min(limit, CGFloat(pair[1]) * ratio)
        guard hi > lo else { return nil }
        return (lo, hi)
    }

    private static func mergeRanges(
        _ ranges: [(lo: CGFloat, hi: CGFloat)],
        tolerance: CGFloat
    ) -> [(lo: CGFloat, hi: CGFloat)] {
        var merged: [(lo: CGFloat, hi: CGFloat)] = []
        for range in ranges {
            if var last = merged.last, range.lo <= last.hi + tolerance {
                last.hi = max(last.hi, range.hi)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Choose page boundaries (top-down, source-PDF points). Each page is at most `pageHeight`
    /// tall and never ends inside a line range. Blocks are kept together only when they can fit on
    /// a page; oversized blocks are allowed to split, but their internal text lines remain
    /// protected by `lineRanges`.
    static func pageSpans(
        contentHeight: CGFloat,
        pageHeight: CGFloat,
        lineRanges: [(lo: CGFloat, hi: CGFloat)],
        blockRanges: [(lo: CGFloat, hi: CGFloat)]
    ) -> [(CGFloat, CGFloat)] {
        guard pageHeight > 0 else { return [(0, contentHeight)] }
        var spans: [(CGFloat, CGFloat)] = []
        var start: CGFloat = 0
        let eps: CGFloat = 0.5
        let sortedLines = lineRanges.sorted { $0.lo < $1.lo }
        let sortedBlocks = blockRanges.sorted { $0.lo < $1.lo }
        var safety = 0

        while start < contentHeight - eps {
            safety += 1
            if safety > 5000 { spans.append((start, contentHeight)); break }

            var end = start + pageHeight
            if end >= contentHeight - eps {
                spans.append((start, contentHeight))
                break
            }

            end = adjustedPageEnd(
                proposedEnd: end,
                start: start,
                pageHeight: pageHeight,
                lineRanges: sortedLines,
                blockRanges: sortedBlocks,
                eps: eps
            )
            if end <= start + eps { end = start + pageHeight } // guarantee forward progress
            spans.append((start, end))
            start = end
        }
        if spans.isEmpty { spans.append((0, contentHeight)) }
        return spans
    }

    private static func adjustedPageEnd(
        proposedEnd: CGFloat,
        start: CGFloat,
        pageHeight: CGFloat,
        lineRanges: [(lo: CGFloat, hi: CGFloat)],
        blockRanges: [(lo: CGFloat, hi: CGFloat)],
        eps: CGFloat
    ) -> CGFloat {
        var end = proposedEnd
        var adjustmentCount = 0

        while adjustmentCount < 50 {
            adjustmentCount += 1
            var candidates: [(lo: CGFloat, hi: CGFloat)] = []

            for range in lineRanges where range.lo < end - eps && end < range.hi - eps {
                candidates.append(range)
            }
            for range in blockRanges where range.lo > start + eps && range.lo < end - eps && end < range.hi - eps {
                // This block can fit on a fresh page and starts below this page's top, so keep it
                // together by moving the break above the block.
                if (range.hi - range.lo) < pageHeight - eps {
                    candidates.append(range)
                }
            }

            guard let containingRange = candidates.min(by: { $0.lo < $1.lo }) else {
                return end
            }
            let adjusted = containingRange.lo
            guard adjusted > start + eps, adjusted < end - eps else {
                return end
            }
            end = adjusted
        }

        return end
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
