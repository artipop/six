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

    @Test func theCaretKeepsWordMovementOnlyWhileThereIsAWord() {
        let empty = KeyContext.Field(kind: .singleLine, hasTextBefore: false, hasTextAfter: false)
        let typed = KeyContext.Field(kind: .singleLine, hasTextBefore: true, hasTextAfter: true)
        // The start page's field is focused the moment a window opens, and it is empty. ⌥← there is
        // the only way off the window, not word movement across nothing.
        #expect(KeyBinding.Key.code(.leftArrow).yields(to: empty) == false)
        #expect(KeyBinding.Key.code(.leftArrow).yields(to: typed))
        // ⌥↑ is paragraph movement; a one-line field has no paragraphs and used to swallow it whole.
        #expect(KeyBinding.Key.code(.upArrow).yields(to: typed) == false)
        #expect(KeyBinding.Key.code(.upArrow).yields(to: .init(kind: .multiLine, hasTextBefore: true, hasTextAfter: true)))
        // A letter is not text movement in any of six's fields.
        #expect(KeyBinding.Key.letter("w", .w).yields(to: typed) == false)
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
