import Foundation
import Testing

@testable import SixCore

/// The keyboard, checked against the file that documents it.
///
/// [hotkeys.md](../../docs/hotkeys.md) opens by saying "the file is named so nothing here can drift
/// from the code". It said that for a year while `Esc` out of the ⌃Tab ring — a whole row, with a
/// sentence explaining it — could not fire, because it was written as a binding for no modifiers and
/// the ring is held open by one. Nobody noticed, because a documented key that does nothing is
/// indistinguishable from a key you pressed slightly wrong.
///
/// So the doc is read here and asked about, in both directions: every binding has to be written
/// down somewhere in it, and every key its rail and ring tables promise has to resolve to a binding.
/// The third test is about the table's own order, which is load-bearing — first match wins — and
/// which is how the ring's `⌃⇧Tab` was silently answered by the row above it during the rewrite.
struct KeyBindingsTests {

    // MARK: The documentation

    private static let doc: String = {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return (try? String(contentsOf: root.appending(path: "docs/hotkeys.md"), encoding: .utf8)) ?? ""
    }()

    /// Every `` `…` `` in a stretch of the doc that reads as a chord. Anything else in backticks —
    /// a type name, a path, a lone `⌥` standing for a scroll gesture — is not one and is skipped.
    private func chords(in text: String) -> Set<KeyChord> {
        var found: Set<KeyChord> = []
        for piece in text.components(separatedBy: "`").enumerated() where piece.offset % 2 == 1 {
            if let chord = KeyChord(piece.element) { found.insert(chord) }
        }
        return found
    }

    /// One `## ` section of the doc, by a word in its heading.
    private func section(_ title: String) -> String {
        let parts = Self.doc.components(separatedBy: "\n## ")
        return parts.first { $0.hasPrefix(title) || $0.contains(title) && parts.firstIndex(of: $0) != 0 } ?? ""
    }

    @Test func theDocumentationIsWhereTheTestThinksItIs() {
        #expect(Self.doc.contains("# Hotkeys"), "docs/hotkeys.md was not found next to the package")
    }

    // MARK: Both directions

