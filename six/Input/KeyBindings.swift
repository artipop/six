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
///
/// **Most of it is asked second.** A `⌥` key has a meaning on a Mac before six gives it one — word
/// movement, a typed «∑», a page scrolled by a screen, whatever a web app bound for itself — and six
/// cannot know in advance which of those the thing in front of you wants. So a `.pageFirst` row lets
/// the key reach the page, and answers only if WebKit hands it back unhandled, the way Chrome and
/// Firefox treat every shortcut they do not reserve. The `.reserved` rows are the ones that stay
/// six's whatever has the focus: the ring, and a `⌃⌥` copy of the rail's navigation for the page that
/// swallows every key it is given.
enum KeyBindings {
    /// The ring is listed first because it is on top: while `⌃` holds the cards up, nothing else in
    /// the window is being looked at. Order is meaningful — the first row that matches wins — and
    /// `KeyBindingsTests` checks that no `.any` row is shadowing a narrower one written after it.
    static let all: [KeyBinding] = table + reservedRail

    private static let table: [KeyBinding] = [
        // MARK: The ⌃Tab ring, while it is held open
        KeyBinding(.code(.tab), .exactly([.control, .shift]), .switcher, .stepSwitcher(-1)),
        KeyBinding(.code(.tab), .any, .switcher, .stepSwitcher(1)),
        // The arrows are the reason this table exists. The ring is a row of cards drawn left to
        // right; the two keys that mean "left" and "right" used to land it and fall through.
        //
        // They walk the **row** and not the memory ⌃Tab walks. The two were the same thing until the
        // row started being drawn along the rail — a split's halves keep their places there rather
        // than taking the order they were used in — and after that an arrow that answered by recency
        // would move the highlight the other way from the one it points.
        KeyBinding(.code(.rightArrow), .any, .switcher, .walkSwitcher(1)),
        KeyBinding(.code(.leftArrow), .any, .switcher, .walkSwitcher(-1)),
        KeyBinding(.code(.returnKey), .any, .switcher, .landSwitcher),
        KeyBinding(.code(.keypadEnter), .any, .switcher, .landSwitcher),
        // `⎋` out of the ring, which the docs have promised all along: it was written as a binding
        // for no modifiers, and the ring is held open by one.
        KeyBinding(.code(.escape), .any, .switcher, .cancelSwitcher),

        // MARK: The rail (⌥)
        // Every one of these is a key macOS or the page may already mean something by, so every one
        // is offered to the page first. `⌥↑` / `⌥↓` show why that is not a formality: WebKit scrolls
        // a page by a screen with them and keeps them for as long as the page *can* scroll — at its
        // bottom edge too, measured — so on an article they are the article's, and on a start page
        // or a short page they come back and step the workspace.
        KeyBinding(.code(.leftArrow), .exactly(.option), .rail, .focusColumn(-1), .pageFirst),
        KeyBinding(.code(.rightArrow), .exactly(.option), .rail, .focusColumn(1), .pageFirst),
        KeyBinding(.code(.leftArrow), .exactly([.option, .shift]), .rail, .moveColumn(-1), .pageFirst),
        KeyBinding(.code(.rightArrow), .exactly([.option, .shift]), .rail, .moveColumn(1), .pageFirst),
        KeyBinding(.code(.home), .exactly(.option), .rail, .focusColumnEdge(last: false), .pageFirst),
        KeyBinding(.code(.end), .exactly(.option), .rail, .focusColumnEdge(last: true), .pageFirst),
        KeyBinding(.code(.upArrow), .exactly(.option), .rail, .focusWorkspace(-1), .pageFirst),
        KeyBinding(.code(.downArrow), .exactly(.option), .rail, .focusWorkspace(1), .pageFirst),
        KeyBinding(.code(.upArrow), .exactly([.option, .shift]), .rail, .moveColumnToWorkspace(-1), .pageFirst),
        KeyBinding(.code(.downArrow), .exactly([.option, .shift]), .rail, .moveColumnToWorkspace(1), .pageFirst),
        KeyBinding(.letter("w", .w), .exactly(.option), .rail, .toggleFullWidth, .pageFirst),
        // ⌥S beside ⌥W: the two keys that change what a window is given, one after the other in the
        // hand. Not a ⌘ key, and not only because ⌘S is Save — it is pressed while reading a page,
        // and a focused `WKWebView` answers a key equivalent before the menu bar is asked.
        KeyBinding(.letter("s", .s), .exactly(.option), .rail, .toggleSplit, .pageFirst),
        KeyBinding(.letter("o", .o), .exactly(.option), .rail, .toggleOverview, .pageFirst),
        KeyBinding(.letter("c", .c), .exactly(.option), .rail, .toggleCenterFocus, .pageFirst),

        // MARK: Opening the ring
        KeyBinding(.code(.tab), .exactly(.control), .rail, .stepSwitcher(1)),
        KeyBinding(.code(.tab), .exactly([.control, .shift]), .rail, .stepSwitcher(-1)),

        // MARK: The `⌥⇧` verbs the View and File menus show but cannot deliver
        KeyBinding(.letter("t", .t), .exactly([.option, .shift]), .rail, .translateSelection, .pageFirst),
        KeyBinding(.letter("h", .h), .exactly([.option, .shift]), .rail, .highlightSelection, .pageFirst),
        // Picture-in-picture is the one of these that is pressed while a video has the focus, which
        // is the case a menu item is worst at: the page is first responder, it is playing, and it
        // would rather have the key.
        KeyBinding(.letter("p", .p), .exactly([.option, .shift]), .rail, .pictureInPicture, .pageFirst),

        // MARK: The address, into the pasteboard
        // **Not** offered to the page first, though Google Docs has ⌘⇧C for a word count: a ⌘ chord
        // offered to a focused page never came back through the monitor — measured, nothing copied —
        // where the ⌥ keys do. A ⌘ key is the browser's by convention, and this one stays six's.
        // ⌘⇧C, which is what Arc calls Copy URL and what the Chromium forks bind on Windows — as
        // `⌃⇧C` there, which is why the chord is asked for rather than written (`copyAddressChord`).
        // It is in the table and not only in the menu because the key is pressed while the page has
        // the focus, and a focused `WKWebView` answers a key equivalent before the menu bar is
        // asked. ⌘C is the page's own — the selection — and stays the page's.
        KeyBinding(.letter("c", .c), .exactly(copyAddressChord), .rail, .copyAddress),

        // MARK: ⎋
        KeyBinding(.code(.escape), .exactly([]), .rail, .leaveOverview),

        // MARK: ↩, in the overview
        // Into the focused window, which is what a click on its card does. The same action as ⎋ —
        // leaving puts the rail back under the focused window either way — but ↩ is the key a
        // person presses to go *into* something. Scoped to the overview rather than declined outside
        // it, as ⎋ is: a bare ↩ is every page's and every field's, and outside the overview it
        // should not so much as pass through here. And `.pageFirst`, which in the overview asks
        // only the caret: a workspace being renamed on its plate keeps its ↩ to finish the name.
        KeyBinding(.code(.returnKey), .exactly([]), .overview, .leaveOverview, .pageFirst),
        KeyBinding(.code(.keypadEnter), .exactly([]), .overview, .leaveOverview, .pageFirst)
    ]

