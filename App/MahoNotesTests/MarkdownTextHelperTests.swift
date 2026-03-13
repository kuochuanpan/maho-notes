import Foundation
import Testing
@testable import Maho_Notes

@Suite("MarkdownTextHelper")
struct MarkdownTextHelperTests {

    // MARK: - Wrap Selection

    @Test func wrapBoldWithSelection() {
        let result = MarkdownTextHelper.wrapSelection(
            text: "hello world",
            selectedRange: NSRange(location: 6, length: 5), // "world"
            prefix: "**", suffix: "**"
        )
        #expect(result.text == "hello **world**")
        #expect(result.selectedRange == NSRange(location: 8, length: 5))
    }

    @Test func wrapBoldNoSelection() {
        let result = MarkdownTextHelper.wrapSelection(
            text: "hello world",
            selectedRange: NSRange(location: 5, length: 0), // cursor after "hello"
            prefix: "**", suffix: "**"
        )
        #expect(result.text == "hello**** world")
        #expect(result.selectedRange == NSRange(location: 7, length: 0)) // cursor between **|**
    }

    @Test func unwrapBoldWhenAlreadyWrapped() {
        let result = MarkdownTextHelper.wrapSelection(
            text: "hello **world**",
            selectedRange: NSRange(location: 8, length: 5), // "world" inside **
            prefix: "**", suffix: "**"
        )
        #expect(result.text == "hello world")
        #expect(result.selectedRange == NSRange(location: 6, length: 5))
    }

    @Test func wrapItalicWithSelection() {
        let result = MarkdownTextHelper.wrapSelection(
            text: "hello",
            selectedRange: NSRange(location: 0, length: 5),
            prefix: "*", suffix: "*"
        )
        #expect(result.text == "*hello*")
        #expect(result.selectedRange == NSRange(location: 1, length: 5))
    }

    @Test func wrapCodeNoSelection() {
        let result = MarkdownTextHelper.wrapSelection(
            text: "abc",
            selectedRange: NSRange(location: 3, length: 0),
            prefix: "`", suffix: "`"
        )
        #expect(result.text == "abc``")
        #expect(result.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test func wrapStrikethroughWithSelection() {
        let result = MarkdownTextHelper.wrapSelection(
            text: "remove this",
            selectedRange: NSRange(location: 7, length: 4), // "this"
            prefix: "~~", suffix: "~~"
        )
        #expect(result.text == "remove ~~this~~")
        #expect(result.selectedRange == NSRange(location: 9, length: 4))
    }

    // MARK: - Toggle Line Prefix

    @Test func toggleBulletListAdd() {
        let result = MarkdownTextHelper.toggleLinePrefix(
            text: "item one\nitem two",
            selectedRange: NSRange(location: 0, length: 0), // cursor at start
            prefix: "- "
        )
        #expect(result.text == "- item one\nitem two")
    }

    @Test func toggleBulletListRemove() {
        let result = MarkdownTextHelper.toggleLinePrefix(
            text: "- item one\nitem two",
            selectedRange: NSRange(location: 2, length: 0), // cursor in "item"
            prefix: "- "
        )
        #expect(result.text == "item one\nitem two")
    }

    @Test func toggleQuoteAdd() {
        let result = MarkdownTextHelper.toggleLinePrefix(
            text: "a quote",
            selectedRange: NSRange(location: 2, length: 0),
            prefix: "> "
        )
        #expect(result.text == "> a quote")
    }

    @Test func toggleQuoteRemove() {
        let result = MarkdownTextHelper.toggleLinePrefix(
            text: "> a quote",
            selectedRange: NSRange(location: 4, length: 0),
            prefix: "> "
        )
        #expect(result.text == "a quote")
    }

    @Test func toggleCheckboxAdd() {
        let result = MarkdownTextHelper.toggleLinePrefix(
            text: "task",
            selectedRange: NSRange(location: 0, length: 0),
            prefix: "- [ ] "
        )
        #expect(result.text == "- [ ] task")
    }

