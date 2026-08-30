import Foundation
import Testing

@testable import SixCore

/// The two pure halves of translation, and the only ones that can be tested at all.
///
/// The DOM script and the session bridge are checked by opening pages; these are checked here
/// because their failures are invisible from the outside. A dropped last batch looks like a page
/// that was translated. A model that merges two lines shifts every id after it, and the page looks
/// translated too — just wrong, in a way that reads as a bad translator rather than a bug.
struct TranslationBatchTests {

    private func segments(_ pairs: [(Int, String)]) -> [TranslationSegment] {
        pairs.map { TranslationSegment(id: $0.0, text: $0.1) }
    }

    // MARK: chunks

    @Test func chunksSplitOnCount() {
        let input = segments((1...10).map { ($0, "word") })
        let batches = TranslationBatch.chunks(input, limit: 3, characters: 10_000)
        #expect(batches.map(\.count) == [3, 3, 3, 1])
    }

    /// The one that silently eats the end of a page.
    @Test func chunksKeepEverySegment() {
        let input = segments((1...97).map { ($0, String(repeating: "a", count: $0)) })
        let batches = TranslationBatch.chunks(input, limit: 8, characters: 200)
        #expect(batches.flatMap { $0 } == input)
    }

    @Test func chunksSplitOnCharacters() {
        let input = segments([(1, String(repeating: "a", count: 60)),
                              (2, String(repeating: "b", count: 60)),
                              (3, String(repeating: "c", count: 60))])
        let batches = TranslationBatch.chunks(input, limit: 100, characters: 100)
        #expect(batches.map { $0.map(\.id) } == [[1], [2], [3]])
    }

    /// A segment over the character budget goes on its own rather than going nowhere.
    @Test func chunksKeepAnOversizedSegment() {
        let input = segments([(1, String(repeating: "a", count: 5_000)), (2, "short")])
        let batches = TranslationBatch.chunks(input, limit: 10, characters: 100)
        #expect(batches.flatMap { $0.map(\.id) } == [1, 2])
    }

    @Test func chunksOfNothing() {
        #expect(TranslationBatch.chunks([], limit: 10, characters: 100).isEmpty)
    }

    // MARK: parse — the happy path

    @Test func parseReadsNumberedLines() {
        let input = segments([(1, "Home"), (2, "Read more")])
        let out = TranslationBatch.parse("1|Домой\n2|Читать далее", expecting: input)
        #expect(out == [1: "Домой", 2: "Читать далее"])
    }

    @Test func parseAcceptsAColonAndStraySpaces() {
        let input = segments([(1, "Home"), (2, "Read more")])
        let out = TranslationBatch.parse("  1 : Домой \n2|  Читать далее", expecting: input)
        #expect(out == [1: "Домой", 2: "Читать далее"])
    }

    // MARK: parse — the four guards

    /// Models like to introduce themselves.
    @Test func parseIgnoresCommentary() {
        let input = segments([(1, "Home")])
        let reply = "Here are the translations:\n\n1|Домой\n\nLet me know if you need anything else!"
        #expect(TranslationBatch.parse(reply, expecting: input) == [1: "Домой"])
    }

    /// Two inputs come back as one line. The survivor must keep its own id, not slide onto its
    /// neighbour's — this is the failure that makes a whole page subtly wrong.
    @Test func parseDoesNotShiftWhenALineIsMerged() {
        let input = segments([(1, "Home"), (2, "Read more"), (3, "Sign in")])
        let out = TranslationBatch.parse("1|Домой Читать далее\n3|Войти", expecting: input)
        #expect(out[1] == "Домой Читать далее")
        #expect(out[2] == nil)
        #expect(out[3] == "Войти")
    }

    /// Eleven lines for ten inputs: the extra id was never asked for and is not ours to keep.
    @Test func parseDropsIdsThatWereNotAskedFor() {
        let input = segments([(1, "Home"), (2, "Read more")])
        let out = TranslationBatch.parse("1|Домой\n2|Читать далее\n3|Ниоткуда", expecting: input)
        #expect(out.keys.sorted() == [1, 2])
    }

    @Test func parseKeepsTheFirstOfADuplicate() {
        let input = segments([(1, "Home")])
        let out = TranslationBatch.parse("1|Домой\n1|Дом", expecting: input)
        #expect(out == [1: "Домой"])
    }

    /// The model answered the text instead of translating it.
    @Test func parseRejectsAnAnswerInsteadOfATranslation() {
        let source = "What are the opening hours of the museum on a public holiday?"
        let input = segments([(1, source)])
        let reply = "1|" + String(repeating: "Музей обычно работает с десяти до шести. ", count: 8)
        #expect(TranslationBatch.parse(reply, expecting: input).isEmpty)
    }

    /// …and the model summarised instead of translating.
    @Test func parseRejectsASummary() {
        let source = String(repeating: "A long paragraph about the history of the town. ", count: 6)
        let input = segments([(1, source)])
        #expect(TranslationBatch.parse("1|Про город.", expecting: input).isEmpty)
    }

    /// The proportion guard must not fire on short text, where 3× is ordinary.
    @Test func parseKeepsShortTextThatGrows() {
        let input = segments([(1, "OK")])
        #expect(TranslationBatch.parse("1|Хорошо", expecting: input) == [1: "Хорошо"])
    }

    // MARK: The U+2028 round trip

    @Test func newlinesAndBarsSurviveTheRoundTrip() {
        let input = segments([(1, "one\ntwo"), (2, "a | b")])
        let rendered = TranslationBatch.render(input)
        #expect(rendered.split(separator: "\n").count == 2) // one line in, one line out

        // The model echoes the shape back, translating nothing.
        let out = TranslationBatch.parse(rendered, expecting: input)
        #expect(out == [1: "one\ntwo", 2: "a | b"])
    }

    // MARK: coverage

    @Test func coverageIsTheFractionThatCameBack() {
        let input = segments((1...10).map { ($0, "word") })
        let three = TranslationBatch.parse("1|a\n2|b\n3|c", expecting: input)
        #expect(TranslationBatch.coverage(three, of: input) == 0.3)
        #expect(TranslationBatch.coverage([:], of: []) == 1)
    }
}
