#if os(macOS)
import AppKit

/// The half of the keyboard that is AppKit's: an `NSEvent` and an `NSWindow`, turned into the four
/// plain values `KeyBindings` is written in terms of. Everything above this file is portable, and
/// the GTK front's equivalent is one file of the same size.

extension KeyModifiers {
    /// The modifiers a hand is on, and only those.
    ///
    /// `deviceIndependentFlagsMask` is not that set. macOS puts `.function` **and** `.numericPad` on
    /// every arrow key and `.capsLock` on everything while Caps Lock is down, so an equality test
    /// against `.option` was false for `⌥→` and had always been false — `⌥W` answered, `⌥→` never
    /// had, and the report that finally arrived was "option + arrow doesn't always work".
    init(_ flags: NSEvent.ModifierFlags) {
        self.init()
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

extension NSEvent.ModifierFlags {
    /// The same four, as AppKit spells them — for the places that still compare AppKit's own type.
    static let heldByHand: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
}

extension KeyBinding {
    func matches(_ event: NSEvent, in context: KeyContext) -> Bool {
        matches(code: event.keyCode,
                character: event.charactersIgnoringModifiers?.first,
                held: KeyModifiers(event.modifierFlags),
                in: context)
    }
}

extension KeyContext {
    init(event: NSEvent, isSwitching: Bool, isOverview: Bool) {
        let window = Self.window(of: event)
        self.init(window: window,
                  field: window == .main ? Self.field(in: event.window) : nil,
                  isSwitching: isSwitching,
                  isOverview: isOverview)
    }

    private static func window(of event: NSEvent) -> Window {
        guard let window = event.window else { return .elsewhere }
        // A sheet, and anything hanging off the window — a popover has the window as its parent.
        if window.isSheet || window.parent != nil { return .elsewhere }
        // A video playing full screen is WebKit's own window, with its own `Esc`; that one is not ours.
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

extension NSEvent {
    /// The chord this event is, as a person would write it — for the trace and the key matrix. A key
    /// the table has no name for is written by what it says on it.
    var chordLabel: String {
        let held = KeyModifiers(modifierFlags).label
        if let code = KeyCode(rawValue: keyCode) { return held + code.label }
        return held + (charactersIgnoringModifiers ?? "\(keyCode)").uppercased()
    }
}

#endif
