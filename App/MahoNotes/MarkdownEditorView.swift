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

    /// Unused on macOS (keyboard accessory is iOS-only). Kept for API parity.
    var showKeyboardAccessory: Bool = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        let newFontSize = fontSize
        if textView.font?.pointSize != CGFloat(newFontSize) {
            textView.font = .monospacedSystemFont(ofSize: newFontSize, weight: .regular)
        }

        // Apply pending action
        if let actionBinding = pendingAction, let action = actionBinding.wrappedValue {
            let selectedRange = textView.selectedRange()
            if let result = MarkdownTextHelper.applyAction(action, text: textView.string, selectedRange: selectedRange) {
                textView.string = result.text
                text = result.text
                textView.setSelectedRange(result.selectedRange)
                onSelectionChange?(result.selectedRange)
            }
            DispatchQueue.main.async {
                actionBinding.wrappedValue = nil
            }
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

// MARK: - iOS (UITextView)

#else
struct MarkdownEditorView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var onSelectionChange: ((NSRange) -> Void)?
    var pendingAction: Binding<MarkdownToolbarAction?>?

    /// Keyboard accessory actions for iPhone.
    var showKeyboardAccessory: Bool = false

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
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }

        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.text = text
            // Restore selection if still valid
            if selectedRange.location + selectedRange.length <= (text as NSString).length {
                textView.selectedRange = selectedRange
            }
        }

        let newFontSize = fontSize
        if textView.font?.pointSize != CGFloat(newFontSize) {
            textView.font = .monospacedSystemFont(ofSize: newFontSize, weight: .regular)
        }

        // Apply pending action
        if let actionBinding = pendingAction, let action = actionBinding.wrappedValue {
            let selectedRange = textView.selectedRange
            if let result = MarkdownTextHelper.applyAction(action, text: textView.text, selectedRange: selectedRange) {
                textView.text = result.text
                text = result.text
                textView.selectedRange = result.selectedRange
                onSelectionChange?(result.selectedRange)
            }
            DispatchQueue.main.async {
                actionBinding.wrappedValue = nil
            }
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

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.onSelectionChange?(textView.selectedRange)
        }

        // MARK: - Keyboard Accessory

        func makeKeyboardAccessory() -> UIView {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
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
            guard let textView else { return }
            let selectedRange = textView.selectedRange
            if let result = MarkdownTextHelper.applyAction(action, text: textView.text, selectedRange: selectedRange) {
                textView.text = result.text
                parent.text = result.text
                textView.selectedRange = result.selectedRange
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
