/// What the keyboard is pointed at when a key arrives: which window, and whether a caret is in a
/// field. Worked out per event from the window system (`KeyEvents.swift`) rather than registered.
struct KeyContext: Equatable {
    /// A sheet, a popover and a video playing full screen each have their own idea of what a key means.
    enum Window: Equatable { case main, elsewhere }

    /// A caret sitting in a text field.
    struct Field: Equatable {
        enum Kind: Equatable { case singleLine, multiLine }
        let kind: Kind
        let hasTextBefore: Bool
        let hasTextAfter: Bool
        var hasText: Bool { hasTextBefore || hasTextAfter }

        init(kind: Kind, hasTextBefore: Bool, hasTextAfter: Bool) {
            self.kind = kind
            self.hasTextBefore = hasTextBefore
            self.hasTextAfter = hasTextAfter
        }
    }

    var window: Window
    var field: Field?
    /// The ⌃Tab ring is held open. While it is, it is on top of everything else in the window.
    var isSwitching: Bool

    init(window: Window, field: Field? = nil, isSwitching: Bool = false) {
        self.window = window
        self.field = field
        self.isSwitching = isSwitching
    }
}

extension KeyContext: CustomStringConvertible {
    var description: String {
        var parts = [window == .main ? "main" : "elsewhere"]
        if isSwitching { parts.append("switcher") }
        if let field {
            parts.append("field(\(field.kind == .multiLine ? "multi" : "single")"
                         + "\(field.hasTextBefore ? " ←text" : "")\(field.hasTextAfter ? " text→" : ""))")
        }
        return parts.joined(separator: " ")
    }
}
