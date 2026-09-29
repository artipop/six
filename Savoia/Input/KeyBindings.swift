/// Every key Savoia answers itself, in one table. `⌘` keys belong to the menu bar; these are the ones a
/// menu item cannot keep, because a first-responder `WKWebView` answers a key equivalent before the
/// menu bar is asked. `KeyBindingsTests` checks the table against [hotkeys.md](../../docs/hotkeys.md).
///
/// **Most of it is asked second.** A `.pageFirst` row lets the key reach the page and answers only if
/// WebKit hands it back unhandled; the ⌃Tab ring is `.reserved` and stays Savoia's whatever has the focus.
enum KeyBindings {
    /// The ring is listed first because it is on top: while `⌃` holds the cards up, nothing else in
    /// the window is being looked at. Order is meaningful — the first row that matches wins — and
    /// `KeyBindingsTests` checks that no `.any` row is shadowing a narrower one written after it.
    /// Order is meaningful — the first row that matches wins.
    static let all: [KeyBinding] = [
        // MARK: The ⌃Tab ring, while it is held open
        KeyBinding(.code(.tab), .exactly([.control, .shift]), .switcher, .stepSwitcher(-1)),
        KeyBinding(.code(.tab), .any, .switcher, .stepSwitcher(1)),
        KeyBinding(.code(.rightArrow), .any, .switcher, .walkSwitcher(1)),
        KeyBinding(.code(.leftArrow), .any, .switcher, .walkSwitcher(-1)),
        KeyBinding(.code(.returnKey), .any, .switcher, .landSwitcher),
        KeyBinding(.code(.keypadEnter), .any, .switcher, .landSwitcher),
        KeyBinding(.code(.escape), .any, .switcher, .cancelSwitcher),

        // MARK: Opening the ring
        KeyBinding(.code(.tab), .exactly(.control), .window, .stepSwitcher(1)),
        KeyBinding(.code(.tab), .exactly([.control, .shift]), .window, .stepSwitcher(-1)),

        // MARK: The `⌥⇧` verbs the View and File menus show but cannot deliver
        KeyBinding(.letter("t", .t), .exactly([.option, .shift]), .window, .translateSelection, .pageFirst),
        KeyBinding(.letter("h", .h), .exactly([.option, .shift]), .window, .highlightSelection, .pageFirst),
        KeyBinding(.letter("p", .p), .exactly([.option, .shift]), .window, .pictureInPicture, .pageFirst),

        // MARK: The address, into the pasteboard
        // Not offered to the page first: a ⌘ chord offered to a focused page never comes back.
        KeyBinding(.letter("c", .c), .exactly(copyAddressChord), .window, .copyAddress)
    ]

    static let copyAddressChord: KeyModifiers = [.command, .shift]
}

/// One binding: the key, what has to be held, where it is allowed to answer, and what it does.
struct KeyBinding {
    let key: KeyBinding.Key
    let modifiers: Modifiers
    let scope: Scope
    let action: KeyAction
    let precedence: Precedence

    /// Who is asked about a key first: Savoia, or whatever has the keyboard.
    enum Precedence: Equatable {
        /// Savoia answers before anything else sees the key: the ring, and `⌘⇧C`.
        case reserved
        /// The page is asked first, and Savoia answers only what WebKit hands back unhandled. A native
        /// text field cannot hand anything back, so for one of those `yieldsToCaret(in:)` decides.
        case pageFirst
    }

    /// Whether one of Savoia's own text fields keeps this key instead of this binding taking it. A
    /// reserved key never yields; `⌥⇧T` types a character, `⌘⇧C` types nothing.
    func yieldsToCaret(in context: KeyContext) -> Bool {
        guard context.field != nil, precedence == .pageFirst else { return false }
        if case .letter = key { return !modifiers.holds(.command) }
        return false
    }

    init(_ key: Key, _ modifiers: Modifiers, _ scope: Scope, _ action: KeyAction,
         _ precedence: Precedence = .reserved) {
        self.key = key
        self.modifiers = modifiers
        self.scope = scope
        self.action = action
        self.precedence = precedence
    }

    /// A key, by where it sits and by what it says — both, because neither alone is enough.
    ///
    /// A letter answers to its key code (the Russian layout reports «е» for T) or to its character
    /// (Dvorak puts T elsewhere); anything else answers to its code.
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
    }

    /// What has to be held. `.any` is for the ring: it is held open by `⌃` and cannot also ask that
    /// nothing else be down.
    enum Modifiers: Equatable {
        case exactly(KeyModifiers)
        case any

        func holds(_ modifier: KeyModifiers) -> Bool {
            if case .exactly(let wanted) = self { return wanted.contains(modifier) }
            return false
        }

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
        /// In Savoia's own window: not in a sheet, not in a popover, not in a video playing full screen.
        case window

        /// The modifier that holds this scope open, and so the one a person writing the key down is
        /// already holding. The ring's `←` is written `⌃←`.
        var heldOpenBy: KeyModifiers { self == .switcher ? .control : [] }
    }

    func matches(code: UInt16, character: Character?, held: KeyModifiers, in context: KeyContext) -> Bool {
        guard key.matches(code: code, character: character) else { return false }
        guard modifiers.matches(held) else { return false }
        switch scope {
        case .switcher: return context.isSwitching
        case .window: return context.window == .main
        }
    }

    /// How this binding may be written down. A `.exactly` binding has one spelling; an `.any` one
    /// has two, because a ring key is written both with the `⌃` that holds the ring open and without it.
    var spellings: [KeyChord] {
        switch modifiers {
        case .exactly(let held):
            return [KeyChord(held, key.keyCode)]
        case .any:
            return [KeyChord([], key.keyCode), KeyChord(scope.heldOpenBy, key.keyCode)]
        }
    }
}

/// Everything the table can ask for. `ContentView` turns each one into a call.
enum KeyAction: Equatable {
    case translateSelection
    case highlightSelection
    case pictureInPicture
    case copyAddress
    case stepSwitcher(Int)
    case walkSwitcher(Int)
    case landSwitcher
    case cancelSwitcher
}

/// The modifiers a hand can be on, and nothing else.
///
/// `NSEvent.ModifierFlags` also carries `.function` and `.numericPad` on every arrow key and
/// `.capsLock`, so it is never compared for equality.
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

/// The physical keys the table and the page-key fallback name, by the Mac's virtual key codes.
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
    case p = 35
    case t = 17

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
        case .p: return "P"
        case .t: return "T"
        }
    }

    init?(label: String) {
        guard let match = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = match
    }
}
