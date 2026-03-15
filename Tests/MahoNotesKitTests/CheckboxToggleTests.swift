import Testing
@testable import MahoNotesKit

@Suite("Checkbox Toggle")
struct CheckboxToggleTests {

    @Test("Toggle unchecked to checked")
    func toggleUncheckedToChecked() {
        let md = """
        - [ ] Buy milk
        - [ ] Write code
        """
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 0, checked: true, in: md)
        #expect(result.contains("- [x] Buy milk"))
        #expect(result.contains("- [ ] Write code"))
    }

    @Test("Toggle checked to unchecked")
    func toggleCheckedToUnchecked() {
        let md = """
        - [x] Buy milk
        - [ ] Write code
        """
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 0, checked: false, in: md)
        #expect(result.contains("- [ ] Buy milk"))
        #expect(result.contains("- [ ] Write code"))
    }

    @Test("Toggle second checkbox")
    func toggleSecond() {
        let md = """
        - [ ] First
        - [ ] Second
        - [ ] Third
        """
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 1, checked: true, in: md)
        #expect(result.contains("- [ ] First"))
        #expect(result.contains("- [x] Second"))
        #expect(result.contains("- [ ] Third"))
    }

    @Test("Nested list checkboxes")
    func nestedCheckboxes() {
        let md = """
        - [ ] Parent
          - [ ] Child 1
          - [x] Child 2
        - [ ] Another parent
        """
        // Toggle Child 1 (index 1)
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 1, checked: true, in: md)
        #expect(result.contains("- [ ] Parent"))
        #expect(result.contains("  - [x] Child 1"))
        #expect(result.contains("  - [x] Child 2"))
    }

    @Test("Asterisk and plus list markers")
    func alternativeMarkers() {
        let md = """
        * [ ] Asterisk item
        + [ ] Plus item
        - [ ] Dash item
        """
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 0, checked: true, in: md)
        #expect(result.contains("* [x] Asterisk item"))
        #expect(result.contains("+ [ ] Plus item"))

        let result2 = MarkdownHTMLRenderer.toggleCheckbox(at: 1, checked: true, in: md)
        #expect(result2.contains("+ [x] Plus item"))
    }

    @Test("Ordered list checkboxes")
    func orderedList() {
        let md = """
        1. [ ] Step one
        2. [x] Step two
        3. [ ] Step three
        """
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 0, checked: true, in: md)
        #expect(result.contains("1. [x] Step one"))

        let result2 = MarkdownHTMLRenderer.toggleCheckbox(at: 1, checked: false, in: md)
        #expect(result2.contains("2. [ ] Step two"))
    }

    @Test("Index out of range returns original")
    func outOfRange() {
        let md = "- [ ] Only one"
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 5, checked: true, in: md)
        #expect(result == md)
    }

    @Test("Negative index returns original")
    func negativeIndex() {
        let md = "- [ ] Only one"
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: -1, checked: true, in: md)
        #expect(result == md)
    }

    @Test("Mixed content with non-checkbox items")
    func mixedContent() {
        let md = """
        # Shopping List

        - [ ] Apples
        - Regular item (no checkbox)
        - [x] Bananas

        Some paragraph with [x] in it.

        - [ ] Oranges
        """
        // Toggle Bananas (index 1, because "Regular item" has no checkbox)
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 1, checked: false, in: md)
        #expect(result.contains("- [ ] Bananas"))
        // The [x] in the paragraph should NOT be touched
        #expect(result.contains("Some paragraph with [x] in it."))
    }

    @Test("Uppercase X is handled")
    func uppercaseX() {
        let md = "- [X] Done task"
        let result = MarkdownHTMLRenderer.toggleCheckbox(at: 0, checked: false, in: md)
        #expect(result.contains("- [ ] Done task"))
    }
}
