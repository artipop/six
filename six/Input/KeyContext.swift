/// What the keyboard is pointed at when a key arrives.
///
/// This is the thing six did not have. The rail's keys come through a local key monitor — they have
/// to, a first-responder `WKWebView` answers a key equivalent before the menu bar sees it — and the
/// monitor used to decide who should get the key from one line: `firstResponder is NSText`. That
/// line is wrong in both directions. It said *yes* to the empty field a fresh window opens with, so
/// `⌥←` on a start page moved a caret across nothing instead of walking the rail; it said yes to
/// `⌥↑`, which a one-line field has no answer for at all, so the key simply did nothing. And it said
/// *nothing* about the window the key landed in, so `⌥O` toggled the overview from underneath a
/// sheet.
///
/// So the context is worked out per event, and worked out properly: which window, what kind of field
/// if any, and whether the caret in it has anywhere to go. It is derived rather than registered on
/// purpose — a stack that views push and pop is a second copy of the truth, and the copy is what
/// drifts. The window system already knows; it only had to be asked a better question, and asking it
/// is the one part of this that is platform work (`KeyEvents.swift` on the Mac).
struct KeyContext: Equatable {
    /// Which window the key landed in. The rail's keys are six's own window's and nobody else's: a
    /// sheet, a popover and a video playing full screen each have their own idea of what `Esc`
    /// means, and none of them wants the rail moving behind them.
    enum Window: Equatable { case main, elsewhere }

    /// A caret sitting in a text field, and what it could do if the key were handed to it.
    struct Field: Equatable {
        enum Kind: Equatable { case singleLine, multiLine }
        let kind: Kind
        /// There is something on the left of the caret for `⌥←` to walk over.
        let hasTextBefore: Bool
        let hasTextAfter: Bool

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
    var isOverview: Bool

    init(window: Window, field: Field? = nil, isSwitching: Bool = false, isOverview: Bool = false) {
        self.window = window
        self.field = field
        self.isSwitching = isSwitching
        self.isOverview = isOverview
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
