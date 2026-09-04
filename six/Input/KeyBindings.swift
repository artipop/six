/// Every key six answers itself, in one table — and in no window system.
///
/// Not every key it has: `⌘` belongs to the menu bar, which shows the key, greys it out when it
/// cannot be pressed, and is where a person looks for it. This table is the rest — the bindings a
/// menu item cannot keep, because a first-responder `WKWebView` answers a key equivalent before the
/// menu bar is asked and keeps `⌥←` for word movement. They used to be scattered across a `Layout`
/// menu, a `View` menu and two `if` statements in a scroll monitor.
///
/// It is in `SixCore` on purpose, and that is a claim about what a key binding *is*: a name for a
/// key, the modifiers a hand can hold, where it may answer, and what it does — none of which is
/// AppKit's business. What is AppKit's business is turning an `NSEvent` into those four things, and
/// that is `KeyEvents.swift`, which does not ship here. Two things follow. The GTK front inherits
/// the table rather than reinventing it: it maps its own key vals onto `KeyCode` the same way the
/// Mac maps `NSEvent.keyCode`, and the answer to "what does `⌥→` do" stops being written twice. And
/// the table can be **tested against [hotkeys.md](../../docs/hotkeys.md)** — see
/// `KeyBindingsTests`, which reads that file and refuses to let either side promise a key the other
/// has never heard of. That doc has said "nothing here can drift from the code" since it was
/// written; this is the first version of it where that is enforced rather than hoped for.
enum KeyBindings {
    /// The ring is listed first because it is on top: while `⌃` holds the cards up, nothing else in
    /// the window is being looked at. Order is meaningful — the first row that matches wins — and
    /// `KeyBindingsTests` checks that no `.any` row is shadowing a narrower one written after it.
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

        // MARK: The `⌥⇧` verbs the View and File menus show but cannot deliver
        KeyBinding(.letter("t", .t), .exactly([.option, .shift]), .rail, .translateSelection),
        KeyBinding(.letter("h", .h), .exactly([.option, .shift]), .rail, .highlightSelection),
        // Picture-in-picture is the one of these that is pressed while a video has the focus, which
        // is the case a menu item is worst at: the page is first responder, it is playing, and it
        // would rather have the key.
        KeyBinding(.letter("p", .p), .exactly([.option, .shift]), .rail, .pictureInPicture),

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
    /// that is the key code's job, and reading the character alone is why the three letter bindings
    /// were dead for anyone not typing in Latin. And it has to keep meaning W on Dvorak, where W is
    /// somewhere else entirely: that is the character's job. A letter answers to either; an arrow
    /// has no character worth reading and answers to its code.
    enum Key: Equatable {
        case code(KeyCode)
        case letter(Character, KeyCode)

        var keyCode: KeyCode {
            switch self {
            case .code(let code), .letter(_, let code): return code
            }
        }

        func matches(code: UInt16, character: Character?) -> Bool {
            switch self {
            case .code(let wanted):
                return code == wanted.rawValue
            case .letter(let wanted, let fallback):
                if code == fallback.rawValue { return true }
                return character.map { Character($0.lowercased()) == wanted } ?? false
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
    enum Modifiers: Equatable {
        case exactly(KeyModifiers)
        case any

        func matches(_ held: KeyModifiers) -> Bool {
            switch self {
            case .any: return true
            case .exactly(let wanted): return held == wanted
            }
        }
    }

    /// Where a binding is allowed to answer.
    enum Scope: Equatable {
        /// Only while the ⌃Tab ring is open.
        case switcher
        /// In six's own window: not in a sheet, not in a popover, not in a video playing full screen.
        case rail

        /// The modifier that holds this scope open, and so the one a person writing the key down is
        /// already holding. The ring's `←` is written `⌃←`; the rail's is written `←`.
        var heldOpenBy: KeyModifiers { self == .switcher ? .control : [] }
    }

    func matches(code: UInt16, character: Character?, held: KeyModifiers, in context: KeyContext) -> Bool {
        guard key.matches(code: code, character: character) else { return false }
        guard modifiers.matches(held) else { return false }
        switch scope {
        case .switcher: return context.isSwitching
        case .rail: return context.window == .main
        }
    }

    /// How this binding may be written down. A `.exactly` binding has one spelling; an `.any` one
    /// has two, because a ring key is written `⌃Tab` in the row that opens the ring and `↩` in the
    /// row below it, and both of those are true sentences about the same binding.
    var spellings: [KeyChord] {
        switch modifiers {
        case .exactly(let held):
            return [KeyChord(held, key.keyCode)]
        case .any:
            return [KeyChord([], key.keyCode), KeyChord(scope.heldOpenBy, key.keyCode)]
        }
    }
}

/// Everything the table can ask for. On the Mac `ContentView` is where each one turns into a call,
/// because that is the view that has the browser, the highlights and the rail all in one place.
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
    case pictureInPicture
    case stepSwitcher(Int)
    case landSwitcher
    case cancelSwitcher
    case leaveOverview
}

/// The modifiers a hand can be on, and nothing else.
///
/// This is not a convenience over `NSEvent.ModifierFlags`; it is the fix. That type carries
/// `.function` and `.numericPad` — which macOS sets on **every** arrow key — and `.capsLock`
/// whenever Caps Lock is down, all of them inside `deviceIndependentFlagsMask`. Comparing the lot
/// for equality is why `⌥→` had never once matched a binding while `⌥W` always had. Four bits, and
/// the conversion from a platform's flags happens in one place per platform.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    /// In the order a chord is written on a Mac: ⌃⌥⇧⌘.
    static let inWritingOrder: [(KeyModifiers, Character)] = [
        (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
    ]

    var label: String { String(Self.inWritingOrder.filter { contains($0.0) }.map(\.1)) }
}

/// A chord as it is written down. `KeyChord("⌥⇧→")` round-trips through `label`, which is what lets
/// a test read the documentation and ask the table about every key it finds there.
struct KeyChord: Equatable, Hashable {
    var modifiers: KeyModifiers
    var key: KeyCode

    init(_ modifiers: KeyModifiers, _ key: KeyCode) {
        self.modifiers = modifiers
        self.key = key
    }

    init?(_ text: String) {
        var modifiers: KeyModifiers = []
        var rest = Substring(text)
        while let first = rest.first, let match = KeyModifiers.inWritingOrder.first(where: { $0.1 == first }) {
            modifiers.insert(match.0)
            rest = rest.dropFirst()
        }
        guard let key = KeyCode(label: String(rest)) else { return nil }
        self.modifiers = modifiers
        self.key = key
    }

    var label: String { modifiers.label + key.label }
}

/// The physical keys the table names. The numbers are the Mac's virtual key codes, because that is
/// the front the table was written for; a second front maps its own onto these names.
enum KeyCode: UInt16, CaseIterable, Sendable {
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
    case p = 35
    case t = 17
    case w = 13

    /// How the key is written in `docs/hotkeys.md`, in the trace, and in the key matrix.
    var label: String {
        switch self {
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .returnKey: return "↩"
        case .keypadEnter: return "⌤"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .downArrow: return "↓"
        case .upArrow: return "↑"
        case .home: return "Home"
        case .end: return "End"
        case .c: return "C"
        case .h: return "H"
        case .o: return "O"
        case .p: return "P"
        case .t: return "T"
        case .w: return "W"
        }
    }

    init?(label: String) {
        guard let match = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = match
    }
}
