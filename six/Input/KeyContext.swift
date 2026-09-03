#if os(macOS)
import AppKit

/// What the keyboard is pointed at when a key arrives.
///
/// This is the thing six did not have. The rail's keys came through a local `NSEvent` monitor —
/// they have to, a first-responder `WKWebView` answers a key equivalent before the menu bar sees it
/// — and the monitor decided who should get the key from one line: `firstResponder is NSText`. That
/// line is wrong in both directions. It said *yes* to the empty field a fresh window opens with, so
/// `⌥←` on a start page moved a caret across nothing instead of walking the rail; it said yes to
/// `⌥↑`, which a one-line field has no answer for at all, so the key simply did nothing. And it said
/// *nothing* about the window the key landed in, so `⌥O` toggled the overview from underneath a
/// sheet.
///
/// So the context is worked out per event, and worked out properly: which window, what kind of field
/// if any, and whether the caret in it has anywhere to go. It is derived rather than registered on
/// purpose — a stack that views push and pop is a second copy of the truth, and the copy is what
/// drifts. AppKit already knows; it only had to be asked a better question.
struct KeyContext {
    /// Which window the key landed in. The rail's keys are six's own window's and nobody else's: a
    /// sheet, a popover and WebKit's full-screen video each have their own idea of what `⎋` means,
    /// and none of them wants the rail moving behind them.
    enum Window: Equatable { case main, elsewhere }

    /// A caret sitting in a text field, and what it could do if the key were handed to it.
    struct Field: Equatable {
        enum Kind: Equatable { case singleLine, multiLine }
        let kind: Kind
        /// There is something on the left of the caret for `⌥←` to walk over.
        let hasTextBefore: Bool
        let hasTextAfter: Bool
    }

    var window: Window
    var field: Field?
    /// The ⌃Tab ring is held open. While it is, it is on top of everything else in the window.
    var isSwitching: Bool
    var isOverview: Bool

    init(window: Window, field: Field? = nil, isSwitching: Bool = false, isOverview: Bool = false) {
        self.window = window
        self.field = field
        self.isSwitching = isSwitching
        self.isOverview = isOverview
    }

    init(event: NSEvent, isSwitching: Bool, isOverview: Bool) {
        self.window = Self.window(of: event)
        self.field = window == .main ? Self.field(in: event.window) : nil
        self.isSwitching = isSwitching
        self.isOverview = isOverview
    }

    private static func window(of event: NSEvent) -> Window {
        guard let window = event.window else { return .elsewhere }
        // A sheet, and anything hanging off the window — a popover has the window as its parent.
        if window.isSheet || window.parent != nil { return .elsewhere }
        // A video playing full screen is WebKit's own window, with its own `⎋`; that one is not ours.
        if String(describing: type(of: window)).contains("FullScreen") { return .elsewhere }
        return .main
    }

    /// AppKit edits every one-line field through a shared field editor, so the first responder for
    /// the address bar, the ⌘K line and the start page alike is an `NSText`; a `TextEditor` is an
    /// `NSTextView` that is *not* a field editor, which is the whole difference between a field with
    /// paragraphs in it and a field with a line in it.
    private static func field(in window: NSWindow?) -> Field? {
        guard let text = window?.firstResponder as? NSText else { return nil }
        let kind: Field.Kind = (text as? NSTextView).map { $0.isFieldEditor ? .singleLine : .multiLine } ?? .singleLine
        let range = text.selectedRange
        // From the storage, not from `string`: this runs on every key press, and a document window
        // is a text view with a book in it — asking that for its length must not cost the book.
        let length = (text as? NSTextView)?.textStorage?.length ?? (text.string as NSString).length
        return Field(kind: kind,
                     hasTextBefore: range.location > 0,
                     hasTextAfter: NSMaxRange(range) < length)
    }
}

extension KeyContext: CustomStringConvertible {
    var description: String {
        var parts = [window == .main ? "main" : "elsewhere"]
        if isSwitching { parts.append("switcher") }
        if isOverview { parts.append("overview") }
        if let field {
            parts.append("field(\(field.kind == .multiLine ? "multi" : "single")"
                         + "\(field.hasTextBefore ? " ←text" : "")\(field.hasTextAfter ? " text→" : ""))")
        }
        return parts.joined(separator: " ")
    }
}
#endif