    @Test func toggleCheckboxRemove() {
        let result = MarkdownTextHelper.toggleLinePrefix(
            text: "- [ ] task",
            selectedRange: NSRange(location: 6, length: 0),
            prefix: "- [ ] "
        )
        #expect(result.text == "task")
    }

    // MARK: - Cycle Heading

    @Test func cycleHeadingFromNone() {
        let result = MarkdownTextHelper.cycleHeading(
            text: "Title",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(result.text == "# Title")
    }

    @Test func cycleHeadingH1toH2() {
        let result = MarkdownTextHelper.cycleHeading(
            text: "# Title",
            selectedRange: NSRange(location: 2, length: 0)
        )
        #expect(result.text == "## Title")
    }

    @Test func cycleHeadingH2toH3() {
        let result = MarkdownTextHelper.cycleHeading(
            text: "## Title",
            selectedRange: NSRange(location: 3, length: 0)
        )
        #expect(result.text == "### Title")
    }

    @Test func cycleHeadingH3toNone() {
        let result = MarkdownTextHelper.cycleHeading(
            text: "### Title",
            selectedRange: NSRange(location: 4, length: 0)
        )
        #expect(result.text == "Title")
    }

    @Test func cycleHeadingOnSecondLine() {
        let result = MarkdownTextHelper.cycleHeading(
            text: "line one\nline two",
            selectedRange: NSRange(location: 12, length: 0) // in "line two"
        )
        #expect(result.text == "line one\n# line two")
    }

    // MARK: - Insert Link

    @Test func insertLinkNoSelection() {
        let result = MarkdownTextHelper.insertLink(
            text: "hello",
            selectedRange: NSRange(location: 5, length: 0)
        )
        #expect(result.text == "hello[](url)")
        #expect(result.selectedRange == NSRange(location: 6, length: 0)) // cursor inside []
    }

    @Test func insertLinkWithSelection() {
        let result = MarkdownTextHelper.insertLink(
            text: "click here",
            selectedRange: NSRange(location: 6, length: 4) // "here"
        )
        #expect(result.text == "click [here]()")
        #expect(result.selectedRange == NSRange(location: 13, length: 0)) // cursor inside ()
    }

    // MARK: - Insert Ruby

    @Test func insertRubyNoSelection() {
        let result = MarkdownTextHelper.insertRuby(
            text: "hello",
            selectedRange: NSRange(location: 5, length: 0)
        )
        #expect(result.text == "hello{|reading}")
        #expect(result.selectedRange == NSRange(location: 6, length: 0)) // cursor before |
    }

    @Test func insertRubyWithSelection() {
        let result = MarkdownTextHelper.insertRuby(
            text: "漢字test",
            selectedRange: NSRange(location: 0, length: 2) // "漢字"
        )
        #expect(result.text == "{漢字|}test")
        #expect(result.selectedRange == NSRange(location: 4, length: 0)) // cursor after |
    }

    // MARK: - Apply Action

    @Test func applyBoldAction() {
        let result = MarkdownTextHelper.applyAction(
            .bold,
            text: "hello",
            selectedRange: NSRange(location: 0, length: 5)
        )
        #expect(result != nil)
        #expect(result?.text == "**hello**")
    }

    @Test func applyTableReturnsNil() {
        let result = MarkdownTextHelper.applyAction(
            .table,
            text: "hello",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(result == nil)
    }

    @Test func applyHeadingAction() {
        let result = MarkdownTextHelper.applyAction(
            .heading,
            text: "Title",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(result?.text == "# Title")
    }

    @Test func applyCheckboxAction() {
        let result = MarkdownTextHelper.applyAction(
            .checkbox,
            text: "todo item",
            selectedRange: NSRange(location: 0, length: 0)
        )
        #expect(result?.text == "- [ ] todo item")
    }
}
