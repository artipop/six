import Foundation

/// Cutting a page into the passages a vector is made of.
///
/// Here rather than in `BookmarkStore` because every front that saves a bookmark has to cut it the
/// same way. The vectors in one index have to come from passages of the same shape — a chunk that
/// is a paragraph on one machine and a whole page on another is two different notions of what a hit
/// is — and `BookmarkStore.indexVersion` exists precisely to force a re-embed when this changes.
/// One implementation, so there is one thing to bump.
///
/// The rules, and why: the title and the excerpt go in as a passage of their own, because a page is
/// often found by what it is called rather than by anything in its body; paragraphs are packed up to
/// `chunkTarget` so a passage is a thought rather than a line; a paragraph longer than `maxChunk` is
/// cut at a sentence end where there is one and hard where there is not, because E5's window is 512
/// tokens and what runs past it is simply not read; and `maxChunks` is where six stops and says so
/// on the bookmark, rather than embedding a book nobody asked it to.
nonisolated enum TextChunker {
    /// Passages are cut around this many characters; a paragraph longer than `maxChunk` is split.
    static let chunkTarget = 900
    static let maxChunk = 1400
    /// Beyond this many passages a page is indexed only in part — and says so in `indexError`.
    static let maxChunks = 120
    /// Bump when chunking or pooling changes: every bookmark is then re-embedded on the next launch.
    ///
    /// Beside the rules rather than on `BookmarkStore`, because it is the rules it is versioning and
    /// because the Mac is no longer the only thing that applies them. It travels with every row, in
    /// `Bookmark.embeddingModel`, as `multilingual-e5-small@3`.
    static let indexVersion = 3

    static func chunks(title: String, excerpt: String, text: String) -> [String] {
        var result: [String] = []
        let head = [title, excerpt].filter { !$0.isEmpty }.joined(separator: "\n")
        if !head.isEmpty { result.append(head) }
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for paragraph in text.components(separatedBy: "\n\n") {
            let paragraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if current.count + paragraph.count > chunkTarget, !current.isEmpty { flush() }
            if paragraph.count > maxChunk {
                flush()
                for piece in split(paragraph, every: maxChunk) { result.append(piece) }
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
            if result.count >= maxChunks { break }
        }
        flush()
        return Array(result.prefix(maxChunks))
    }

    /// Cuts at sentence ends where it can, hard where it must.
    private static func split(_ text: String, every limit: Int) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { ".!?\n".contains($0) }).map { window.index(after: $0) } ?? window.endIndex
            let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}
