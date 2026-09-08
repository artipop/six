import Foundation

/// One thing the assistant can be asked to do about what the person is pointing at.
///
/// The catalog is the point of the whole rebuild. Every use case used to want a place of its own to
/// live — a panel, a menu item, a sheet — and the ones that never got built are the ones nobody
/// wanted to draw a panel for. Here a use case is a row: a title, where it applies, what it says to
/// the model, and where the answer lands. The three surfaces (the bar at a selection, the ⌘K line, a
/// caret in a field) all read this one list, so a new verb appears in all of them at once and adds
/// no interface at all.
///
/// `prompt` stays English even where the title is translated: it is a prompt and not an interface
/// ([docs/localization.md](../../docs/localization.md)). The answer's language is the person's, and
/// the instructions say so once, for every action.
struct AssistantAction: Identifiable, Sendable, Equatable {
    /// Where the answer goes when it arrives.
    enum Landing: Sendable, Equatable {
        /// Read it and move on. The only landing a page six may not write to can have.
        case show
        /// Take the selection's place.
        case replaceSelection
        /// Take everything in the field's place.
        case replaceField
        /// Go in at the caret, leaving what is already typed alone.
        case insert

        var writesToPage: Bool { self != .show }
    }

    /// What has to be true of the focus for this action to be offered.
    enum Requirement: Sendable, Equatable {
        /// Text is selected, anywhere — an article, a comment box, a table.
        case selection
        /// Text is selected inside something six can write to.
        case editableSelection
        /// A caret in a field, with nothing selected.
        case caret
        /// Nothing in particular: the page itself is the subject.
        case page
    }

    let id: String
    let title: LocalizedStringResource
    let symbol: String
    let requirement: Requirement
    let landing: Landing
    /// What the model is told to do. The subject text is appended by `AssistantStore`.
    let prompt: String
    /// Shown in the bar at the selection, rather than only in the ⌘K line's list.
    var isPrimary = false

    func applies(to focus: PageFocus) -> Bool {
        switch requirement {
        case .selection: focus.kind == .selection
        case .editableSelection: focus.kind == .selection && focus.isEditable
        case .caret: focus.kind == .caret && focus.isEditable
        case .page: true
        }
    }
}

extension AssistantAction {
    /// The catalog. Order is the order they are offered in.
    static let all: [AssistantAction] = reading + writing + composing + page

    /// What can be asked about text that is only being read — an article, a table, someone else's
    /// comment. Nothing here touches the page.
    static let reading: [AssistantAction] = [
        AssistantAction(
            id: "explain",
            title: "Explain",
            symbol: "lightbulb",
            requirement: .selection,
            landing: .show,
            prompt: "Explain the selected text in plain language. If it contains a term of art, an "
                + "abbreviation or a reference, say what it means. Be brief: a few sentences.",
            isPrimary: true),
        AssistantAction(
            id: "summarize-selection",
            title: "Summarize",
            symbol: "text.line.first.and.arrowtriangle.forward",
            requirement: .selection,
            landing: .show,
            prompt: "Summarize the selected text. Keep every claim that carries information and drop "
                + "the rest. Three sentences at most, or a short list where the text is a list.",
            isPrimary: true),
        AssistantAction(
            id: "define",
            title: "What is this?",
            symbol: "character.book.closed",
            requirement: .selection,
            landing: .show,
            prompt: "The selection is a name, a term or a phrase. Say what it is in two or three "
                + "sentences, using the page around it to disambiguate."),
        AssistantAction(
            id: "check",
            title: "Check this claim",
            symbol: "checkmark.seal",
            requirement: .selection,
            landing: .show,
            prompt: "The selection is a claim. Say whether it holds up, what it depends on, and what "
                + "would have to be true for it to be wrong. Say plainly when you do not know."),
    ]

    /// What can be done to text the person owns: their own comment, their own draft.
    static let writing: [AssistantAction] = [
        AssistantAction(
            id: "fix",
            title: "Fix Spelling and Grammar",
            symbol: "text.badge.checkmark",
            requirement: .editableSelection,
            landing: .replaceSelection,
            prompt: "Correct spelling, grammar and punctuation in the text. Keep the wording, the "
                + "register and the language exactly as they are — change nothing that is not wrong.",
            isPrimary: true),
        AssistantAction(
            id: "rewrite",
            title: "Rewrite",
            symbol: "wand.and.sparkles",
            requirement: .editableSelection,
            landing: .replaceSelection,
            prompt: "Rewrite the text so it reads clearly and naturally, in the same language and at "
                + "the same length. Keep every point it makes.",
            isPrimary: true),
        AssistantAction(
            id: "shorten",
            title: "Make It Shorter",
            symbol: "arrow.down.right.and.arrow.up.left",
            requirement: .editableSelection,
            landing: .replaceSelection,
            prompt: "Say the same thing in noticeably fewer words, in the same language. Keep the "
                + "meaning and the tone; drop the padding."),
        AssistantAction(
            id: "translate-en",
            title: "Translate to English",
            symbol: "character.bubble",
            requirement: .editableSelection,
            landing: .replaceSelection,
            prompt: "Translate the text into English. Keep the register — a casual message stays "
                + "casual. Return the translation only."),
    ]

    /// A caret in an empty box, or at the end of what is written so far.
    static let composing: [AssistantAction] = [
        AssistantAction(
            id: "continue",
            title: "Continue Writing",
            symbol: "text.append",
            requirement: .caret,
            landing: .insert,
            prompt: "Continue the text from exactly where it stops, in its language and voice. "
                + "Return only the continuation — no repetition of what is already there.",
            isPrimary: true),
        AssistantAction(
            id: "reply",
            title: "Draft a Reply",
            symbol: "arrowshape.turn.up.left",
            requirement: .caret,
            landing: .insert,
            prompt: "The field is for a reply to what is on the page. Draft one in the language of "
                + "the page: to the point, no flattery, no restating of the question. Return the "
                + "reply only.",
            isPrimary: true),
        AssistantAction(
            id: "polish-field",
            title: "Polish What Is Written",
            symbol: "text.badge.checkmark",
            requirement: .caret,
            landing: .replaceField,
            prompt: "Correct and tidy everything in the field: spelling, grammar, punctuation and "
                + "any sentence that does not parse. Keep the wording, the language and the length. "
                + "Return the whole text."),
    ]

    /// The page as a whole, for when nothing at all is pointed at.
    static let page: [AssistantAction] = [
        AssistantAction(
            id: "summarize-page",
            title: "Summarize This Page",
            symbol: "doc.text.magnifyingglass",
            requirement: .page,
            landing: .show,
            prompt: "Summarize the page: what it is, and what a person who has not read it would "
                + "need to know. Five sentences at most."),
    ]

    /// What the bar at a selection offers, and the ⌘K line lists under the field.
    static func offered(for focus: PageFocus) -> [AssistantAction] {
        all.filter { $0.applies(to: focus) }
    }

    static func primary(for focus: PageFocus) -> [AssistantAction] {
        offered(for: focus).filter(\.isPrimary)
    }

    static func action(_ id: String) -> AssistantAction? {
        all.first { $0.id == id }
    }
}
