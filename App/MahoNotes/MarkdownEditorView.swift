import SwiftUI

// MARK: - macOS (NSTextView)

#if os(macOS)
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var onSelectionChange: ((NSRange) -> Void)?

    /// Set this to a non-nil value to trigger an action application.
    /// The coordinator will read it, apply the action, and clear it.
    var pendingAction: Binding<MarkdownToolbarAction?>?

    /// Set to a non-nil string to insert arbitrary text at cursor.
    var pendingInsertion: Binding<String?>?

    /// Called when a complex action (photo/file) is tapped. Unused on macOS (breadcrumb handles it).
    var onComplexAction: ((MarkdownToolbarAction) -> Void)?

    /// Unused on macOS (keyboard accessory is iOS-only). Kept for API parity.
    var showKeyboardAccessory: Bool = false

    /// Called when an input method starts (`true`) or finishes (`false`) composing text.
    var onCompositionChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposingAwareTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.string = text

        context.coordinator.textView = textView
        (textView as? ComposingAwareTextView)?.onCompositionChange = { [weak coordinator = context.coordinator] composing in
            coordinator?.compositionChanged(composing)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // The coordinator outlives this value: hand it the current bindings and callbacks.
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }

        // While an input method is composing (Zhuyin, Pinyin, Kana…), the text view holds the
        // uncommitted "marked" text but the binding does not — AppKit only reports the text as
        // changed once it is committed. Writing the binding back at that point would throw the
        // composition away, and any view update (an auto-save, a sync, a vault reload) used to
        // do exactly that. The text is reconciled when the composition ends instead.
        context.coordinator.applyBindingTextIfNeeded(to: textView)

        let newFontSize = fontSize
        if textView.font?.pointSize != CGFloat(newFontSize), !textView.hasMarkedText() {
            textView.font = .monospacedSystemFont(ofSize: newFontSize, weight: .regular)
        }

        // Apply pending action — clear FIRST to prevent re-entrant loop
        if let actionBinding = pendingAction, let action = actionBinding.wrappedValue {
            // Clear immediately so the text mutation below doesn't re-trigger this block
            actionBinding.wrappedValue = nil

            let selectedRange = textView.selectedRange()
            if let result = MarkdownTextHelper.applyAction(action, text: textView.string, selectedRange: selectedRange) {
                textView.string = result.text
                text = result.text
                textView.setSelectedRange(result.selectedRange)
                onSelectionChange?(result.selectedRange)
            }
        }

        // Apply pending insertion — insert arbitrary text at cursor
        if let insertionBinding = pendingInsertion, let insertionText = insertionBinding.wrappedValue {
            insertionBinding.wrappedValue = nil

            let selectedRange = textView.selectedRange()
            let nsString = textView.string as NSString
            let newText = nsString.replacingCharacters(in: selectedRange, with: insertionText)
            textView.string = newText
            text = newText
            let newCursor = NSRange(location: selectedRange.location + (insertionText as NSString).length, length: 0)
            textView.setSelectedRange(newCursor)
            onSelectionChange?(newCursor)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        var isUpdating = false
        weak var textView: NSTextView?

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        /// Replace the text view's content with the binding's when something other than typing
        /// changed it (a note reloaded after sync, a checkbox toggled in the preview). Never
        /// while an input method is composing — see `updateNSView`.
        @MainActor
        func applyBindingTextIfNeeded(to textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            let text = parent.text
            guard textView.string != text else { return }

            let length = (text as NSString).length
            let selection = textView.selectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                // The new text can be shorter; a range past its end raises an exception.
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            let wasUpdating = isUpdating
            isUpdating = true
            textView.string = text
            textView.selectedRanges = selection.isEmpty ? [NSValue(range: NSRange(location: length, length: 0))] : selection
            // The undo stack describes edits to the text that was just replaced.
            textView.undoManager?.removeAllActions()
            isUpdating = wasUpdating
        }

        /// The input method started or finished composing.
        @MainActor
        func compositionChanged(_ composing: Bool) {
            parent.onCompositionChange?(composing)
            // A change that arrived mid-composition was held back; apply it now if the
            // composition was cancelled. (A commit goes through `textDidChange` instead,
            // and what the user typed is then the newer text.)
            if !composing, let textView {
                applyBindingTextIfNeeded(to: textView)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.onSelectionChange?(textView.selectedRange())
        }
    }
}

