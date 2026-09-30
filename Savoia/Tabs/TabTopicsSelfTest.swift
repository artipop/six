import Foundation

/// `SAVOIA_TOPICS_SELFTEST=1`: the real models on fixed titles; `=grid` also compares e5 sizes and prefixes;
/// `=batch` is a second batch of one topic arriving together, before and after `near`; `=live` does
/// the same with real pages in a new profile, through the sorter itself. `SAVOIA_CLEANUP_SELFTEST=1` (or `=small`, `=base`) measures `TabCleanup`.
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

    static func run(_ browser: BrowserState, grid: Bool, compare: Bool = false) async {
        func say(_ line: String) { Log.info(.browser, "topics selftest: \(line)") }
        guard let embedder = browser.bookmarks?.embedder else { return say("no embedder") }
        if compare {
            await self.compare(embedder, say)
            return say("done")
        }
        if ProcessInfo.processInfo.environment["SAVOIA_TOPICS_SELFTEST"] == "live" {
            await live(browser, say)
            return say("done")
        }
        if ProcessInfo.processInfo.environment["SAVOIA_TOPICS_SELFTEST"] == "batch" {
            await batch(say)
            return say("done")
        }
        if ProcessInfo.processInfo.environment["SAVOIA_TOPICS_SELFTEST"] == "agent" {
            await askAgent(browser, say)
            return say("done")
        }
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
        await name(say)
        say("done")
    }

    private static func name(_ say: (String) -> Void) async {
        let groups = [
            ["Chocolate lava cake recipe", "Как испечь брауни", "Panna cotta with berries"],
            ["Tesla Model 3 review", "Зарядные станции для электромобилей", "BYD Seal: first drive"],
            ["Borscht. Borscht is a sour soup common in Eastern Europe",
             "Sourdough. Sourdough is a type of bread made by fermenting dough",
             "Pilaf. Pilaf is a rice dish cooked in a seasoned broth"],
            ["Swift Concurrency: updating an app to use strict concurrency",
             "Actors in Swift: how to use them and prevent data races",
             "Structured concurrency with async let and task groups"],
            ["Премьер-лига: результаты тура и таблица", "Champions League draw: full fixtures",
             "Трансферные новости Реал Мадрида"],
        ]
        let models = AppDatabase.url.deletingLastPathComponent().appending(path: "Models", directoryHint: .isDirectory)
        let namer = LocalLanguageModel(modelsDirectory: models)
        let chosen = ProcessInfo.processInfo.environment["SAVOIA_LOCAL_MODEL"].flatMap(LocalModelChoice.init(rawValue:)) ?? .standard
        for titles in groups {
            let started = Date()
            do {
                let name = try await namer.name(for: titles, with: chosen)
                say("\(chosen.name) name \"\(name)\" in \(Int(Date().timeIntervalSince(started) * 1000)) ms for \(titles.first ?? "")")
            } catch {
                say("name failed: \(error.localizedDescription)")
            }
        }
    }

    private static func askAgent(_ browser: BrowserState, _ say: (String) -> Void) async {
        guard let ask = browser.askAgent else { return say("agent: not wired") }
        for titles in [["Chocolate lava cake recipe", "Как испечь брауни", "Panna cotta with berries"],
                       ["Tesla Model 3 review", "Зарядные станции для электромобилей", "BYD Seal: first drive"]] {
            let started = Date()
            do {
                let question = LocalLanguageModel.instructions + " Do not use tools.\n\n" + LocalLanguageModel.prompt(titles)
                let answer = try await ask(question)
                say("agent answered \"\(answer ?? "nil")\" → \"\(answer.map { LocalLanguageModel.clean($0, titles: titles) } ?? "")\" in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            } catch {
                say("agent failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Embeddings against each local model, on every tab

    private static let named = [("swift", "Swift"), ("food", "Еда"), ("football", "Футбол")]
    private static let moreHeldOut = [
        ("swift", "Как устроены макросы в Swift 5.9"), ("swift", "Xcode 26 release notes"),
        ("food", "Лучший рецепт шарлотки"), ("food", "How long to boil an egg"),
        ("football", "Зенит — Спартак: обзор матча"), ("football", "World Cup 2026 qualifiers schedule"),
    ]
    private static let moreStrays = ["Курс доллара на сегодня", "iPhone 18 rumors", "Как оформить загранпаспорт"]

    private static func compare(_ embedder: any Embedder, _ say: (String) -> Void) async {
        let anchors = topics.flatMap { topic in topic.1.map { (topic.0, $0) } }
        let cases = topics.flatMap { topic in topic.2.map { (topic.0, $0) } } + moreHeldOut
            + between.map { ("between", $0) } + (strays + moreStrays).map { ("none", $0) }
        let texts = anchors.map(\.1) + cases.map(\.1)
        guard let vectors = try? await embedder.embed(texts, as: TabSorter.role),
              let names = try? await embedder.embed(named.map(\.1), as: TabSorter.role) else { return say("embed failed") }
        let tabs = zip(texts, vectors).map { TabTopics.Tab(id: UUID(), vector: $1.vector, host: "", title: $0) }
        let groups = named.enumerated().map { index, pair in
            TabTopics.Group(id: UUID(), name: names[index].vector,
                            members: tabs.prefix(anchors.count).filter { tab in anchors.contains { $0.0 == pair.0 && $0.1 == tab.title } })
        }
        let topicOf = Dictionary(uniqueKeysWithValues: zip(groups.map(\.id), named.map(\.0)))
        let tested = Array(tabs.suffix(cases.count))

        func score(_ label: String, _ verdicts: [TabTopics.Verdict], ms: Int) {
            var right = 0, nearly = 0, strayKept = 0, bridged = 0, halfBridged = 0
            var wrong: [String] = []
            for (verdict, (expected, title)) in zip(verdicts, cases) {
                switch (expected, verdict) {
                case ("none", .none): strayKept += 1
                case ("between", .between(let a, let b, _)) where Set([topicOf[a], topicOf[b]]) == ["food", "football"]: bridged += 1
                case ("between", .group(let id)) where ["food", "football"].contains(topicOf[id] ?? ""): halfBridged += 1
                case (let topic, .group(let id)) where topicOf[id] == topic: right += 1
                case (let topic, .near(let id, _)) where topicOf[id] == topic: nearly += 1
                default: wrong.append("\(title.prefix(30))→\(describe(verdict, topicOf))")
                }
            }
            let held = cases.filter { !["none", "between"].contains($0.0) }.count
            say("\(label): held-out \(right)/\(held) (+\(nearly) next to it), strays kept \(strayKept)/\(strays.count + moreStrays.count), "
                + "between \(bridged)/\(between.count) (+\(halfBridged) in one), \(ms) ms/tab; wrong: \(wrong.joined(separator: " | "))")
        }

        let background = tested.map { TabTopics.background(of: $0, among: tabs) }
        score("e5", zip(tested, background).map { TabTopics.classify($0, among: groups, background: $1) }, ms: 0)

        let models = AppDatabase.url.deletingLastPathComponent().appending(path: "Models", directoryHint: .isDirectory)
        let model = LocalLanguageModel(modelsDirectory: models)
        let listed = named.map { pair in (name: pair.1, titles: anchors.filter { $0.0 == pair.0 }.map(\.1)) }
        for choice in LocalModelChoice.allCases {
            _ = try? await model.name(for: ["warm up"], with: choice)
            var verdicts: [TabTopics.Verdict] = []
            let started = Date()
            for tab in tested {
                let picked = (try? await model.choose(for: tab.title, among: listed, with: choice)) ?? []
                switch picked.count {
                case 0: verdicts.append(.none)
                case 1: verdicts.append(.group(groups[picked[0]].id))
                default: verdicts.append(.between(from: groups[picked[0]].id, to: groups[picked[1]].id, weight: 0.5))
                }
            }
            score(choice.name, verdicts, ms: Int(Date().timeIntervalSince(started) * 1000) / tested.count)
        }
    }

    // MARK: Real pages in a clean profile

    private static func wiki(_ titles: [String]) -> [URL] {
        titles.compactMap { URL(string: "https://en.wikipedia.org/wiki/\($0)") }
    }

    private static func live(_ browser: BrowserState, _ say: (String) -> Void) async {
        let wasOn = browser.sortsTabsByMeaning
        let method = browser.tabSorting
        let name = "Topics \(Date().formatted(.dateTime.hour().minute().second()))"
        browser.addProfile(name: name, colorHex: "#888888")
        guard let profile = browser.profiles.last, profile.name == name else { return say("no profile") }
        browser.tabSorting = .embeddings
        browser.setSortsTabsByMeaning(true)
        let first = wiki(["Borscht", "Sourdough", "Carbonara", "Chocolate_chip_cookie",
                          "Swift_(programming_language)", "Actor_model", "Async/await", "SwiftUI",
                          "Premier_League", "UEFA_Champions_League", "Real_Madrid_CF", "Arsenal_F.C."])
        let second = wiki(["Pilaf", "Chicken_curry", "Solyanka", "Ramen", "Sports_nutrition",
                           "Weather_forecasting", "Rail_transport"])
        for (label, urls) in [("first", first), ("second", second)] {
            for url in urls { browser.newTab(url: url, in: profile.id, workspace: nil, activate: false) }
            await settle(browser, profile.id)
            say("\(label): " + rows(browser, profile.id))
        }
        browser.setSortsTabsByMeaning(wasOn)
        browser.tabSorting = method
        say("profile \(name) left in place")
    }

    /// Until every page has loaded and the sorter has had a quiet stretch to finish its pass and names.
    private static func settle(_ browser: BrowserState, _ profile: UUID) async {
        let started = Date()
        while Date().timeIntervalSince(started) < 90 {
            try? await Task.sleep(for: .seconds(2))
            if Date().timeIntervalSince(started) > 10, !browser.tabs(in: profile).contains(where: \.isLoading) { break }
        }
        try? await Task.sleep(for: .seconds(20))
    }

    private static func rows(_ browser: BrowserState, _ profile: UUID) -> String {
        let strip = browser.layout.strip(for: profile).workspaces
        return strip.enumerated().filter { !$0.element.isEmpty }.map { index, row in
            var head = row.name.isEmpty ? "·" : "«\(row.name)»"
            if let blend = row.blend {
                let parents = blend.parents.map { id in strip.first { $0.id == id }?.name ?? "?" }
                head += String(format: " [between %@ %.2f]", parents.joined(separator: "+"), blend.weight)
            }
            if browser.layout.activeProfileID == profile, let color = browser.layout.groupColor(of: row.id) {
                let c = color.srgb
                head += String(format: " #%02X%02X%02X", Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255))
            }
            let titles = row.columns.flatMap(\.tabIDs).compactMap { browser.tab($0)?.title.prefix(22) }
            return head + ": " + titles.joined(separator: ", ")
        }.joined(separator: " || ")
    }

    // MARK: A second batch arriving together

    private static let secondBatch = [
        "Как приготовить плов в казане", "Easy weeknight chicken curry",
        "Рецепт солянки сборной мясной", "Homemade ramen from scratch",
    ]

    /// What `TabSorter.sort` does with tabs that arrive together: one at a time, each measured against
    /// the ones still loose, then the rest clustered.
    /// Old tabs on every topic, a period spent reading about swift and football: food and the strays are
    /// what should be offered.
    static func cleanup(_ embedder: any Embedder) async {
        func say(_ line: String) { Log.info(.browser, "cleanup selftest: \(line)") }
        let old = topics.flatMap { topic in topic.1.map { (topic.0 == "food" ? "offer" : "keep", $0) } }
            + strays.map { ("offer", $0) }
        let read = topics.filter { $0.0 != "food" }.flatMap(\.2)
            + ["Swift Testing: parameterized tests", "Реал Мадрид — Барселона: онлайн трансляция"]
        let texts = old.map(\.1) + read
        guard let vectors = try? await embedder.embed(texts, as: TabSorter.role) else { return say("embed failed") }
        let now = Date.now
        let tabs = zip(old, vectors).map { TabCleanup.Tab(id: UUID(), vector: $1.vector, host: "", seenAt: now.addingTimeInterval(-20 * 86_400)) }
        let history = vectors.suffix(read.count).map { TabCleanup.Interest(vector: $0.vector, host: "") }
        let open = tabs.map { TabTopics.Tab(id: $0.id, vector: $0.vector, host: "") }
        for (tab, (expected, title)) in zip(tabs, old) {
            let nearest = history.map { TabTopics.cosine(tab.vector, $0.vector) }.max() ?? 0
            let usual = TabTopics.background(of: open.first { $0.id == tab.id }!, among: open)
            let peers = open.filter { $0.id != tab.id }.map { TabTopics.cosine(tab.vector, $0.vector) }.sorted(by: >).prefix(3)
            let kin = peers.reduce(0, +) / Float(max(1, peers.count))
            say("[\(expected)] \(title.prefix(32)): lead \(String(format: "%.3f", nearest - usual)), over peers \(String(format: "%.3f", nearest - kin))")
        }
        for kin in [Float(-0.03), -0.02, -0.01, 0, 0.01] {
            var thresholds = TabCleanup.Thresholds.standard
            thresholds.kin = kin
            let offered = Set(TabCleanup.abandoned(tabs, history: history, since: now.addingTimeInterval(-7 * 86_400),
                                                   thresholds: thresholds))
            let right = zip(tabs, old).filter { offered.contains($0.0.id) == ($0.1.0 == "offer") }.count
            let wrongClosed = zip(tabs, old).filter { offered.contains($0.0.id) && $0.1.0 == "keep" }.count
            say("kin \(kin): \(right)/\(tabs.count) right, \(wrongClosed) read topics offered")
        }
        say("done")
    }

    private static func batch(_ say: (String) -> Void) async {
        let anchors = topics.flatMap { topic in topic.1.map { (topic.0, $0) } }
        let arriving = secondBatch.map { ("food", $0) } + between.map { ("between", $0) } + strays.map { ("none", $0) }
        let names = [("swift", "Swift"), ("food", "Ужин"), ("football", "Футбол")]
        let models = AppDatabase.url.deletingLastPathComponent().appending(path: "Models", directoryHint: .isDirectory)
        for choice in EmbeddingModelChoice.allCases {
            let embedder = MLXEmbedder(choice: choice, modelsDirectory: models)
            let texts = (anchors + arriving).map(\.1)
            guard let vectors = try? await embedder.embed(texts, as: TabSorter.role),
                  let named = try? await embedder.embed(names.map(\.1), as: TabSorter.role) else { return say("embed failed") }
            let tabs = zip(texts, vectors).map { TabTopics.Tab(id: UUID(), vector: $1.vector, host: "", title: $0) }
            let groups = names.enumerated().map { index, pair in
                TabTopics.Group(id: UUID(), name: named[index].vector,
                                members: Array(tabs.prefix(anchors.count)).enumerated()
                                    .filter { anchors[$0.offset].0 == pair.0 }.map(\.element))
            }
            let topicOf = Dictionary(uniqueKeysWithValues: zip(groups.map(\.id), names.map(\.0)))
            let incoming = Array(tabs.suffix(arriving.count))
            for (label, near) in [("before", Float.infinity), ("now", TabTopics.Thresholds.standard.near)] {
                var thresholds = TabTopics.Thresholds.standard
                thresholds.near = near
                var loose = incoming
                var lines: [String] = []
                for (tab, (expected, title)) in zip(incoming, arriving) {
                    let background = TabTopics.background(of: tab, among: tabs)
                    let nearest = loose.filter { $0.id != tab.id }.map { TabTopics.cosine(tab.vector, $0.vector) }.max() ?? -.infinity
                    let verdict = TabTopics.classify(tab, among: groups, background: background, loose: nearest, thresholds: thresholds)
                    if verdict != .none { loose.removeAll { $0.id == tab.id } }
                    let scores = groups.map { String(format: "%@ %.3f", topicOf[$0.id] ?? "", TabTopics.score(tab, in: $0) ?? 0) }
                    lines.append("[\(expected)] \(title.prefix(28)) → \(describe(verdict, topicOf))"
                                 + String(format: " (usual %.3f, loose %.3f, ", background, nearest) + scores.joined(separator: " ") + ")")
                }
                let clusters = TabTopics.clusters(loose, context: tabs, thresholds: thresholds).map { cluster in
                    let members = tabs.filter { cluster.contains($0.id) }
                    return "«\(TabTopics.label(for: members, among: tabs))» ×\(members.count)"
                }
                say("\(choice.rawValue) \(label): " + lines.joined(separator: " | ")
                    + " || new groups: " + (clusters.isEmpty ? "none" : clusters.joined(separator: ", ")))
            }
        }

        guard ProcessInfo.processInfo.environment["SAVOIA_TOPICS_SELFTEST_LLM"] != "0" else { return }
        let local = LocalLanguageModel(modelsDirectory: models)
        let listed = names.map { pair in (name: pair.1, titles: anchors.filter { $0.0 == pair.0 }.map(\.1)) }
        for choice in LocalModelChoice.allCases {
            _ = try? await local.name(for: ["warm up"], with: choice)
            var lines: [String] = []
            let started = Date()
            for (expected, title) in arriving {
                let picked = (try? await local.choose(for: title, among: listed, with: choice)) ?? []
                lines.append("[\(expected)] \(title.prefix(28)) → \(picked.isEmpty ? "none" : picked.map { names[$0].0 }.joined(separator: "+"))")
            }
            say("\(choice.name) (\(Int(Date().timeIntervalSince(started) * 1000) / arriving.count) ms/tab): " + lines.joined(separator: " | "))
        }
    }

    private static func describe(_ verdict: TabTopics.Verdict, _ topicOf: [UUID: String]) -> String {
        switch verdict {
        case .none: "none"
        case .group(let id): topicOf[id] ?? "?"
        case .between(let a, let b, _): "\(topicOf[a] ?? "?")+\(topicOf[b] ?? "?")"
        case .near(let id, let weight): String(format: "≈%@ %.2f", topicOf[id] ?? "?", weight)
        }
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
            case .near(let id, let weight): verdict = String(format: "next to %@ %.2f", groupName[id] ?? "", weight)
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
