import Foundation

/// Which group a tab belongs to, from vectors alone, so every front can share it.
/// Decided by the lead over the alternatives, not an absolute threshold: e5 cosines are too
/// compressed for one (docs/layout.md).
nonisolated enum TabTopics {
    struct Weights: Sendable, Equatable {
        /// Added to a group's score when one of its tabs is on the same site.
        var domain: Float = 0.015
        /// Added when the tab was opened from one of the group's tabs.
        var opener: Float = 0.03

        static let standard = Weights()
    }

    struct Thresholds: Sendable, Equatable {
        /// How far the best group has to be ahead of the rest for the tab to join it.
        var joins: Float = 0.035
        /// Two groups closer than this, both well ahead of the rest, have the tab between them.
        var tie: Float = 0.02
        var betweenLead: Float = 0.04
        /// Ungrouped tabs this far above their usual similarity to everything make a group.
        var cluster: Float = 0.04
        var clusterSize = 3

        static let standard = Thresholds()
    }

    struct Tab: Sendable, Equatable {
        var id: UUID
        var vector: [Float]
        var host: String
        var title: String = ""
        var opener: UUID? = nil
    }

    struct Group: Sendable, Equatable {
        var id: UUID
        /// The group's name, embedded the way tabs are; nil for a group nobody named.
        var name: [Float]?
        /// The group's tabs, oldest first; the most recent dozen are what a tab is measured against.
        var members: [Tab]

        var anchors: ArraySlice<Tab> { members.suffix(12) }
    }

    enum Verdict: Sendable, Equatable {
        case group(UUID)
        /// `weight` is how far along from `from` towards `to`: 0.5 is exactly halfway.
        case between(from: UUID, to: UUID, weight: Double)
        case none
    }

    // MARK: Scoring

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let norm = (na * nb).squareRoot()
        return norm > 0 ? dot / norm : 0
    }

    /// Nil for a group with nothing to compare against; the tab is never its own anchor.
    static func score(_ tab: Tab, in group: Group, weights: Weights = .standard) -> Float? {
        let anchors = group.anchors.filter { $0.id != tab.id }
        let nearest = (anchors.map { cosine(tab.vector, $0.vector) } + [group.name.map { cosine(tab.vector, $0) }].compactMap { $0 }).max()
        guard var score = nearest else { return nil }
        if !tab.host.isEmpty, anchors.contains(where: { $0.host == tab.host }) { score += weights.domain }
        if let opener = tab.opener, group.members.contains(where: { $0.id == opener }) { score += weights.opener }
        return score
    }

    /// The median cosine to `others`: what a lone group has to beat.
    static func background(of tab: Tab, among others: [Tab]) -> Float {
        let cosines = others.filter { $0.id != tab.id }.map { cosine(tab.vector, $0.vector) }.sorted()
        return cosines.isEmpty ? 0 : cosines[cosines.count / 2]
    }

    /// `loose` is the closest ungrouped tab: nearer than the group, the tab may start a group of its own.
    static func classify(_ tab: Tab, among groups: [Group], background: Float, loose: Float = -.infinity,
                         weights: Weights = .standard, thresholds: Thresholds = .standard) -> Verdict {
        let scored = groups.compactMap { group in score(tab, in: group, weights: weights).map { (group.id, $0) } }
            .sorted { $0.1 > $1.1 }
        guard let first = scored.first else { return .none }
        let floor = max(background, loose)
        let second = max(scored.count > 1 ? scored[1].1 : floor, loose)
        let third = max(scored.count > 2 ? scored[2].1 : floor, floor)
        if scored.count > 1, first.1 - second < thresholds.tie, second - third >= thresholds.betweenLead {
            let weight = 0.5 - 0.25 * Double((first.1 - second) / thresholds.tie)
            return .between(from: first.0, to: scored[1].0, weight: weight)
        }
        return first.1 - max(second, floor) >= thresholds.joins ? .group(first.0) : .none
    }

    // MARK: New groups

    /// Average linkage. `context` is every tab: measured against the loose ones only, a topic that
    /// is half of them sets its own bar.
    static func clusters(_ tabs: [Tab], context: [Tab]? = nil, weights: Weights = .standard,
                         thresholds: Thresholds = .standard) -> [[UUID]] {
        let n = tabs.count
        guard n >= thresholds.clusterSize else { return [] }
        let usual = tabs.map { background(of: $0, among: context ?? tabs) }
        var affinity = Array(repeating: Array(repeating: Float(0), count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var a = cosine(tabs[i].vector, tabs[j].vector) - max(usual[i], usual[j])
                if !tabs[i].host.isEmpty, tabs[i].host == tabs[j].host { a += weights.domain }
                if tabs[i].opener == tabs[j].id || tabs[j].opener == tabs[i].id { a += weights.opener }
                affinity[i][j] = a
                affinity[j][i] = a
            }
        }
        var groups: [[Int]] = (0..<n).map { [$0] }
        while groups.count > 1 {
            var best: (Int, Int, Float)?
            for a in groups.indices {
                for b in (a + 1)..<groups.count {
                    var sum: Float = 0
                    for i in groups[a] { for j in groups[b] { sum += affinity[i][j] } }
                    let mean = sum / Float(groups[a].count * groups[b].count)
                    if mean > (best?.2 ?? -.infinity) { best = (a, b, mean) }
                }
            }
            guard let (a, b, mean) = best, mean >= thresholds.cluster else { break }
            groups[a] += groups[b]
            groups.remove(at: b)
        }
        return groups.filter { $0.count >= thresholds.clusterSize }
            .sorted { $0.count > $1.count }
            .map { $0.sorted().map { tabs[$0].id } }
    }

    // MARK: Names

    /// c-TF-IDF over the titles, else the shared host: the name until a model gives a better one.
    static func label(for cluster: [Tab], among all: [Tab]) -> String {
        let inside = Set(cluster.map(\.id))
        let rest = all.filter { !inside.contains($0.id) }
        var counts: [String: Int] = [:]
        var spread: [String: Int] = [:]
        for tab in cluster {
            let words = self.words(cleanTitle(tab.title, host: tab.host))
            for word in words { counts[word, default: 0] += 1 }
            for word in Set(words) { spread[word, default: 0] += 1 }
        }
        var elsewhere: [String: Int] = [:]
        for tab in rest { for word in Set(words(cleanTitle(tab.title, host: tab.host))) { elsewhere[word, default: 0] += 1 } }
        let total = Double(max(1, counts.values.reduce(0, +)))
        let scored = counts.compactMap { word, count -> (String, Double)? in
            guard spread[word, default: 0] >= 2 else { return nil }
            let idf = log(1 + Double(all.count) / Double(spread[word, default: 0] + elsewhere[word, default: 0]))
            return (word, Double(count) / total * idf)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var picked: [String] = []
        for (word, _) in scored where picked.count < 2 {
            guard !picked.contains(where: { sameStem($0, word) }) else { continue }
            picked.append(word)
        }
        if !picked.isEmpty { return picked.map(\.localizedCapitalized).joined(separator: " ") }
        let hosts = Set(cluster.map(\.host))
        if hosts.count == 1, let host = hosts.first, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return ""
    }

    /// Drops the site's name off the end when what is left is still a title (Firefox's rule).
    static func cleanTitle(_ title: String, host: String = "") -> String {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = host.lowercased().replacingOccurrences(of: "-", with: "")
        for separator in [" | ", " - ", " — ", " – ", " · ", " :: "] {
            guard let range = title.range(of: separator, options: .backwards) else { continue }
            let head = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = title[range.upperBound...].lowercased().filter { $0.isLetter || $0.isNumber }
            let spelled = !tail.isEmpty && !site.isEmpty && site.contains(tail)
            if !head.isEmpty, head.count >= 20 || spelled { title = head }
        }
        return title
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func sameStem(_ a: String, _ b: String) -> Bool {
        let n = min(a.count, b.count, 5)
        return n >= 4 && a.prefix(n) == b.prefix(n)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "your", "you", "are", "how", "what", "why",
        "when", "who", "all", "new", "not", "can", "will", "about", "into", "more", "most", "best", "its",
        "our", "out", "use", "using", "via", "vs", "home", "page", "official", "site", "online", "free",
        "это", "как", "что", "для", "или", "при", "без", "под", "над", "все", "всё", "его", "она", "они",
        "так", "уже", "где", "кто", "чем", "вам", "вас", "нас", "наш", "ваш", "был", "была", "было", "быть",
        "есть", "ещё", "еще", "также", "только", "очень", "может", "можно", "нужно", "через", "после",
        "перед", "главная", "страница", "официальный", "сайт", "онлайн", "бесплатно",
    ]
}