/// `NSTextView` that reports when an input method starts and stops composing.
///
/// AppKit has no delegate callback for this: marked text is set and cleared through
/// `NSTextInputClient`, and a cancelled composition (Esc) changes nothing a delegate sees.
final class ComposingAwareTextView: NSTextView {
    var onCompositionChange: (@MainActor (Bool) -> Void)?
    private var wasComposing = false

    private func reportCompositionIfChanged() {
        let composing = hasMarkedText()
        guard composing != wasComposing else { return }
        wasComposing = composing
        onCompositionChange?(composing)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        reportCompositionIfChanged()
    }

    override func unmarkText() {
        super.unmarkText()
        reportCompositionIfChanged()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        reportCompositionIfChanged()
    }
}

// MARK: - iOS (UITextView)

#else
struct MarkdownEditorView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var onSelectionChange: ((NSRange) -> Void)?
    var pendingAction: Binding<MarkdownToolbarAction?>?

    /// Set to a non-nil string to insert arbitrary text at cursor.
    var pendingInsertion: Binding<String?>?

    /// Called when a complex action (photo/file) is tapped from the keyboard accessory.
    var onComplexAction: ((MarkdownToolbarAction) -> Void)?

    /// Keyboard accessory actions for iPhone.
    var showKeyboardAccessory: Bool = false

    /// Called when an input method starts (`true`) or finishes (`false`) composing text.
    var onCompositionChange: ((Bool) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .default
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = text
        textView.allowsEditingTextAttributes = false

        context.coordinator.textView = textView

        if showKeyboardAccessory {
            textView.inputAccessoryView = context.coordinator.makeKeyboardAccessory()
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        // The coordinator outlives this value: hand it the current bindings and callbacks.
        context.coordinator.parent = self
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }

        // Replacing the text while an input method is composing would end the composition;
        // the text is reconciled once it finishes (see the macOS editor above).
        context.coordinator.applyBindingTextIfNeeded(to: textView)

        let newFontSize = fontSize
        if textView.font?.pointSize != CGFloat(newFontSize) {
            textView.font = .monospacedSystemFont(ofSize: newFontSize, weight: .regular)
        }

        // Apply pending action — clear FIRST to prevent re-entrant loop
        if let actionBinding = pendingAction, let action = actionBinding.wrappedValue {
            // Clear immediately so the text mutation below doesn't re-trigger this block
            actionBinding.wrappedValue = nil

            let selectedRange = textView.selectedRange
            if let result = MarkdownTextHelper.applyAction(action, text: textView.text, selectedRange: selectedRange) {
                textView.text = result.text
                text = result.text
                textView.selectedRange = result.selectedRange
                onSelectionChange?(result.selectedRange)
            }
        }

        // Apply pending insertion — insert arbitrary text at cursor
        if let insertionBinding = pendingInsertion, let insertionText = insertionBinding.wrappedValue {
            insertionBinding.wrappedValue = nil

            let selectedRange = textView.selectedRange
            let nsString = textView.text as NSString
            let newText = nsString.replacingCharacters(in: selectedRange, with: insertionText)
            textView.text = newText
            text = newText
            let newCursor = NSRange(location: selectedRange.location + (insertionText as NSString).length, length: 0)
            textView.selectedRange = newCursor
            onSelectionChange?(newCursor)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditorView
        var isUpdating = false
        weak var textView: UITextView?

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        private var wasComposing = false

        /// Replace the text view's content with the binding's when something other than typing
        /// changed it. Never while an input method is composing.
        @MainActor
        func applyBindingTextIfNeeded(to textView: UITextView) {
            guard textView.markedTextRange == nil, textView.text != parent.text else { return }
            let text = parent.text
            let selectedRange = textView.selectedRange
            let contentOffset = textView.contentOffset
            let wasUpdating = isUpdating
            isUpdating = true
            textView.text = text
            // Restore selection if still valid
            if selectedRange.location + selectedRange.length <= (text as NSString).length {
                textView.selectedRange = selectedRange
            }
            // Preserve scroll position (prevents jumping to bottom on text sync)
            textView.setContentOffset(contentOffset, animated: false)
            isUpdating = wasUpdating
        }

        @MainActor
        private func reportCompositionIfChanged(_ textView: UITextView) {
            let composing = textView.markedTextRange != nil
            guard composing != wasComposing else { return }
            wasComposing = composing
            parent.onCompositionChange?(composing)
            if !composing, textView.text != parent.text {
                // Nothing was committed (the composition was cancelled) and a change was held
                // back meanwhile: apply it now.
                applyBindingTextIfNeeded(to: textView)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.text = textView.text
            reportCompositionIfChanged(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.onSelectionChange?(textView.selectedRange)
        }

        // MARK: - Keyboard Accessory

        func makeKeyboardAccessory() -> UIView {
            // Only the height matters: UIKit stretches an inputAccessoryView to the
            // keyboard's width. Never size from UIScreen.main — the window is not the
            // screen in iPad multitasking or on iPhone Duo's folding displays.
            let bar = UIToolbar()
            bar.sizeToFit()
            bar.autoresizingMask = [.flexibleWidth]
            bar.isTranslucent = true

            var items: [UIBarButtonItem] = []

            for action in MarkdownToolbarAction.keyboardPrimaryActions {
                let item = UIBarButtonItem(
                    image: UIImage(systemName: action.icon),
                    style: .plain,
                    target: self,
                    action: #selector(accessoryButtonTapped(_:))
                )
                item.tag = tagForAction(action)
                items.append(item)
            }

            // More menu (···)
            let moreItem = UIBarButtonItem(
                image: UIImage(systemName: "ellipsis"),
                menu: makeOverflowMenu()
            )
            items.append(moreItem)

            // Flexible space
            items.append(UIBarButtonItem.flexibleSpace())

            // Dismiss keyboard
            let dismissItem = UIBarButtonItem(
                image: UIImage(systemName: "chevron.down"),
                style: .plain,
                target: self,
                action: #selector(dismissKeyboard)
            )
            items.append(dismissItem)

            bar.items = items
            return bar
        }

        private func makeOverflowMenu() -> UIMenu {
            let actions = MarkdownToolbarAction.keyboardOverflowActions.map { action in
                UIAction(title: action.label, image: UIImage(systemName: action.icon)) { [weak self] _ in
                    self?.applyAction(action)
                }
            }
            return UIMenu(children: actions)
        }

        @objc private func accessoryButtonTapped(_ sender: UIBarButtonItem) {
            guard let action = actionForTag(sender.tag) else { return }
            applyAction(action)
        }

        @objc private func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        private func applyAction(_ action: MarkdownToolbarAction) {
            // Complex actions (photo/file) need dedicated UI — delegate to parent
            if action.category == .complex {
                parent.onComplexAction?(action)
                return
            }
            guard let textView else { return }
            let selectedRange = textView.selectedRange
            let contentOffset = textView.contentOffset
            if let result = MarkdownTextHelper.applyAction(action, text: textView.text, selectedRange: selectedRange) {
                isUpdating = true
                textView.text = result.text
                parent.text = result.text
                textView.selectedRange = result.selectedRange
                // Preserve scroll position
                textView.setContentOffset(contentOffset, animated: false)
                isUpdating = false
                parent.onSelectionChange?(result.selectedRange)
            }
        }

        private func tagForAction(_ action: MarkdownToolbarAction) -> Int {
            MarkdownToolbarAction.allCases.firstIndex(of: action) ?? 0
        }

        private func actionForTag(_ tag: Int) -> MarkdownToolbarAction? {
            let all = MarkdownToolbarAction.allCases
            guard tag >= 0 && tag < all.count else { return nil }
            return all[all.index(all.startIndex, offsetBy: tag)]
        }
    }
}
#endif
