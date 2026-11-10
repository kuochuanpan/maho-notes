import Foundation
import SwiftUI
import Testing
@testable import Maho_Notes

/// What the editor does with a note whose file changed underneath it.
@Suite("Editor buffer vs. disk")
struct EditorDiskChangeTests {
    private func change(buffer: String, base: String, disk: String) -> EditorState.DiskChange {
        EditorState.diskChange(buffer: buffer, base: base, disk: disk)
    }

    @Test func unchangedFileIsLeftAlone() {
        #expect(change(buffer: "a", base: "a", disk: "a") == .none)
        // Unsaved edits, file untouched: an ordinary save.
        #expect(change(buffer: "a, edited", base: "a", disk: "a") == .none)
    }

    @Test func fileChangedAndBufferCleanShowsTheNewText() {
        #expect(change(buffer: "a", base: "a", disk: "a, from another device") == .incoming)
    }

    @Test func ownSaveReadBackIsNotAChange() {
        #expect(change(buffer: "a, edited", base: "a", disk: "a, edited") == .sameAsBuffer)
    }

    @Test func fileAndBufferBothChangedIsNeverOverwrittenEitherWay() {
        #expect(change(buffer: "a, typed here", base: "a", disk: "a, from another device") == .diverged)
    }
}

#if os(macOS)
import AppKit

/// The macOS editor and input methods. `setMarkedText` / `insertText` are what an input
/// method (Zhuyin, Pinyin, Kana…) calls on the text view through `NSTextInputClient`.
@Suite("Editor input-method composition")
@MainActor
struct EditorCompositionTests {

    /// The binding's storage — stands in for `EditorState.editingBody`.
    final class Model {
        var text: String
        var compositionEvents: [Bool] = []
        init(_ text: String) { self.text = text }
    }

    /// A text view wired to a coordinator the way `makeNSView` does it.
    struct Editor {
        let model: Model
        let coordinator: MarkdownEditorView.Coordinator
        let textView: ComposingAwareTextView
        private let scrollView: NSScrollView

        @MainActor init(_ text: String) {
            let model = Model(text)
            self.model = model
            let view = MarkdownEditorView(
                text: Binding(get: { model.text }, set: { model.text = $0 }),
                fontSize: 14,
                onCompositionChange: { model.compositionEvents.append($0) }
            )
            coordinator = MarkdownEditorView.Coordinator(view)
            scrollView = ComposingAwareTextView.scrollableTextView()
            textView = scrollView.documentView as! ComposingAwareTextView
            textView.delegate = coordinator
            textView.isRichText = false
            textView.allowsUndo = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.textView = textView
            textView.onCompositionChange = { [weak coordinator] in coordinator?.compositionChanged($0) }
        }

        /// What `updateNSView` does with the text on every SwiftUI update — an auto-save,
        /// a finished sync, a vault reload all cause one.
        @MainActor func viewUpdate() {
            coordinator.isUpdating = true
            coordinator.applyBindingTextIfNeeded(to: textView)
            coordinator.isUpdating = false
        }

        @MainActor func compose(_ marked: String) {
            textView.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        @MainActor func commit(_ text: String) {
            textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        /// Esc: the input method clears its marked text.
        @MainActor func cancelComposition() { compose("") }
    }

    /// The reported bug: typing Chinese with the candidate list open, the text being
    /// composed vanished whenever the view updated (two seconds after the last committed
    /// character the auto-save ran, and that was enough).
    @Test func viewUpdateDuringCompositionKeepsTheComposedText() {
        let editor = Editor("今天")
        editor.compose("ㄊㄧㄢ")
        editor.compose("天氣")
        // The binding does not have the composing text — AppKit reports it on commit only.
        #expect(editor.model.text == "今天")

        editor.viewUpdate()
        editor.viewUpdate()

        #expect(editor.textView.hasMarkedText())
        #expect(editor.textView.string == "今天天氣")

        editor.commit("天氣")
        #expect(!editor.textView.hasMarkedText())
        #expect(editor.model.text == "今天天氣")
        #expect(editor.model.compositionEvents == [true, false])
    }

    @Test func textChangedElsewhereIsShownWhenNotComposing() {
        let editor = Editor("a long line of text that was here before the sync")
        editor.model.text = "short"          // the note was reloaded after a sync
        editor.viewUpdate()
        #expect(editor.textView.string == "short")
        // The old selection was past the end of the new text.
        #expect(editor.textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func textChangedElsewhereWaitsForTheCompositionToEnd() {
        let editor = Editor("今天")
        editor.compose("天氣")
        editor.model.text = "今天（另一台裝置改過）"   // arrives mid-composition
        editor.viewUpdate()
        #expect(editor.textView.hasMarkedText())
        #expect(editor.textView.string == "今天天氣")

        // Cancelled: nothing was typed after all, so the new text can be shown.
        editor.cancelComposition()
        #expect(!editor.textView.hasMarkedText())
        #expect(editor.textView.string == "今天（另一台裝置改過）")
        #expect(editor.model.compositionEvents == [true, false])
    }

    @Test func committedTextWinsOverAChangeThatArrivedMeanwhile() {
        let editor = Editor("今天")
        editor.compose("天氣")
        editor.model.text = "今天（另一台裝置改過）"
        editor.viewUpdate()

        editor.commit("天氣")
        // What the user typed is in the editor and in the binding; `EditorState.saveNote()`
        // then finds the file diverged and keeps both versions.
        #expect(editor.textView.string == "今天天氣")
        #expect(editor.model.text == "今天天氣")
    }
}
#endif
