import Foundation
import Observation
import WebKit

/// Highlights per URL, in a file of their own (`highlights.json`, like the old history): they come
/// back when the page is opened next week, whether or not the research run that made them still
/// exists. Painting them is `HighlightScript`'s job; this store only knows when to ask.
@MainActor
@Observable
final class HighlightStore {
    static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "six/highlights.json")
    }()

    private(set) var all: [Highlight] = []
    /// Wired at launch: a private profile's pages are never recorded, highlights included.
    @ObservationIgnored var isPrivate: (Profile.ID) -> Bool = { _ in false }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode([Highlight].self, from: data) {
            all = saved
        }
    }

    func highlights(for url: URL) -> [Highlight] {
        let key = Highlight.key(for: url)
        return all.filter { $0.url == key }.sorted { $0.start < $1.start }
    }

    func highlight(_ id: UUID) -> Highlight? {
        all.first { $0.id == id }
    }

    func highlight(matching raw: String) throws -> Highlight {
        let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { throw BrowserTool.Failure(message: "highlight_id is required") }
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        guard let first = matches.first else { throw BrowserTool.Failure(message: "No highlight with id \(raw)") }
        guard matches.count == 1 else { throw BrowserTool.Failure(message: "Highlight id \(raw) is ambiguous") }
        return first
    }

    func add(_ highlight: Highlight) {
        all.append(highlight)
        scheduleSave()
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        scheduleSave()
    }

    func removeAll(for url: URL) {
        let key = Highlight.key(for: url)
        all.removeAll { $0.url == key }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = all
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(snapshot).write(to: Self.url, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("[six] highlights save failed: \(error)\n".utf8))
            }
        }
    }

    // MARK: Painting

    /// After a page finishes loading: re-anchor whatever is stored for its URL. The script keeps
    /// watching the DOM for a few seconds for passages that arrive late; what never anchors is
    /// reported on the tab (`highlightNote`) rather than pretended.
    func apply(to tab: BrowserTab) {
        guard !tab.isDocument, let url = tab.currentURL else { return }
        let stored = highlights(for: url)
        tab.highlightNote = nil
        guard !stored.isEmpty else { return }
        let page = tab.page
        Task { [weak tab] in
            let result = try? await page.six(HighlightScript.apply, arguments: ["list": stored.map(\.scriptValue)])
            var missing = (result as? [String: Any])?["missing"] as? [String] ?? []
            let unsupported = (result as? [String: Any])?["unsupported"] as? String
            if !missing.isEmpty, unsupported?.isEmpty != false {
                // The page's retry budget is five seconds; ask again once it has run out.
                try? await Task.sleep(for: .milliseconds(5600))
                let later = try? await page.six(HighlightScript.status, arguments: ["ids": missing])
                missing = (later as? [String: Any])?["missing"] as? [String] ?? missing
            }
            guard let tab, tab.currentURL.map({ Highlight.key(for: $0) }) == Highlight.key(for: url) else { return }
            if let unsupported, !unsupported.isEmpty {
                tab.highlightNote = unsupported
            } else if !missing.isEmpty {
                tab.highlightNote = missing.count == 1
                    ? "A highlighted passage is no longer on this page"
                    : "\(missing.count) highlighted passages are no longer on this page"
            }
        }
    }

    /// Paints one new highlight right away (its page is loaded — it was just made there).
    func paint(_ highlight: Highlight, in tab: BrowserTab) {
        let page = tab.page
        Task { _ = try? await page.six(HighlightScript.apply, arguments: ["list": [highlight.scriptValue]]) }
    }

    /// Scrolls the window to the highlight a citation link points at. The link carries a text
    /// fragment WebKit handles by itself; this adds the precise in-app jump when the highlight is ours.
    func scroll(_ tab: BrowserTab, toHighlightMatching url: URL) {
        guard let fragment = url.fragment(percentEncoded: false), fragment.hasPrefix(":~:text=") else { return }
        let directive = String(fragment.dropFirst(":~:text=".count))
        let exact = directive.split(separator: ",").first { !$0.hasSuffix("-") && !$0.hasPrefix("-") }.map(String.init) ?? directive
        guard let match = highlights(for: url).first(where: { $0.exact.hasPrefix(exact) || exact.hasPrefix($0.exact.prefix(40)) }) else { return }
        let page = tab.page
        let id = match.id.uuidString
        Task {
            try? await Task.sleep(for: .milliseconds(600)) // give the load and the re-anchor a moment
            _ = try? await page.six(HighlightScript.scrollTo, arguments: ["id": id])
        }
    }

    /// Marks the page's current selection. Nil when nothing is selected.
    func highlightSelection(in tab: BrowserTab, note: String = "") async -> Highlight? {
        guard !tab.isDocument, !isPrivate(tab.profileID), let url = tab.currentURL else { return nil }
        let value = try? await tab.page.six(HighlightScript.selectionSelectors)
        guard let highlight = Highlight(url: Highlight.key(for: url), script: value, note: note, pageTitle: tab.title) else { return nil }
        add(highlight)
        paint(highlight, in: tab)
        return highlight
    }
}