    /// The rail's navigation again, on `⌃⌥`, and **never** offered to anything first.
    ///
    /// `⌃⌥` is the one pair of modifiers that means nothing to a Mac: `StandardKeyBinding.dict` binds
    /// `⌃⌥B`, `⌃⌥F` and `⌃⌥⌫` and no arrow, `com.apple.symbolichotkeys` has none of it, and it types no
    /// character. So these keys can be taken first without taking anything from anybody — which is
    /// what a page that swallows every key needs (a game, a remote desktop, Figma), and what a caret
    /// in a field with text in it needs, since `⌥←` there is word movement and stays that.
    ///
    /// The Mac's alone. `RailKeyLookup` reads this table on Windows, where `Ctrl+Alt` *is* AltGr and
    /// types half of a Polish keyboard.
    static let reservedRail: [KeyBinding] = {
        #if os(macOS)
        let hyper: KeyModifiers = [.control, .option]
        let move: KeyModifiers = [.control, .option, .shift]
        return [
            KeyBinding(.code(.leftArrow), .exactly(hyper), .rail, .focusColumn(-1)),
            KeyBinding(.code(.rightArrow), .exactly(hyper), .rail, .focusColumn(1)),
            KeyBinding(.code(.leftArrow), .exactly(move), .rail, .moveColumn(-1)),
            KeyBinding(.code(.rightArrow), .exactly(move), .rail, .moveColumn(1)),
            KeyBinding(.code(.upArrow), .exactly(hyper), .rail, .focusWorkspace(-1)),
            KeyBinding(.code(.downArrow), .exactly(hyper), .rail, .focusWorkspace(1)),
            KeyBinding(.code(.upArrow), .exactly(move), .rail, .moveColumnToWorkspace(-1)),
            KeyBinding(.code(.downArrow), .exactly(move), .rail, .moveColumnToWorkspace(1)),
            KeyBinding(.letter("o", .o), .exactly(hyper), .rail, .toggleOverview)
        ]
        #else
        return []
        #endif
    }()

