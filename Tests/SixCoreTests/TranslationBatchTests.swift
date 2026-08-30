import Foundation
import Testing

@testable import SixCore

/// The one part of translation that is pure arithmetic, and so the one part testable here.
///
/// The DOM script and the session bridge are checked by opening real pages. This is checked here
/// because its failure is invisible from the outside: a dropped last batch looks exactly like a
/// page that was translated.
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
}
