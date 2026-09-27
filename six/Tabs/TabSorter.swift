import Foundation
import WebKit
import FoundationModels

/// Moves tabs into groups by meaning; `TabTopics` decides. Only new tabs and tabs that changed site
/// move, and what the person placed by hand stays.
@MainActor
final class TabSorter {
    private struct Seen {
        var host: String
        /// Where the sorter last saw it; anywhere else means the person moved it.
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
    private var arrivals: Set<UUID> = []
    private var pending: Set<UUID> = []
    /// An ungroup of one of these is taken as an answer.
    private var made: Set<UUID> = []
    private var pass: Task<Void, Never>?
    private let model = LocalLanguageModel(modelsDirectory: AppDatabase.url.deletingLastPathComponent()
        .appending(path: "Models", directoryHint: .isDirectory))

    /// E5's prefix for symmetric comparison; it also measured better on titles.
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

    /// Tabs already in a group are only noted: someone put them there.
    func sortEverything(in browser: BrowserState) {
        for row in browser.layout.strip(for: browser.selectedProfileID).workspaces {
            let ids = row.columns.flatMap(\.tabIDs)
            if row.name.isEmpty { arrivals.formUnion(ids) }
            pending.formUnion(ids)
        }
        schedule(browser)
    }

    func pageFinished(_ tab: BrowserTab, in browser: BrowserState) {
        guard let page = tab.livePage else { return }
        let id = tab.id
        Task {
            // Wikipedia and many articles have no description; the first paragraph stands in.
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

    /// Cut short: e5 finds long texts alike for being long.
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
        LocalLanguageModel.trimMemory()
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
            var verdict = TabTopics.classify(features, among: groups, background: background, loose: loose,
                                             weights: weights, thresholds: thresholds)
            if browser.tabSorting == .languageModel, !groups.isEmpty {
                verdict = await chosen(for: features, among: strip.filter { !$0.name.isEmpty }, in: browser) ?? verdict
            }
            Log.debug(.browser, String(format: "sort %@: usual %.3f, loose %.3f, ", host, background, loose)
                + groups.map { group in
                    String(format: "%@ %.3f", strip.first { $0.id == group.id }?.name ?? "", TabTopics.score(features, in: group) ?? 0)
                }
                    .joined(separator: ", ") + " → \(verdict)")
            // The strip can have changed while the model answered.
            let latest = browser.layout.strip(for: profileID).workspaces
            guard let here = latest.first(where: { $0.columns.contains { $0.holds(id) } }), here.id == row.id else { continue }
            switch verdict {
            case .group(let target) where target != here.id:
                let end = latest.first { $0.id == target }?.columns.count ?? 0
                browser.layout.placeTab(id, in: profileID, workspace: target, at: end)
                seen[id]?.row = target
                moved = true
                Log.info(.browser, "sorted \(host) into \(latest.first { $0.id == target }?.name ?? "?")")
            case .between(let from, let to, let weight):
                let lean = TilingLean(from: from, to: to, weight: weight)
                if here.columns.first(where: { $0.holds(id) })?.lean == lean { continue }
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

    /// Nil when the model could not answer, and the embeddings' verdict stands.
    private func chosen(for tab: TabTopics.Tab, among rows: [TilingWorkspace], in browser: BrowserState) async -> TabTopics.Verdict? {
        let groups = rows.map { row in
            (name: row.name, titles: row.columns.flatMap(\.tabIDs).filter { $0 != tab.id }
                .compactMap { vectors[$0]?.text })
        }
        do {
            let picked = try await model.choose(for: tab.title, among: groups, with: browser.localModel)
            switch picked.count {
            case 0: return TabTopics.Verdict.none
            case 1: return .group(rows[picked[0]].id)
            default: return .between(from: rows[picked[0]].id, to: rows[picked[1]].id, weight: 0.5)
            }
        } catch {
            Log.error(.browser, "group choice: \(error.localizedDescription)")
            return nil
        }
    }

    private func features(of tab: BrowserTab) -> TabTopics.Tab? {
        guard let vector = vectors[tab.id] else { return nil }
        // The embedded text, so a name can come from the description when titles share no word.
        return TabTopics.Tab(id: tab.id, vector: vector.values, host: host(of: tab), title: vector.text,
                             opener: tab.openedFrom)
    }

    private func group(_ row: TilingWorkspace, in browser: BrowserState) -> TabTopics.Group {
        let members = row.columns.flatMap(\.tabIDs).compactMap(browser.tab).compactMap(features(of:))
        return TabTopics.Group(id: row.id, name: nameVectors[row.name], members: members)
    }

    // MARK: New groups

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
            rename(created, from: name, titles: members.map(\.title), in: browser)
        }
        return true
    }

    /// The assistant's model when AI is on, else the small one. Not an ACP agent: its one session is
    /// the person's chat. A name typed in the meantime wins.
    private func rename(_ group: UUID, from label: String, titles: [String], in browser: BrowserState) {
        let session = browser.isAIEnabled ? try? browser.assistantSettings.namingSession(instructions: LocalLanguageModel.instructions) : nil
        let choice = browser.localModel
        Task { [weak browser, model] in
            var name = ""
            if let session {
                do {
                    name = LocalLanguageModel.clean(try await session.respond(to: LocalLanguageModel.prompt(titles)).content, titles: titles)
                } catch {
                    Log.info(.browser, "group name: assistant model: \(error.localizedDescription)")
                }
            }
            if name.isEmpty {
                do {
                    name = try await model.name(for: titles, with: choice)
                } catch {
                    return Log.error(.browser, "group name: \(error.localizedDescription)")
                }
            }
            guard let browser, !name.isEmpty,
                  let index = browser.layout.workspaces.firstIndex(where: { $0.id == group }),
                  browser.layout.workspaces[index].name == label
            else { return }
            browser.layout.rename(workspaceAt: index, to: name)
            Log.info(.browser, "renamed group \(label) to \(name)")
        }
    }
}
