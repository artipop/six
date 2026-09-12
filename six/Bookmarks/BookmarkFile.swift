import Foundation

/// A saved page as a file: Markdown with YAML front matter, readable in any editor a year after the
/// site is gone, and enough to rebuild the row.
///
/// Here rather than in `BookmarkStore` because it is text and a folder, and every front that can
/// read a page can keep one. The Mac writes through it from `BookmarkStore`, the others from
/// `BookmarkIndexer` — so a copy is the same file whichever machine saved it, down to the name.
nonisolated enum BookmarkFile {
    /// `<title slug>-<first 8 of the id>.md`, ASCII-folded so it is the same on any file system.
    static func name(for title: String, id: UUID) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { slug.append(Character(scalar)) }
            else if !slug.hasSuffix("-") { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.count > 60 { slug = String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        let short = String(id.uuidString.prefix(8)).lowercased()
        return (slug.isEmpty ? short : "\(slug)-\(short)") + ".md"
    }

    /// The file's whole text. `profileName` is nil where a front has no row to name the profile by,
    /// and then the line is left out rather than written empty.
    static func contents(markdown: String, byline: String, bookmark: Bookmark, profileName: String?) -> String {
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var lines = ["---", "title: \(quoted(bookmark.title))", "url: \(bookmark.url.absoluteString)", "site: \(quoted(bookmark.siteName))"]
        if !byline.isEmpty { lines.append("author: \(quoted(byline))") }
        if let image = bookmark.imageURL { lines.append("image: \(image.absoluteString)") }
        if !bookmark.language.isEmpty { lines.append("language: \(bookmark.language)") }
        if let profileName { lines.append("profile: \(quoted(profileName))") }
        lines.append("saved: \(ISO8601DateFormatter().string(from: bookmark.createdAt))")
        lines.append("id: \(bookmark.id.uuidString)")
        lines.append("---")
        lines.append("")
        if !bookmark.title.isEmpty, !markdown.hasPrefix("# ") { lines.append("# \(bookmark.title)"); lines.append("") }
        lines.append(markdown)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func write(markdown: String, byline: String, bookmark: Bookmark, profileName: String?, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents(markdown: markdown, byline: byline, bookmark: bookmark, profileName: profileName)
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
