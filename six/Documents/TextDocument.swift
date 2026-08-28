import Foundation
import Observation

/// A document window's content: Markdown source, a title read off the first heading, and where it has
/// been saved. `@Observable`, so the title bar, the preview and autosave all follow the text.
@MainActor
@Observable
final class TextDocument: Identifiable {
    let id: UUID
    var text: String {
        didSet { if text != oldValue { modifiedAt = Date() } }
    }
    private(set) var modifiedAt: Date
    /// Set by the first Save As; ⌘S is a plain re-save afterwards.
    var fileURL: URL?
    /// Editing the source or reading the rendered preview. Persists with the window.
    var showsPreview: Bool

    init(id: UUID = UUID(), text: String = "", modifiedAt: Date = Date(), fileURL: URL? = nil, showsPreview: Bool = false) {
        self.id = id
        self.text = text
        self.modifiedAt = modifiedAt
        self.fileURL = fileURL
        self.showsPreview = showsPreview
    }

    /// The first heading, or the first non-empty line, or "Untitled".
    var title: String {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { return heading }
                continue
            }
            return String(line.prefix(80))
        }
        return String(localized: "Untitled")
    }

    /// A file name for exports: the title, made safe.
    var suggestedFileName: String {
        let base = title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? String(localized: "Untitled") : String(base.prefix(80))
    }

    // MARK: Section-level writes (an agent writing while the user reads)

    /// `## Heading` blocks: the text between one heading line and the next of the same or higher level.
    struct Section {
        var heading: String
        var level: Int
        var range: Range<String.Index>   // from the heading line through the section's last line
    }

    var sections: [Section] {
        Self.sections(of: text)
    }

    static func sections(of text: String) -> [Section] {
        var starts: [(heading: String, level: Int, start: String.Index)] = []
        var index = text.startIndex
        var inFence = false
        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[index..<lineEnd]
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let (level, heading) = Self.heading(of: line) {
                starts.append((heading, level, index))
            }
            index = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        var result: [Section] = []
        for (i, start) in starts.enumerated() {
            let end = starts[(i + 1)...].first { $0.level <= start.level }?.start ?? text.endIndex
            result.append(Section(heading: start.heading, level: start.level, range: start.start..<end))
        }
        return result
    }

    private static func heading(of line: Substring) -> (Int, String)? {
        var level = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == "#", level < 6 { level += 1; cursor = line.index(after: cursor) }
        guard level > 0, cursor < line.endIndex, line[cursor] == " " else { return nil }
        let heading = line[cursor...].trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : (level, heading)
    }

    /// Finds a section by heading text (case-insensitive; a prefix is enough when it is unambiguous).
    func section(named name: String) -> Section? {
        let wanted = name.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let all = sections
        if let exact = all.first(where: { $0.heading.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }
        let prefixed = all.filter { $0.heading.lowercased().hasPrefix(wanted.lowercased()) }
        return prefixed.count == 1 ? prefixed.first : nil
    }

    /// Replaces a section's body (keeps the heading line) or, when there is none, appends the section.
    func replaceSection(_ name: String, with body: String) {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let section = section(named: name) {
            let headingLine = String(repeating: "#", count: section.level) + " " + section.heading
            let replacement = headingLine + "\n\n" + body + "\n\n"
            text.replaceSubrange(section.range, with: replacement)
        } else {
            let heading = name.trimmingCharacters(in: .whitespaces)
            let line = heading.hasPrefix("#") ? heading : "## " + heading
            append(line + "\n\n" + body)
        }
    }

    func append(_ more: String) {
        let more = more.trimmingCharacters(in: .newlines)
        guard !more.isEmpty else { return }
        if text.isEmpty {
            text = more + "\n"
        } else {
            let separator = text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
            text += separator + more + "\n"
        }
    }

    /// The `## Sources` list at the end: numbered citations an agent (or `cite`) adds. Returns the
    /// number given to this one. The same URL cited twice keeps its number.
    @discardableResult
    func cite(title: String, url: URL, retrievedAt: Date = Date(), passage: String? = nil) -> Int {
        let existing = citations
        if let known = existing.first(where: { $0.url == url }) { return known.number }
        let number = (existing.map(\.number).max() ?? 0) + 1
        var line = "[\(number)]: \(url.absoluteString) \"\(title.replacingOccurrences(of: "\"", with: "'"))\""
        let date = retrievedAt.formatted(date: .abbreviated, time: .omitted)
        line += " — retrieved \(date)"
        if let passage = passage?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty {
            line += "\n    > " + passage.replacingOccurrences(of: "\n", with: " ")
        }
        if section(named: Self.sourcesHeading) != nil {
            append(line)
        } else {
            append("## \(Self.sourcesHeading)\n\n" + line)
        }
        return number
    }

    static let sourcesHeading = "Sources"

    struct Citation { var number: Int; var url: URL; var title: String }

    /// `[n]: url "title"` lines anywhere in the text.
    var citations: [Citation] {
        let pattern = #"^\[(\d+)\]:\s+(\S+)(?:\s+"([^"]*)")?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let number = Int(ns.substring(with: match.range(at: 1))),
                  let url = URL(string: ns.substring(with: match.range(at: 2))) else { return nil }
            let title = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
            return Citation(number: number, url: url, title: title)
        }
    }
}

/// Where documents live: `~/Library/Application Support/org.deffun.six/Documents/<id>.md`. The snapshot keeps only
/// the id, the title and the column; the text is here, written by a debounced autosave of its own, so
/// a long document doesn't ride along in `state.json` on every keystroke.
@MainActor
final class DocumentStore {
    static let folder: URL = {
        AppSupport.folder("Documents")
    }()

    private var pending: [UUID: Task<Void, Never>] = [:]
    private var watched: Set<UUID> = []

    static func url(for id: UUID) -> URL { folder.appending(path: "\(id.uuidString).md") }

    func load(id: UUID) -> String? {
        try? String(contentsOf: Self.url(for: id), encoding: .utf8)
    }

    /// Follows the document: every edit schedules a write, a second later, off the main thread.
    func watch(_ document: TextDocument) {
        guard watched.insert(document.id).inserted else { return }
        observe(document)
    }

    private func observe(_ document: TextDocument) {
        withObservationTracking {
            _ = document.text
        } onChange: {
            Task { @MainActor [weak self, weak document] in
                guard let self, let document, self.watched.contains(document.id) else { return }
                self.schedule(document)
                self.observe(document)
            }
        }
    }

    private func schedule(_ document: TextDocument) {
        pending[document.id]?.cancel()
        pending[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let document else { return }
            self.pending[document.id] = nil
            self.save(document)
        }
    }

    func save(_ document: TextDocument) {
        let url = Self.url(for: document.id)
        let text = document.text
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("[six] document save failed: \(error)\n".utf8))
            }
        }
    }

    /// Everything pending, now — for the way out.
    func flush(_ documents: [TextDocument]) {
        for document in documents where pending[document.id] != nil {
            pending[document.id]?.cancel()
            pending[document.id] = nil
            let url = Self.url(for: document.id)
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try? document.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A closed document window takes its file with it (the user has Save As for what is worth keeping).
    func remove(id: UUID) {
        pending[id]?.cancel()
        pending[id] = nil
        watched.remove(id)
        try? FileManager.default.removeItem(at: Self.url(for: id))
    }
}