    @Test func everyBindingIsWrittenDown() {
        let documented = chords(in: Self.doc)
        for binding in KeyBindings.all {
            let spellings = binding.spellings
            #expect(spellings.contains { documented.contains($0) },
                    "\(spellings.map(\.label)) — \(binding.action) is bound and docs/hotkeys.md never mentions it")
        }
    }

    @Test func everyKeyTheRailPromisesIsBound() {
        let context = KeyContext(window: .main)
        for chord in chords(in: section("The rail")) {
            #expect(binding(for: chord, in: context) != nil,
                    "docs/hotkeys.md promises \(chord.label) on the rail and nothing answers it")
        }
    }

    @Test func everyKeyTheRingPromisesIsBound() {
        let context = KeyContext(window: .main, isSwitching: true)
        for chord in chords(in: section("Flying between windows")) {
            #expect(binding(for: chord, in: context) != nil,
                    "docs/hotkeys.md promises \(chord.label) while the ⌃Tab ring is open and nothing answers it")
        }
    }

    // MARK: The caret, and the one thing that outranks it

    /// An arrow belongs to the caret while there is text to walk over — and **not** while the ⌃Tab
    /// ring is open, where nothing else in the window is being looked at. The exception was missing,
    /// so `⌃→` over a ring opened while the address field had the caret moved the caret and read as
    /// an arrow that did nothing; the doc has promised the ring answers first since it was written.
    @Test func theRingOutranksTheCaret() {
        let typing = KeyContext.Field(kind: .singleLine, hasTextBefore: true, hasTextAfter: true)
        let onTheRail = KeyContext(window: .main, field: typing)
        let inTheRing = KeyContext(window: .main, field: typing, isSwitching: true)

        // The rail's own ⌥→ steps aside for the caret.
        let rail = binding(for: KeyChord(.option, .rightArrow), in: onTheRail)
        #expect(rail?.yieldsToCaret(in: onTheRail) == true)

        // The ring's does not, and neither does the plain arrow the ring binds.
        let ring = binding(for: KeyChord([], .rightArrow), in: inTheRing)
        #expect(ring != nil)
        #expect(ring?.yieldsToCaret(in: inTheRing) == false)
    }

    /// And with no caret anywhere, nothing yields — the rule is about a field, not about a mood.
    @Test func withNoFieldNothingYields() {
        let context = KeyContext(window: .main)
        let rail = binding(for: KeyChord(.option, .rightArrow), in: context)
        #expect(rail?.yieldsToCaret(in: context) == false)
    }

    // MARK: The table's own order

    @Test func noRowIsShadowedByTheOnesAboveIt() {
        for (index, binding) in KeyBindings.all.enumerated() {
            let context = KeyContext(window: .main, isSwitching: binding.scope == .switcher)
            let reachable = binding.spellings.contains { chord in
                KeyBindings.all.firstIndex { $0.matches(chord: chord, in: context) } == index
            }
            #expect(reachable,
                    "row \(index) (\(binding.spellings.map(\.label)) → \(binding.action)) can never be reached — a row above it answers every chord it wants")
        }
    }

    // MARK: What a text field keeps

    @Test func aFieldWithTextKeepsEveryArrow() {
        let empty = KeyContext.Field(kind: .singleLine, hasTextBefore: false, hasTextAfter: false)
        // The caret at the very start of the text: under the old per-caret rule ⌥← went to the rail
        // from here, which is how holding ⌥← walked the caret home and then changed the window.
        let atStart = KeyContext.Field(kind: .singleLine, hasTextBefore: false, hasTextAfter: true)
        // The start page's field is focused the moment a window opens, and it is empty. ⌥← there is
        // the only way off the window, not word movement across nothing.
        #expect(KeyBinding.Key.code(.leftArrow).yields(to: empty) == false)
        #expect(KeyBinding.Key.code(.leftArrow).yields(to: atStart))
        // ⌥↑ in a one-line field goes to its start — text movement like the rest.
        #expect(KeyBinding.Key.code(.upArrow).yields(to: atStart))
        #expect(KeyBinding.Key.code(.home).yields(to: atStart) == false)
    }

    /// `⌥W` types «∑». In a field that is what the key is for, empty or not.
    @Test func aLetterTypedWithOptionAlwaysGoesToTheField() {
        let empty = KeyContext(window: .main, field: .init(kind: .singleLine, hasTextBefore: false, hasTextAfter: false))
        let fullWidth = binding(for: KeyChord(.option, .w), in: empty)
        #expect(fullWidth?.yieldsToCaret(in: empty) == true)
        // ⌘⇧C is reserved, and a field has no claim on it.
        let copy = binding(for: KeyChord(KeyBindings.copyAddressChord, .c), in: empty)
        #expect(copy?.yieldsToCaret(in: empty) == false)
    }

    // MARK: Who is asked first

    /// The ring, `⌘⇧C` and the `⌃⌥` rail are six's whatever has the focus; everything else is offered to it.
    @Test func onlyTheRingAndTheControlOptionRailAreReserved() {
        for binding in KeyBindings.all {
            let reserved = binding.scope == .switcher || binding.key.keyCode == .tab
                || binding.action == .leaveOverview || binding.action == .copyAddress || binding.modifiers == .exactly([.control, .option])
                || binding.modifiers == .exactly([.control, .option, .shift])
            #expect((binding.precedence == .reserved) == reserved,
                    "\(binding.spellings.map(\.label)) → \(binding.action) is \(binding.precedence)")
        }
    }

    @Test func aReservedKeyNeverYields() {
        let typing = KeyContext(window: .main, field: .init(kind: .multiLine, hasTextBefore: true, hasTextAfter: true))
        for binding in KeyBindings.all where binding.precedence == .reserved {
            #expect(binding.yieldsToCaret(in: typing) == false, "\(binding.spellings.map(\.label)) yields")
        }
    }

    /// The `⌃⌥` rail is the Mac's: on Windows `Ctrl+Alt` is AltGr, and `RailKeyLookup` reads this table.
    @Test func theControlOptionRailIsTheMacsAlone() {
        let hyper = KeyBindings.all.filter { $0.modifiers == .exactly([.control, .option]) }
        #if os(macOS)
        #expect(hyper.contains { $0.action == .focusColumn(-1) })
        #expect(hyper.contains { $0.action == .focusWorkspace(1) })
        #else
        #expect(hyper.isEmpty)
        #endif
    }

    // MARK: The layout the letters are typed on

    @Test func aLetterAnswersByPositionAsWellAsByCharacter() {
        let fullWidth = KeyBindings.all.first { $0.action == .toggleFullWidth }
        // «ц» is what the key with W on it reports on the Russian layout, and reading only that is
        // why ⌥W, ⌥O and ⌥C were dead for anyone not typing in Latin.
        #expect(fullWidth?.key.matches(code: KeyCode.w.rawValue, character: "ц") == true)
        // And on a layout that moved W somewhere else, the letter still means the letter.
        #expect(fullWidth?.key.matches(code: 0, character: "W") == true)
        #expect(fullWidth?.key.matches(code: 0, character: "q") == false)
    }

    private func binding(for chord: KeyChord, in context: KeyContext) -> KeyBinding? {
        KeyBindings.all.first { $0.matches(chord: chord, in: context) }
    }
}

private extension KeyBinding {
    /// The table asked about a written chord rather than about an event: the key by its code, and
    /// nothing typed, which is how a person reading the docs would ask.
    func matches(chord: KeyChord, in context: KeyContext) -> Bool {
        matches(code: chord.key.rawValue, character: nil, held: chord.modifiers, in: context)
    }
}
