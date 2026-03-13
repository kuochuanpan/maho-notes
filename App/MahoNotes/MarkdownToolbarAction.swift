import SwiftUI

/// Actions available in the markdown formatting toolbar.
enum MarkdownToolbarAction: String, CaseIterable, Identifiable {
    case bold
    case italic
    case strikethrough
    case heading
    case code
    case quote
    case bulletList
    case numberedList
    case checkbox
    case link
    case ruby
    case table
    case insertPhoto
    case insertFile

    var id: String { rawValue }

    // MARK: - Display

    var icon: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .heading: "number"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .quote: "text.quote"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .checkbox: "checkmark.square"
        case .link: "link"
        case .ruby: "character.phonetic"
        case .table: "tablecells"
        case .insertPhoto: "photo"
        case .insertFile: "doc"
        }
    }

    var label: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strikethrough: "Strikethrough"
        case .heading: "Heading"
        case .code: "Code"
        case .quote: "Quote"
        case .bulletList: "Bullet List"
        case .numberedList: "Numbered List"
        case .checkbox: "Checkbox"
        case .link: "Link"
        case .ruby: "Ruby"
        case .table: "Table"
        case .insertPhoto: "Insert Photo"
        case .insertFile: "Insert File"
        }
    }

    // MARK: - Keyboard Shortcuts (macOS / iPad external keyboard)

    var keyboardShortcut: (key: KeyEquivalent, modifiers: EventModifiers)? {
        switch self {
        case .bold: (key: "b", modifiers: .command)
        case .italic: (key: "i", modifiers: .command)
        case .link: (key: "k", modifiers: .command)
        case .strikethrough: (key: "x", modifiers: [.command, .shift])
        case .code: (key: "c", modifiers: [.command, .shift])
        default: nil
        }
    }

    // MARK: - Action Category

    enum Category {
        case wrap        // bold, italic, strikethrough, code
        case linePrefix  // heading, quote, bulletList, numberedList, checkbox
        case insert      // link, ruby
        case complex     // table, photo, file
    }

    var category: Category {
        switch self {
        case .bold, .italic, .strikethrough, .code: .wrap
        case .heading, .quote, .bulletList, .numberedList, .checkbox: .linePrefix
        case .link, .ruby: .insert
        case .table, .insertPhoto, .insertFile: .complex
        }
    }

    // MARK: - Toolbar Groups

    /// Primary actions shown directly in the macOS/iPad breadcrumb toolbar.
    static let breadcrumbActions: [MarkdownToolbarAction] = [
        .bold, .italic, .strikethrough, .heading, .code, .quote, .bulletList, .checkbox
    ]

    /// Overflow actions shown in the breadcrumb toolbar "+" menu.
    static let breadcrumbOverflowActions: [MarkdownToolbarAction] = [
        .link, .ruby, .table, .insertPhoto, .insertFile
    ]

    /// Primary actions for iPhone keyboard accessory.
    static let keyboardPrimaryActions: [MarkdownToolbarAction] = [
        .bold, .italic, .heading, .checkbox, .bulletList
    ]

    /// Overflow actions for iPhone keyboard accessory "more" menu.
    static let keyboardOverflowActions: [MarkdownToolbarAction] = [
        .strikethrough, .code, .quote, .numberedList, .link, .ruby,
        .table, .insertPhoto, .insertFile
    ]
}
