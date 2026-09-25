import Foundation

/// `SIX_TOPICS_SELFTEST=1` — the real embedder on a fixed set of titles, and what `TabTopics` makes
/// of them: how far apart e5 puts pages on one topic and on different ones, where held-out and
/// in-between titles land, and the groups and names clustering finds. Titles only, so nothing is
/// opened and the strip is not touched. `SIX_TOPICS_SELFTEST=grid` also tries e5-base and the other
/// prefix, which is how `query:` on e5-small was chosen.
enum TabTopicsSelfTest {
    private static let topics: [(String, [String], [String])] = [
        ("swift", [
            "Swift Concurrency: updating an app to use strict concurrency",
            "Actors in Swift: how to use them and prevent data races",
            "SwiftUI NavigationStack tutorial",
            "Structured concurrency with async let and task groups",
        ], ["Understanding Sendable in Swift 6", "Как устроены акторы в Swift"]),
        ("food", [
            "Рецепт борща с говядиной — пошагово",
            "How to make sourdough bread at home",
            "Паста карбонара: классический рецепт",
            "Best chocolate chip cookies recipe",
        ], ["Как приготовить плов в казане", "Easy weeknight chicken curry"]),
        ("football", [
            "Премьер-лига: результаты тура и таблица",
            "Champions League draw: full fixtures",
            "Трансферные новости Реал Мадрида",
            "Arsenal 2–1 Chelsea: match report",
        ], ["Лига чемпионов: обзор матчей вторника", "Messi scores twice as Inter Miami win"]),
    ]
    private static let between = [
        "Sports nutrition: what to eat before a football match",
        "Питание футболиста: рацион на день",
    ]
    private static let strays = ["Weather forecast for Berlin", "Купить билеты на поезд"]

    static func run(_ browser: BrowserState, grid: Bool) async {
        func say(_ line: String) { Log.info(.browser, "topics selftest: \(line)") }
        guard let embedder = browser.bookmarks?.embedder else { return say("no embedder") }
        if grid {
            let models = AppDatabase.url.deletingLastPathComponent().appending(path: "Models", directoryHint: .isDirectory)
            for choice in EmbeddingModelChoice.allCases {
                let other = MLXEmbedder(choice: choice, modelsDirectory: models)
                for role in [EmbeddingRole.passage, .query] {
                    await measure(other, role: role, verbose: false, say)
                }
            }
        }
        await measure(embedder, role: TabSorter.role, verbose: true, say)
        say("done")
    }

    private static func measure(_ embedder: any Embedder, role: EmbeddingRole, verbose: Bool,
                                _ say: (String) -> Void) async {
        let anchors = topics.flatMap { topic in topic.1.map { (topic.0, $0) } }
        let heldOut = topics.flatMap { topic in topic.2.map { (topic.0, $0) } }
        let all = anchors + heldOut + between.map { ("between", $0) } + strays.map { ("stray", $0) }
        let started = Date()
        guard let embedded = try? await embedder.embed(all.map(\.1), as: role) else { return say("embed failed") }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let vectors = embedded.map(\.vector)
        let tabs = zip(all, vectors).enumerated().map { index, pair in
            TabTopics.Tab(id: UUID(), vector: pair.1, host: "site\(index).example", title: pair.0.1)
        }
        let topicOf = Dictionary(uniqueKeysWithValues: zip(tabs.map(\.id), all.map(\.0)))

        // How often a pair on one topic is closer than a pair on two: 1 is perfect, 0.5 is chance.
        var same: [Float] = [], different: [Float] = []
        for i in 0..<anchors.count {
            for j in (i + 1)..<anchors.count {
                let c = TabTopics.cosine(tabs[i].vector, tabs[j].vector)
                if anchors[i].0 == anchors[j].0 { same.append(c) } else { different.append(c) }
            }
        }
        let wins = same.reduce(0) { sum, s in sum + different.filter { $0 < s }.count }
        let auc = Double(wins) / Double(same.count * different.count)

        let groups = topics.map { topic in
            TabTopics.Group(id: UUID(), name: nil, members: tabs.filter { topic.1.contains($0.title) })
        }
        let groupName = Dictionary(uniqueKeysWithValues: zip(groups.map(\.id), topics.map(\.0)))
        let held = tabs.filter { heldOut.map(\.1).contains($0.title) }
        let right = held.filter { tab in
            let best = groups.max { (TabTopics.score(tab, in: $0) ?? 0) < (TabTopics.score(tab, in: $1) ?? 0) }
            return best.map { groupName[$0.id] } == topicOf[tab.id]
        }.count
        say(String(format: "%@ %@%@: separation %.2f, held-out nearest %d/%d, %d ms, same median %.3f, different median %.3f",
                   embedder.modelID, role == .query ? "query" : "passage", "",
                   auc, right, held.count, ms, same.sorted()[same.count / 2], different.sorted()[different.count / 2]))
        guard verbose else { return }

        for tab in tabs where !anchors.contains(where: { $0.1 == tab.title }) {
            let background = TabTopics.background(of: tab, among: tabs)
            let scores = groups.map { String(format: "%@ %.3f", groupName[$0.id] ?? "", TabTopics.score(tab, in: $0) ?? 0) }
                + [String(format: "usual %.3f", background)]
            let verdict: String
            switch TabTopics.classify(tab, among: groups, background: background) {
            case .group(let id): verdict = "→ \(groupName[id] ?? "")"
            case .between(let from, let to, let weight):
                verdict = String(format: "between %@ and %@ %.2f", groupName[from] ?? "", groupName[to] ?? "", weight)
            case .none: verdict = "stays"
            }
            say("[\(topicOf[tab.id] ?? "")] \(tab.title): \(verdict) (\(scores.joined(separator: ", ")))")
        }
        for cluster in TabTopics.clusters(tabs) {
            let members = tabs.filter { cluster.contains($0.id) }
            say("cluster \(TabTopics.label(for: members, among: tabs)): " + members.map { topicOf[$0.id] ?? "" }.joined(separator: " "))
        }
    }
}
