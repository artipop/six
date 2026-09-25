import Foundation
import WebKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Puts a tab into the group it is about once its page has loaded, stands it between two groups
/// when it is about both, and makes a group out of three ungrouped tabs that belong together.
/// The deciding is `TabTopics`; this is the memory and the moving.
///
/// Only a tab that is new, or has gone to another site, is moved. One the person has moved since six
/// last placed it is left alone until it goes to another site, and a group six made and the person
/// ungrouped is not made again.
@MainActor
final class TabSorter {
    private struct Seen {
        var host: String
        /// The row the tab stood in when it was last placed or looked at; any other row is the
        /// person's doing.
        var row: UUID
        var byHand = false
    }

    private struct Vector {
        var text: String
        var values: [Float]
    }

    private var seen: [UUID: Seen] = [:]
    private var vectors: [UUID: Vector] = [:]
    private var descriptions: [UUID: String] = [:]
    private var nameVectors: [String: [Float]] = [:]
    /// Tabs opened since the sorter last looked; only these are placed on their first load.
    private var arrivals: Set<UUID> = []
    private var pending: Set<UUID> = []
    /// Groups the sorter made, so an ungroup of one is taken as an answer.
    private var made: Set<UUID> = []
    private var pass: Task<Void, Never>?

    /// E5 asks for `query:` on both sides of a symmetric comparison, and on titles it separates
    /// topics better than `passage:` (0.91 against 0.77, `TabTopicsSelfTest`).
    static let role = EmbeddingRole.query

    var weights = TabTopics.Weights.standard
    var thresholds = TabTopics.Thresholds.standard

    func arrived(_ id: UUID) { arrivals.insert(id) }

    func forget(_ id: UUID) {
        seen[id] = nil
        vectors[id] = nil
        descriptions[id] = nil
        arrivals.remove(id)
    }

    /// The switch just went on: the ungrouped tabs are sorted as if they had just opened, and the
    /// ones already in a group are only noted — someone put them there.
    func sortEverything(in browser: BrowserState) {
        for row in browser.layout.strip(for: browser.selectedProfileID).workspaces {
            let ids = row.columns.flatMap(\.tabIDs)
            if row.name.isEmpty { arrivals.formUnion(ids) }
            pending.formUnion(ids)
        }
        schedule(browser)
    }

    /// A page finished loading. Its description is read now, while the page is at hand; the rest
    /// waits a moment so that a burst of loads is sorted in one pass.
    func pageFinished(_ tab: BrowserTab, in browser: BrowserState) {
        guard let page = tab.livePage else { return }
        let id = tab.id
        Task {
            // The description when the page has one; Wikipedia and many articles do not, and their
            // first real paragraph says the same thing.
            let script = """
            const m = document.querySelector('meta[name="description"], meta[property="og:description"]');
            if (m && m.content && m.content.trim().length >= 40) return m.content;
            for (const p of document.querySelectorAll('main p, article p, p')) {
              const text = p.innerText.trim();
              if (text.length >= 80) return text;
            }
            return m ? m.content : "";
            """
            let description = (try? await page.callJavaScript(script)) as? String ?? ""
            descriptions[id] = String(description.prefix(300))
            pending.insert(id)
            schedule(browser)
        }
    }

    private func schedule(_ browser: BrowserState) {
        pass?.cancel()
        pass = Task { [weak browser] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let browser else { return }
            await sort(browser)
        }
    }

    // MARK: The pass

    /// The title and the first sentence of the description, cut short. e5 finds two long texts alike
    /// for being long: a whole paragraph put a bread recipe nearer a tech news site's blurb than any
    /// title did.
    private func text(of tab: BrowserTab) -> String {
        let title = TabTopics.cleanTitle(tab.title, host: host(of: tab))
        let description = descriptions[tab.id] ?? ""
        let sentence = description.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? ""
        let brief = String(sentence.prefix(120)).trimmingCharacters(in: .whitespaces)
        return brief.isEmpty ? title : "\(title). \(brief)"
    }

