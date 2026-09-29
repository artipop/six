import Foundation
import Testing

@testable import SavoiaCore

/// The keyboard, checked against the file that documents it.
///
/// [hotkeys.md](../../docs/hotkeys.md) opens by saying "the file is named so nothing here can drift
/// from the code". It said that for a year while `Esc` out of the ⌃Tab ring — a whole row, with a
/// sentence explaining it — could not fire, because it was written as a binding for no modifiers and
/// the ring is held open by one. Nobody noticed, because a documented key that does nothing is
/// indistinguishable from a key you pressed slightly wrong.
///
/// So the doc is read here and asked about, in both directions: every binding has to be written
/// down somewhere in it, and every key its page and ring tables promise has to resolve to a binding.
/// The table's own order is load-bearing too — first match wins.
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

    @Test func everyKeyThePagePromisesIsBound() {
        let context = KeyContext(window: .main)
        for chord in chords(in: section("The page")) {
            #expect(binding(for: chord, in: context) != nil,
                    "docs/hotkeys.md promises \(chord.label) on a page and nothing answers it")
        }
    }

    @Test func everyKeyTheRingPromisesIsBound() {
        let context = KeyContext(window: .main, isSwitching: true)
        for chord in chords(in: section("Flying between tabs")) {
            #expect(binding(for: chord, in: context) != nil,
                    "docs/hotkeys.md promises \(chord.label) while the ⌃Tab ring is open and nothing answers it")
        }
    }

    // MARK: The caret, and the one thing that outranks it

    /// An arrow over an open ring is the ring's, even with the caret in a field with text in it.
    @Test func theRingOutranksTheCaret() {
        let typing = KeyContext.Field(kind: .singleLine, hasTextBefore: true, hasTextAfter: true)
        let inTheRing = KeyContext(window: .main, field: typing, isSwitching: true)
        let ring = binding(for: KeyChord([], .rightArrow), in: inTheRing)
        #expect(ring != nil)
        #expect(ring?.yieldsToCaret(in: inTheRing) == false)
    }

    /// With no caret anywhere, nothing yields.
    @Test func withNoFieldNothingYields() {
        let context = KeyContext(window: .main)
        let translate = binding(for: KeyChord([.option, .shift], .t), in: context)
        #expect(translate?.yieldsToCaret(in: context) == false)
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

    /// `⌥⇧T` types a character. In a field that is what the key is for.
    @Test func aLetterTypedWithOptionAlwaysGoesToTheField() {
        let empty = KeyContext(window: .main, field: .init(kind: .singleLine, hasTextBefore: false, hasTextAfter: false))
        let translate = binding(for: KeyChord([.option, .shift], .t), in: empty)
        #expect(translate?.yieldsToCaret(in: empty) == true)
        // ⌘⇧C is reserved, and a field has no claim on it.
        let copy = binding(for: KeyChord(KeyBindings.copyAddressChord, .c), in: empty)
        #expect(copy?.yieldsToCaret(in: empty) == false)
    }

    // MARK: Who is asked first

    /// The ring and `⌘⇧C` are Savoia's whatever has the focus; the `⌥⇧` verbs are offered to the page.
    @Test func onlyTheRingAndCopyAddressAreReserved() {
        for binding in KeyBindings.all {
            let reserved = binding.scope == .switcher || binding.key.keyCode == .tab || binding.action == .copyAddress
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

    // MARK: The layout the letters are typed on

    @Test func aLetterAnswersByPositionAsWellAsByCharacter() {
        let pictureInPicture = KeyBindings.all.first { $0.action == .pictureInPicture }
        // «з» is what the key with P on it reports on the Russian layout.
        #expect(pictureInPicture?.key.matches(code: KeyCode.p.rawValue, character: "з") == true)
        // And on a layout that moved P somewhere else, the letter still means the letter.
        #expect(pictureInPicture?.key.matches(code: 0, character: "P") == true)
        #expect(pictureInPicture?.key.matches(code: 0, character: "q") == false)
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
