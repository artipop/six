import Foundation

/// Cutting a page into batches, and reading a model's answer back.
///
/// Both halves are pure: no WebKit, no `Translation`, no `FoundationModels`, nothing but
/// `Foundation`. That is what lets this file sit in `SixCore` and be reached by
/// `Tests/SixCoreTests`, which is the point — these are the two places the bugs actually live and
/// the two that cannot be found by clicking. An off-by-one in `chunks` silently drops the last
/// segment of a page. A model that merges two lines shifts every translation after it by one, and
/// the page looks *translated*, just wrong.
nonisolated enum TranslationBatch {
    // MARK: Out

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

    /// A batch as the numbered lines a model is asked for.
    ///
    /// JSON was the other option and is the wrong one: it asks a 3-billion-parameter on-device model
    /// to escape quotes, backslashes and newlines inside arbitrary page text, and one slip loses the
    /// whole batch. Numbered lines fail a line at a time, and a lost line is a paragraph left in its
    /// own language rather than a page left untranslated.
    ///
    /// A segment's own newlines become U+2028 (LINE SEPARATOR) so that one line in is one line out;
    /// `parse` puts them back.
    static func render(_ segments: [TranslationSegment]) -> String {
        segments
            .map { "\($0.id)|\(escape($0.text))" }
            .joined(separator: "\n")
    }

    // MARK: In

    /// What came back, by id. Everything the model got wrong is dropped rather than guessed at.
    ///
    /// Four things are thrown away, and each is a failure seen in the wild:
    ///
    /// 1. A line that is not `N|text` — models like to open with "Here are the translations:".
    /// 2. An id that was not asked for, and the second and later copies of one that was.
    /// 3. A translation wildly out of proportion to its source: shorter than a third or longer than
    ///    three times. This catches the two classics — the model *answering* the text instead of
    ///    translating it, and the model summarising the batch. Only applied above 40 characters,
    ///    because "OK" → "Хорошо" is a legitimate 3×.
    /// 4. A translation identical to a source that was not trivially short: the model echoed.
    ///    Kept, in fact — an untranslated line and an echoed one look the same to the page, and a
    ///    proper noun really can survive unchanged. Listed here so the omission is deliberate.
    ///
    /// The fifth guard — did enough of the batch come back to trust any of it — is the caller's,
    /// because only the caller can retry. `coverage(_:of:)` is what it asks.
    static func parse(_ reply: String, expecting segments: [TranslationSegment]) -> [Int: String] {
        let sources = Dictionary(segments.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var out: [Int: String] = [:]

        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (id, text) = split(line) else { continue }
            guard let source = sources[id], out[id] == nil else { continue }
            let translation = unescape(text)
            guard !translation.isEmpty, proportionate(translation, to: source) else { continue }
            out[id] = translation
        }
        return out
    }

    /// How much of what was asked for came back, 0...1. Below a half the batch is not worth having:
    /// the caller retries once at half the size, and gives up after that.
    static func coverage(_ translations: [Int: String], of segments: [TranslationSegment]) -> Double {
        guard !segments.isEmpty else { return 1 }
        return Double(translations.count) / Double(segments.count)
    }

    // MARK: Details

    /// `12|Дом` → `(12, "Дом")`. A colon is accepted as well as a bar, because models reach for one
    /// about as often as the other however the instruction is worded.
    private static func split(_ line: some StringProtocol) -> (Int, String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let id = Int(digits) else { return nil }
        var rest = trimmed.dropFirst(digits.count).drop { $0 == " " }
        guard let separator = rest.first, separator == "|" || separator == ":" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " }
        return (id, String(rest))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\u{2028}")
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2028}", with: "\n")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Guard 3. Counts characters rather than words, so it means the same thing in Chinese.
    private static func proportionate(_ translation: String, to source: String) -> Bool {
        let length = source.count
        guard length > 40 else { return true }
        let got = translation.count
        return got * 3 >= length && got <= length * 3
    }
}