    /// ⌘⇧C where there is a ⌘, and ⌃⇧C where there is not — the same chord under the two names the
    /// two keyboards give it, which is how every browser writes this one. The rest of the table is
    /// spelled the same everywhere because ⌥ is: it stands in for niri's `Mod` and not for a
    /// platform's habit.
    static let copyAddressChord: KeyModifiers = {
        #if os(macOS) || os(iOS)
        [.command, .shift]
        #else
        [.control, .shift]
        #endif
    }()
}

/// One binding: the key, what has to be held, where it is allowed to answer, and what it does.
struct KeyBinding {
    let key: KeyBinding.Key
    let modifiers: Modifiers
    let scope: Scope
    let action: KeyAction
    let precedence: Precedence

    /// Who is asked about a key first: six, or whatever has the keyboard.
    enum Precedence: Equatable {
        /// Six answers before anything else sees the key. The ring, and the `⌃⌥` rail.
        case reserved
        /// The page is asked first, and six answers only what WebKit hands back unhandled. A native
        /// text field cannot hand anything back, so for one of those `yieldsToCaret(in:)` decides.
        case pageFirst
    }

    /// Whether one of six's own text fields keeps this key instead of this binding taking it.
    ///
    /// The whole of the decision, in the one place it can be asked a question: `KeyRouter` had it as
    /// two lines of its own and `KeySelfTest` as a copy of them, so a rule that was true in one was
    /// only probably true in the other.
    ///
    /// **A reserved key never yields.** While ⌃Tab holds the ring open nothing else in the window is
    /// being looked at — without that, `⌃→` over a ring opened while the address field had the caret
    /// walked the *caret*, and read as an arrow that did nothing at all — and the `⌃⌥` rail is
    /// reserved precisely so that there is a way off a field with text in it.
    func yieldsToCaret(in context: KeyContext) -> Bool {
        guard let field = context.field, precedence == .pageFirst else { return false }
        // `⌥W` types «∑»; `⌘⇧C` types nothing, and a field has no use for it.
        if case .letter = key { return !modifiers.holds(.command) }
        return key.yields(to: field)
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

        /// Whether a field with a caret in it keeps this arrow instead of the rail.
        ///
        /// Per field, and not per caret. It used to be per caret — `⌥←` yielded while there was a
        /// word behind the caret — and that was a trap: hold `⌥←` in the address field and the caret
        /// walked to the start of the line and then, one press later, the *window* changed. In a
        /// field with anything in it every arrow is text movement (`⌥↑` too: in a one-line field it
        /// goes to the start), and the way out is `⌃⌥←`. On the empty field a fresh window opens
        /// with they move nothing, and there they are still the only way off it. `Home` and `End`
        /// are no-ops in Cocoa's text and never step aside.
        func yields(to field: KeyContext.Field) -> Bool {
            guard case .code(let code) = self else { return false }
            switch code {
            case .leftArrow, .rightArrow, .upArrow, .downArrow: return field.hasText
            // A field always has a use for ↩: it is how what was typed is finished.
            case .returnKey, .keypadEnter: return true
            default: return false
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
        /// In six's own window: not in a sheet, not in a popover, not in a video playing full screen.
        case rail
        /// The rail, while the overview is open.
        case overview

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
        case .overview: return context.window == .main && context.isOverview
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
    case toggleSplit
    case toggleOverview
    case toggleCenterFocus
    case translateSelection
    case highlightSelection
    case pictureInPicture
    case copyAddress
    case stepSwitcher(Int)
    case walkSwitcher(Int)
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
    case s = 1
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
        case .s: return "S"
        case .t: return "T"
        case .w: return "W"
        }
    }

    init?(label: String) {
        guard let match = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = match
    }
}
