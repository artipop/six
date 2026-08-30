import Foundation

/// Cutting a page into the batches an engine takes one at a time.
///
/// Pure: no WebKit, no `Translation`, nothing but `Foundation`. That is what lets it sit in
/// `SixCore`, be reached by `Tests/SixCoreTests`, and be the same arithmetic on a front that
/// translates with Bergamot or ML Kit instead. It is a named function rather than a loop inline
/// because an off-by-one here silently drops the last segment of a page, and no amount of clicking
/// finds that.
nonisolated enum TranslationBatch {
    /// Segments split into batches small enough that losing one loses little, and large enough that
    /// batching pays. A single segment longer than `characters` still gets a batch of its own rather
    /// than being dropped — the page-side splitter is what keeps segments short, and if it let one
    /// through, sending it is better than losing it.
    static func chunks(
        _ segments: [TranslationSegment],
        limit: Int,
        characters: Int
    ) -> [[TranslationSegment]] {
        var batches: [[TranslationSegment]] = []
        var batch: [TranslationSegment] = []
        var count = 0
        for segment in segments {
            let length = segment.text.count
            if !batch.isEmpty, batch.count >= limit || count + length > characters {
                batches.append(batch)
                batch = []
                count = 0
            }
            batch.append(segment)
            count += length
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}
