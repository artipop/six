import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon

/// A small language model on this Mac for tab groups: naming them, and choosing one for a tab.
/// Loaded only while asked, since memory is tight.
actor LocalLanguageModel {
    private static let idleUnload: Duration = .seconds(60)

    private let hub: HubClient
    private var container: ModelContainer?
    private var repository = ""
    private var loading: Task<ModelContainer, Error>?
    private var unload: Task<Void, Never>?

    init(modelsDirectory: URL) {
        hub = HubClient(cache: HubCache(cacheDirectory: modelsDirectory))
    }

    /// In the interface's language; downloads the model on first use.
    func name(for titles: [String], with model: LocalModelChoice) async throws -> String {
        unload?.cancel()
        let container = try await loaded(model.repository)
        let session = ChatSession(container, history: Self.namingHistory,
                                  generateParameters: GenerateParameters(maxTokens: 12, temperature: 0))
        let answer = try await session.respond(to: Self.prompt(titles))
        scheduleUnload()
        let name = Self.clean(answer, titles: titles)
        Log.debug(.browser, "group name: \(model.name) answered \"\(answer)\" → \"\(name)\"")
        return name
    }

    /// The groups a tab belongs to, by index into `groups`: none, one, or two when it is about both.
    func choose(for tab: String, among groups: [(name: String, titles: [String])],
                with model: LocalModelChoice) async throws -> [Int] {
        guard !groups.isEmpty else { return [] }
        unload?.cancel()
        let container = try await loaded(model.repository)
        let session = ChatSession(container, history: Self.choosingHistory,
                                  generateParameters: GenerateParameters(maxTokens: 8, temperature: 0))
        let answer = try await session.respond(to: Self.choosingPrompt(tab, groups))
        scheduleUnload()
        let picked = Self.numbers(in: answer, upTo: groups.count)
        Log.debug(.browser, "group choice: \(model.name) answered \"\(answer)\" → \(picked)")
        return picked
    }

    private func loaded(_ repository: String) async throws -> ModelContainer {
        if let container, self.repository == repository { return container }
        if let loading, self.repository == repository { return try await loading.value }
        container = nil
        self.repository = repository
        let task = Task { [hub] in
            try await LLMModelFactory.shared.loadContainer(
                from: HubDownloader(hub), using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(id: repository))
        }
        loading = task
        defer { loading = nil }
        let container = try await task.value
        self.container = container
        return container
    }

    private func scheduleUnload() {
        unload = Task {
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled else { return }
            container = nil
            Memory.clearCache()
        }
    }

    // MARK: The question

    private static var languageCode: String {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "en"
    }

    private static var language: String {
        Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? "English"
    }

    static var instructions: String {
        """
        You name groups of browser tabs by their topic. Reply with the topic only: one or two words \
        in \(language), a general subject such as a reader would file the pages under, no quotes, no \
        punctuation, no explanation. Name what the pages are about, never the website they are on.
        """
    }

    /// Earlier chat turns, not text in the question: asked for a language it ignored it, shown one
    /// inside the question it copied the answer.
    private static var examples: [(titles: [String], topic: String)] {
        let topics = languageCode == "ru" ? ["Личные финансы", "Путешествия", "Фотография"] : ["Personal finance", "Travel", "Photography"]
        return [
            (["How to pick an index fund", "Ипотека или аренда: что выгоднее"], topics[0]),
            (["Cheap flights to Rome", "Лучшие отели Лиссабона", "What to see in Porto in two days"], topics[1]),
            (["Sony A7 IV review", "Как снимать портреты при естественном свете"], topics[2]),
        ]
    }

    private static var namingHistory: [Chat.Message] {
        [.system(instructions)] + examples.flatMap { [.user(prompt($0.titles)), .assistant($0.topic)] }
    }

    static func prompt(_ titles: [String]) -> String {
        "Tabs:\n" + titles.prefix(8).map { "- \($0.prefix(160))" }.joined(separator: "\n")
    }

    /// Empty when the answer is not in the interface's script, so the group keeps its name.
    static func clean(_ answer: String, titles: [String] = []) -> String {
        var line = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let colon = line.firstIndex(of: ":"), line[..<colon].count < 12 { line = String(line[line.index(after: colon)...]) }
        line = line.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters).union(CharacterSet(charactersIn: "\"«»“”'`*")))
        guard !line.isEmpty, line.count <= 40, inScript(line, titles: titles) else { return "" }
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// A word taken from the titles is a proper name and may be in any script.
    private static func inScript(_ text: String, titles: [String]) -> Bool {
        let named = Set(titles.flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
        let foreign = text.split(separator: " ").filter { !named.contains($0.lowercased()) }.joined(separator: " ")
        if foreign.isEmpty { return true }
        let letters = foreign.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        let latin = letters.filter { $0.isASCII }.count
        for word in text.split(separator: " ") {
            let scalars = word.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let mixed = scalars.contains { $0.isASCII } && scalars.contains { (0x0400...0x04FF).contains($0.value) }
            if mixed { return false }
        }
        switch languageCode {
        case "ru": return cyrillic * 2 >= letters.count
        default: return latin == letters.count
        }
    }

    // MARK: Choosing

    private static let choosingInstructions = """
        You sort a browser tab into one of the numbered groups by what it is about. Reply with the \
        group's number only. If it fits none of them, reply 0. If it is equally about two groups, \
        reply both numbers separated by a space.
        """

    static func choosingPrompt(_ tab: String, _ groups: [(name: String, titles: [String])]) -> String {
        let listed = groups.enumerated().map { index, group in
            let titles = group.titles.suffix(3).map { String($0.prefix(80)) }.joined(separator: "; ")
            return "\(index + 1). \(group.name): \(titles)"
        }
        return "Groups:\n" + listed.joined(separator: "\n") + "\nTab: \(tab.prefix(200))"
    }

    private static var choosingHistory: [Chat.Message] {
        let groups: [(name: String, titles: [String])] = [
            ("Travel", ["Cheap flights to Rome", "Лучшие отели Лиссабона"]),
            ("Photography", ["Sony A7 IV review", "Как снимать портреты при естественном свете"]),
            ("Finance", ["How to pick an index fund", "Ипотека или аренда"]),
        ]
        let examples = [
            ("Что посмотреть в Порту за два дня", "1"),
            ("Weather forecast for Berlin", "0"),
            ("Best camera for travel photos", "1 2"),
            ("Налоговый вычет за брокерский счёт", "3"),
        ]
        return [.system(choosingInstructions)] + examples.flatMap { tab, answer in
            [Chat.Message.user(choosingPrompt(tab, groups)), .assistant(answer)]
        }
    }

    /// The group numbers in the answer's first line, 1-based in, 0-based out; 0 means none.
    static func numbers(in answer: String, upTo count: Int) -> [Int] {
        let line = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var picked: [Int] = []
        for token in line.split(whereSeparator: { !$0.isNumber }) {
            guard let number = Int(token), number >= 1, number <= count, !picked.contains(number - 1) else { continue }
            picked.append(number - 1)
            if picked.count == 2 { break }
        }
        return picked
    }
}