    private func host(of tab: BrowserTab) -> String {
        guard let host = tab.currentURL?.host() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func isSortable(_ tab: BrowserTab) -> Bool {
        guard tab.isWebPage, let scheme = tab.currentURL?.scheme else { return false }
        return scheme == "https" || scheme == "http"
    }

    func sort(_ browser: BrowserState) async {
        let profileID = browser.selectedProfileID
        guard browser.sortsTabsByMeaning,
              browser.profiles.first(where: { $0.id == profileID })?.isPrivate == false,
              let embedder = browser.bookmarks?.embedder else { return }
        let due = pending
        pending = []

        // Every web tab in the profile gets a vector: the ones in groups are what the others are
        // measured against. A tab restored and never loaded is its saved title.
        let rows = browser.layout.strip(for: profileID).workspaces
        let tabs = rows.flatMap { $0.columns.flatMap(\.tabIDs) }.compactMap(browser.tab).filter(isSortable)
        let stale = tabs.filter { vectors[$0.id]?.text != text(of: $0) }
        let names = Set(rows.map(\.name).filter { !$0.isEmpty && nameVectors[$0] == nil })
        do {
            if !stale.isEmpty {
                let texts = stale.map(text(of:))
                let embedded = try await embedder.embed(texts, as: Self.role)
                for (tab, (text, embedding)) in zip(stale, zip(texts, embedded)) {
                    vectors[tab.id] = Vector(text: text, values: embedding.vector)
                }
            }
            if !names.isEmpty {
                let list = Array(names)
                for (name, embedding) in zip(list, try await embedder.embed(list, as: Self.role)) {
                    nameVectors[name] = embedding.vector
                }
            }
        } catch {
            Log.error(.embed, "tab sorting: \(error.localizedDescription)")
            return
        }
        // The layout may have moved while the model worked.
        guard browser.selectedProfileID == profileID, browser.sortsTabsByMeaning else { return }
        let front = browser.selectedTabID
        var moved = false
        let everyone = tabs.compactMap(features(of:))

        for id in tabs.map(\.id) where due.contains(id) {
            guard let tab = browser.tab(id) else { continue }
            let strip = browser.layout.strip(for: profileID).workspaces
            guard let row = strip.first(where: { $0.columns.contains { $0.holds(id) } }) else { continue }
            let host = host(of: tab)
            let isNew = arrivals.remove(id) != nil
            var record = seen[id] ?? Seen(host: host, row: row.id)
            if record.row != row.id { record.byHand = true }
            let wentElsewhere = seen[id] != nil && record.host != host
            if wentElsewhere { record.byHand = false }
            record.host = host
            record.row = row.id
            seen[id] = record
            // A split is two pages someone put side by side on purpose.
            guard isNew || wentElsewhere, !record.byHand,
                  row.columns.first(where: { $0.holds(id) })?.isSplit == false,
                  let features = features(of: tab) else { continue }

            let groups = strip.filter { !$0.name.isEmpty }.map { group($0, in: browser) }
            let background = TabTopics.background(of: features, among: everyone)
            let ungrouped = Set(strip.filter(\.name.isEmpty).flatMap { $0.columns.flatMap(\.tabIDs) })
            let loose = everyone.filter { $0.id != id && ungrouped.contains($0.id) }
                .map { TabTopics.cosine(features.vector, $0.vector) }.max() ?? -.infinity
            let verdict = TabTopics.classify(features, among: groups, background: background, loose: loose,
                                             weights: weights, thresholds: thresholds)
            Log.debug(.browser, String(format: "sort %@: usual %.3f, loose %.3f, ", host, background, loose)
                + groups.map { group in
                    String(format: "%@ %.3f", strip.first { $0.id == group.id }?.name ?? "", TabTopics.score(features, in: group) ?? 0)
                }
                    .joined(separator: ", ") + " → \(verdict)")
            switch verdict {
            case .group(let target) where target != row.id:
                let end = strip.first { $0.id == target }?.columns.count ?? 0
                browser.layout.placeTab(id, in: profileID, workspace: target, at: end)
                seen[id]?.row = target
                moved = true
                Log.info(.browser, "sorted \(host) into \(strip.first { $0.id == target }?.name ?? "?")")
            case .between(let from, let to, let weight):
                let lean = TilingLean(from: from, to: to, weight: weight)
                if row.columns.first(where: { $0.holds(id) })?.lean == lean { continue }
                if let bridge = browser.layout.placeTabBetween(id, in: profileID, lean: lean) {
                    seen[id]?.row = bridge
                    moved = true
                    Log.info(.browser, "sorted \(host) between two groups, \(String(format: "%.2f", weight))")
                }
            default:
                break
            }
        }

        if makeGroups(browser, profileID: profileID) { moved = true }
        if moved, let front { browser.selectTab(front) }
    }

    private func features(of tab: BrowserTab) -> TabTopics.Tab? {
        guard let vector = vectors[tab.id] else { return nil }
        // The embedded text as the title, so a name can come from the description when the titles
        // share no word ("Borscht", "Pilaf", "Sourdough" — all three are dishes).
        return TabTopics.Tab(id: tab.id, vector: vector.values, host: host(of: tab), title: vector.text,
                             opener: tab.openedFrom)
    }

    private func group(_ row: TilingWorkspace, in browser: BrowserState) -> TabTopics.Group {
        let members = row.columns.flatMap(\.tabIDs).compactMap(browser.tab).compactMap(features(of:))
        return TabTopics.Group(id: row.id, name: nameVectors[row.name], members: members)
    }

    // MARK: New groups

    /// Ungrouped tabs the sorter has seen and nobody placed by hand, clustered; each cluster becomes
    /// a group just after the row its first tab was in.
    private func makeGroups(_ browser: BrowserState, profileID: UUID) -> Bool {
        var strip = browser.layout.strip(for: profileID).workspaces
        for row in strip where made.contains(row.id) && row.name.isEmpty {
            made.remove(row.id)
            for id in row.columns.flatMap(\.tabIDs) { seen[id]?.byHand = true }
        }
        let loose = strip.filter(\.name.isEmpty).flatMap(\.columns)
            .filter { !$0.isSplit && $0.lean == nil }
            .map(\.tabID)
            .filter { seen[$0].map { !$0.byHand } == true }
            .compactMap(browser.tab).compactMap(features(of:))
        let everyone = strip.flatMap { $0.columns.flatMap(\.tabIDs) }.compactMap(browser.tab).compactMap(features(of:))
        let clusters = TabTopics.clusters(loose, context: everyone, weights: weights, thresholds: thresholds)
        guard !clusters.isEmpty else { return false }
        for cluster in clusters {
            guard let first = cluster.first,
                  let created = browser.layout.placeTabInNewWorkspace(first, in: profileID) else { continue }
            for (offset, id) in cluster.dropFirst().enumerated() {
                browser.layout.placeTab(id, in: profileID, workspace: created, at: offset + 1)
            }
            let members = everyone.filter { cluster.contains($0.id) }
            let label = TabTopics.label(for: members, among: everyone)
            strip = browser.layout.strip(for: profileID).workspaces
            let name = label.isEmpty ? String(localized: "Group") : label
            if let index = strip.firstIndex(where: { $0.id == created }) {
                browser.layout.rename(workspaceAt: index, to: name)
            }
            for id in cluster { seen[id]?.row = created }
            made.insert(created)
            Log.info(.browser, "made a group of \(cluster.count): \(label)")
            if browser.isAIEnabled { rename(created, from: name, titles: members.map(\.title), in: browser) }
        }
        return true
    }

    /// A better name from the on-device model, when there is one and the person uses language models.
    private func rename(_ group: UUID, from label: String, titles: [String], in browser: BrowserState) {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else {
            return Log.debug(.browser, "group name: on-device model \(SystemLanguageModel.default.availability)")
        }
        Task { [weak browser] in
            let session = LanguageModelSession(instructions: """
                Name a browser tab group. Answer with one to three words in the language of the \
                titles, no punctuation, no quotes.
                """)
            let prompt = titles.prefix(6).map { "- \($0)" }.joined(separator: "\n")
            let answer: String
            do {
                answer = try await session.respond(to: prompt).content
            } catch {
                return Log.error(.browser, "group name: \(error.localizedDescription)")
            }
            guard let browser else { return }
            let name = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            // Only while the group is still in front and still has the name six gave it.
            guard !name.isEmpty, name.count <= 40,
                  let index = browser.layout.workspaces.firstIndex(where: { $0.id == group }),
                  browser.layout.workspaces[index].name == label
            else { return }
            browser.layout.rename(workspaceAt: index, to: name)
            Log.info(.browser, "renamed group \(label) to \(name)")
        }
        #endif
    }
}
