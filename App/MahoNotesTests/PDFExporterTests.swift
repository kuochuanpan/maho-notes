import CoreGraphics
import Testing
@testable import Maho_Notes

@Suite("NotePDFExporter Pagination")
@MainActor
struct PDFExporterTests {

    @Test func pageBreakMovesBeforeLineWhenBreakFallsInsideLine() {
        let spans = NotePDFExporter.pageSpans(
            contentHeight: 220,
            pageHeight: 100,
            lineRanges: [(lo: 90, hi: 110)],
            blockRanges: []
        )

        #expect(spans.first?.0 == 0)
        #expect(spans.first?.1 == 90)
    }

    @Test func pageBreakAdjustmentRepeatsUntilItFindsASafeGap() {
        let spans = NotePDFExporter.pageSpans(
            contentHeight: 220,
            pageHeight: 100,
            lineRanges: [(lo: 70, hi: 80)],
            blockRanges: [(lo: 75, hi: 120)]
        )

        #expect(spans.first?.1 == 70)
    }

    @Test func oversizedBlockStillAllowsLineSafeBreakInsideIt() {
        let spans = NotePDFExporter.pageSpans(
            contentHeight: 260,
            pageHeight: 100,
            lineRanges: [(lo: 95, hi: 105)],
            blockRanges: [(lo: 0, hi: 250)]
        )

        #expect(spans.first?.1 == 95)
    }

    @Test func breakAvoidanceKeepsOnlyBlocksThatFitOnAPage() {
        let layout = NotePDFExporter.LayoutMeasurement(
            height: 300,
            lines: [[95, 105]],
            blocks: [[0, 250], [120, 170]]
        )

        let ranges = NotePDFExporter.breakAvoidanceRanges(
            layout: layout,
            srcHeight: 300,
            pageHeight: 100
        )

        #expect(ranges.lines.count == 1)
        #expect(ranges.blocks.count == 1)
        #expect(ranges.blocks.first?.lo == 120)
        #expect(ranges.blocks.first?.hi == 170)
    }
}
