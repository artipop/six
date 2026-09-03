#if os(macOS)
import AppKit

/// Every key six answers itself, in one table.
///
/// Not every key it has: `⌘` belongs to the menu bar, which shows it, greys it out when it cannot
/// be pressed, and is where a person looks for it. This table is the rest — the bindings a menu
/// item cannot keep, because a first-responder `WKWebView` answers a key equivalent before the menu
/// bar is asked and keeps `⌥←` for word movement. They used to be scattered across a `Layout` menu,
/// a `View` menu and two `if` statements in a scroll monitor; they are one array now, in the order
/// [hotkeys.md](../../docs/hotkeys.md) lists them, so "which key works where" is a question you
/// answer by reading a file rather than by pressing things.
enum KeyBindings {
    /// The ring is listed first because it is on top: while `⌃` holds the cards up, nothing else in
    /// the window is being looked at.
    static let all: [KeyBinding] = [
        // MARK: The ⌃Tab ring, while it is held open
        KeyBinding(.code(.tab), .exactly([.control, .shift]), .switcher, .stepSwitcher(-1)),
        KeyBinding(.code(.tab), .any, .switcher, .stepSwitcher(1)),
        // The arrows are the reason this table exists. The ring is a row of cards drawn left to
        // right; the two keys that mean "left" and "right" used to land it and fall through.
        KeyBinding(.code(.rightArrow), .any, .switcher, .stepSwitcher(1)),
        KeyBinding(.code(.leftArrow), .any, .switcher, .stepSwitcher(-1)),
        KeyBinding(.code(.returnKey), .any, .switcher, .landSwitcher),
        KeyBinding(.code(.keypadEnter), .any, .switcher, .landSwitcher),
        // `⎋` out of the ring, which the docs have promised all along: it was written as a binding
        // for no modifiers, and the ring is held open by one.
        KeyBinding(.code(.escape), .any, .switcher, .cancelSwitcher),

        // MARK: The rail (⌥)
        KeyBinding(.code(.leftArrow), .exactly(.option), .rail, .focusColumn(-1)),
        KeyBinding(.code(.rightArrow), .exactly(.option), .rail, .focusColumn(1)),
        KeyBinding(.code(.leftArrow), .exactly([.option, .shift]), .rail, .moveColumn(-1)),
        KeyBinding(.code(.rightArrow), .exactly([.option, .shift]), .rail, .moveColumn(1)),
        KeyBinding(.code(.home), .exactly(.option), .rail, .focusColumnEdge(last: false)),
        KeyBinding(.code(.end), .exactly(.option), .rail, .focusColumnEdge(last: true)),
        KeyBinding(.code(.upArrow), .exactly(.option), .rail, .focusWorkspace(-1)),
        KeyBinding(.code(.downArrow), .exactly(.option), .rail, .focusWorkspace(1)),
        KeyBinding(.code(.upArrow), .exactly([.option, .shift]), .rail, .moveColumnToWorkspace(-1)),
        KeyBinding(.code(.downArrow), .exactly([.option, .shift]), .rail, .moveColumnToWorkspace(1)),
        KeyBinding(.letter("w", .w), .exactly(.option), .rail, .toggleFullWidth),
        KeyBinding(.letter("o", .o), .exactly(.option), .rail, .toggleOverview),
        KeyBinding(.letter("c", .c), .exactly(.option), .rail, .toggleCenterFocus),

        // MARK: Opening the ring
        KeyBinding(.code(.tab), .exactly(.control), .rail, .stepSwitcher(1)),
        KeyBinding(.code(.tab), .exactly([.control, .shift]), .rail, .stepSwitcher(-1)),

        // MARK: The two `⌥⇧` verbs the View and File menus show but cannot deliver
        KeyBinding(.letter("t", .t), .exactly([.option, .shift]), .rail, .translateSelection),
        KeyBinding(.letter("h", .h), .exactly([.option, .shift]), .rail, .highlightSelection),

        // MARK: ⎋
        KeyBinding(.code(.escape), .exactly([]), .rail, .leaveOverview)
    ]
}

/// One binding: the key, what has to be held, where it is allowed to answer, and what it does.
struct KeyBinding {
    let key: KeyBinding.Key
    let modifiers: Modifiers
    let scope: Scope
    let action: KeyAction

