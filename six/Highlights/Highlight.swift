import Foundation

/// A marked passage on a page, stored as every W3C Web Annotation selector at once so it can be found
/// again after the page reflows (see `HighlightScript` for the ladder that re-anchors it).
nonisolated struct Highlight: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    /// The page, without its fragment.
    var url: String
    /// TextQuoteSelector: the exact text plus ~32 characters either side.
    var exact: String
    var prefix: String = ""
    var suffix: String = ""
    /// TextPositionSelector: character offsets into the page's text at the time.
    var start: Int = 0
    var end: Int = 0
    /// RangeSelector: XPath to the start and end text nodes and offsets in them.
    var startPath: String = ""
    var startOffset: Int = 0
    var endPath: String = ""
    var endOffset: Int = 0
    var createdAt: Date = Date()
    /// Why it was marked — the question it answers, or a note.
    var note: String = ""
    /// The page's title when it was marked, for the citation line.
    var pageTitle: String = ""

    /// `url#:~:text=prefix-,exact,-suffix`: a link any browser that knows text fragments can follow.
    var textFragmentURL: String {
        var fragment = "#:~:text="
        let leading = contextWords(prefix, fromEnd: true)
        if !leading.isEmpty { fragment += Self.fragmentEscape(leading) + "-," }
        // A long quote becomes a start,end range: the directive matches the first and last few words.
        fragment += Self.fragmentEscape(exact.count > 300 ? Self.rangeStart(exact) : exact)
        if exact.count > 300 { fragment += "," + Self.fragmentEscape(Self.rangeEnd(exact)) }
        let trailing = contextWords(suffix, fromEnd: false)
        if !trailing.isEmpty { fragment += ",-" + Self.fragmentEscape(trailing) }
        return url + fragment
    }

    /// Text fragments match on words; a few whole words of context are enough, and a cut word breaks it.
    private func contextWords(_ s: String, fromEnd: Bool) -> String {
        let words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return "" }
        // Drop the (possibly partial) outer word: the prefix's first word, the suffix's last.
        let whole = fromEnd ? Array(words.dropFirst()) : Array(words.dropLast())
        let picked = fromEnd ? whole.suffix(3) : whole.prefix(3)
        return picked.joined(separator: " ")
    }

    private static func rangeStart(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
    }

    private static func rangeEnd(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).suffix(5).joined(separator: " ")
    }

    /// Percent-encoding for a text directive: everything a fragment or the directive syntax could
    /// mistake — `-`, `,`, `&`, `#`, `%` and whitespace — is escaped.
    static func fragmentEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "!$'()*+./:;=?@_~")
        return s.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// The Markdown citation: the quote as a link that scrolls to the passage.
    var markdownLink: String {
        let quote = exact.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "]", with: "\\]")
        let shown = quote.count > 160 ? String(quote.prefix(157)) + "…" : quote
        return "[\(shown)](\(textFragmentURL))"
    }

    /// What the page's JavaScript needs to re-anchor and paint it.
    var scriptValue: [String: Any] {
        ["id": id.uuidString, "exact": exact, "prefix": prefix, "suffix": suffix, "start": start, "end": end,
         "startPath": startPath, "startOffset": startOffset, "endPath": endPath, "endOffset": endOffset]
    }

    /// A highlight from what `HighlightScript` returns for a selection or a block.
    init?(url: String, script value: Any?, note: String = "", pageTitle: String = "") {
        guard let object = value as? [String: Any], let exact = object["exact"] as? String, !exact.isEmpty else { return nil }
        self.url = url
        self.exact = exact
        prefix = object["prefix"] as? String ?? ""
        suffix = object["suffix"] as? String ?? ""
        start = object["start"] as? Int ?? 0
        end = object["end"] as? Int ?? 0
        startPath = object["startPath"] as? String ?? ""
        startOffset = object["startOffset"] as? Int ?? 0
        endPath = object["endPath"] as? String ?? ""
        endOffset = object["endOffset"] as? Int ?? 0
        self.note = note
        self.pageTitle = pageTitle
    }

    init(url: String, exact: String) {
        self.url = url
        self.exact = exact
    }

    /// A URL without its fragment: highlights are keyed by the page, not by where it was scrolled.
    static func key(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}