    init(_ key: Key, _ modifiers: Modifiers, _ scope: Scope, _ action: KeyAction) {
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
        self.action = action
    }

    /// A key, by where it sits and by what it says — both, because neither alone is enough.
    ///
    /// `⌥W` has to keep working on a Russian layout, where the key under the finger reports «ц»:
    /// that is the key code's job, and reading `charactersIgnoringModifiers` alone is why the three
    /// letter bindings were dead for anyone not typing in Latin. And it has to keep meaning W on
    /// Dvorak, where W is somewhere else entirely: that is the character's job. A letter answers to
    /// either; an arrow has no character worth reading and answers to its code.
    enum Key {
        case code(KeyCode)
        case letter(Character, KeyCode)

        func matches(_ event: NSEvent) -> Bool {
            switch self {
            case .code(let code):
                return event.keyCode == code.rawValue
            case .letter(let character, let code):
                if event.keyCode == code.rawValue { return true }
                return event.charactersIgnoringModifiers?.lowercased() == String(character)
            }
        }

        /// Whether a field with a caret in it keeps this key instead of the rail.
        ///
        /// Per key and per caret, not per field. `⌥←` is word movement and always was — but only
        /// while there is a word behind the caret to move over; on the empty field a fresh window
        /// opens with, that same key is the only way to walk off it, and the old blanket rule spent
        /// it on nothing. `⌥↑` is paragraph movement, which a one-line field does not have: there it
        /// did nothing at all, which is the worst answer a key can give. Letters, `Home` and `End`
        /// are not text movement in any of six's fields and never step aside.
        func yields(to field: KeyContext.Field) -> Bool {
            guard case .code(let code) = self else { return false }
            switch code {
            case .leftArrow: return field.hasTextBefore
            case .rightArrow: return field.hasTextAfter
            case .upArrow: return field.kind == .multiLine && field.hasTextBefore
            case .downArrow: return field.kind == .multiLine && field.hasTextAfter
            default: return false
            }
        }
    }

    /// What has to be held. `.any` is for the ring: it is held open by `⌃` and cannot also ask that
    /// nothing else be down.
    enum Modifiers {
        case exactly(NSEvent.ModifierFlags)
        case any

        /// The four keys a person actually holds. Everything else in `deviceIndependentFlagsMask` is
        /// AppKit describing the key rather than the hand on it — and comparing the lot for equality
        /// is the bug this whole file was written to find: **macOS puts `.function` and `.numericPad`
        /// on every arrow key**, so `flags == .option` was false for `⌥→` and had always been false.
        /// `⌥W` worked, `⌥→` did not, and that is exactly the shape the complaint had. Caps Lock left
        /// down took out the rest of the table the same way.
        static let held: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

        func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
            switch self {
            case .any: return true
            case .exactly(let wanted): return flags.intersection(Self.held) == wanted
            }
        }
    }

    /// Where a binding is allowed to answer.
    enum Scope {
        /// Only while the ⌃Tab ring is open.
        case switcher
        /// In six's own window: not in a sheet, not in a popover, not in WebKit's full-screen video.
        case rail
    }

    func matches(_ event: NSEvent, in context: KeyContext) -> Bool {
        guard key.matches(event) else { return false }
        guard modifiers.matches(event.modifierFlags) else { return false }
        switch scope {
        case .switcher: return context.isSwitching
        case .rail: return context.window == .main
        }
    }
}

/// Everything the table can ask for. `ContentView` is where each one turns into a call, because that
/// is the view that has the browser, the highlights and the rail all in one place.
enum KeyAction: Equatable {
    case focusColumn(Int)
    case moveColumn(Int)
    case focusColumnEdge(last: Bool)
    case focusWorkspace(Int)
    case moveColumnToWorkspace(Int)
    case toggleFullWidth
    case toggleOverview
    case toggleCenterFocus
    case translateSelection
    case highlightSelection
    case stepSwitcher(Int)
    case landSwitcher
    case cancelSwitcher
    case leaveOverview
}

/// The physical keys the table names, by the code AppKit reports for them.
enum KeyCode: UInt16 {
    case escape = 53
    case tab = 48
    case returnKey = 36
    case keypadEnter = 76
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126
    case home = 115
    case end = 119
    case c = 8
    case h = 4
    case o = 31
    case t = 17
    case w = 13
}
#endif
