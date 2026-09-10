import Foundation

/// The Mac's embedder, on the fronts that have no Metal: E5 multilingual, run by transformers.js in
/// a page six owns and nobody sees.
///
/// The same model as `MLXEmbedder` — the same hundred languages in the same space, so «плов» finds
/// *pilaf* here too — reached by a different road, because the road matters less than the space.
/// `intfloat` publishes the PyTorch weights MLX loads and `Xenova` publishes the ONNX conversion of
/// those; a vector out of either is stamped `multilingual-e5-small`, and that is not a convenience.
/// It is the claim that the two are comparable, and it is worth stating what it rests on: the same
/// architecture, the same tokenizer, the same `query: `/`passage: ` prefixes, the same mean pooling
/// and L2 normalisation. What differs is arithmetic — fp16 on a GPU there, int8 on a CPU here — and
/// that moves a cosine distance in its third decimal, under what the ranking sorts on. An index
/// written by one and searched by the other ranks the same; it is not bit-identical and was never
/// going to be.
///
/// Everything platform-shaped is behind `PageSandbox`, everything disk-shaped behind
/// `EmbeddingStore`, and what is left here is the sequence — runtime on disk, weights on disk, page
/// open, model in the page, text in, vectors out — which is the same sequence on Linux and Windows.
/// `BergamotRuntime` is the same three paragraphs about a different program, and that is the point
/// of the seam.
@MainActor
final class WebEmbedder: Embedder {
    /// How many texts go into the page at once.
    ///
    /// Smaller than the Mac's 32, and for a reason that is not timidity: a batch is padded to its
    /// longest member and this runtime has one thread, so a long chunk in a big batch makes every
    /// other chunk in it wait on padding it did not need. Eight also keeps the wasm heap's peak
    /// somewhere a machine with 8 GB will not notice.
    static let batchSize = 8

    nonisolated let modelID: String
    nonisolated let dimension: Int

    private let choice: EmbeddingModelChoice
    private let store: EmbeddingStore
    private let sandbox: any PageSandbox
    private let root: URL

    private var isOpen = false
    /// Which model the page is holding, as `multilingual-e5-small@3.8.1`. Same string, no reload —
    /// and a reload is a hundred megabytes back through a wasm heap.
    private var loaded = ""
    private var preparing: Task<Void, Error>?
    /// What is happening with the model — downloading, loading, failed — for whoever asked.
    ///
    /// English, unlike `MLXEmbedder`'s: the two fronts that run this have no String Catalog yet,
    /// and the rail's own "New Tab" is already in the same boat. When they get one this is three
    /// `String(localized:)` calls, not a design.
    private var statusHandler: (@Sendable (String) -> Void)?

    init(choice: EmbeddingModelChoice, store: EmbeddingStore, sandbox: any PageSandbox) {
        self.choice = choice
        self.store = store
        self.sandbox = sandbox
        root = store.pageRoot
        modelID = choice.modelID
        dimension = choice.dimension
    }

    func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) {
        statusHandler = handler
    }

    // MARK: Embedder

    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [Embedding] {
        guard !texts.isEmpty else { return [] }
        try await prepare()
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        // Batches in order, unlike the Mac's length-sorted ones: sorting is worth its bookkeeping
        // when a batch is 32 wide and the GPU is idle waiting for the longest member, and it is not
        // when the batch is 8 and the work is serial anyway.
        for start in stride(from: 0, to: texts.count, by: Self.batchSize) {
            let batch = Array(texts[start..<min(start + Self.batchSize, texts.count)])
            let answer = try await ask("sixEmbed.embed", EmbedRequest(texts: batch, role: role == .query ? "query" : "passage"))
            if let complaint = answer.error { throw EmbedderError.unavailable(complaint) }
            guard let returned = answer.vectors, returned.count == batch.count else {
                throw EmbedderError.unavailable("the page returned \(answer.vectors?.count ?? 0) vectors for \(batch.count) texts")
            }
            vectors.append(contentsOf: returned)
        }
        return try vectors.map { vector in
            guard vector.count == dimension else {
                throw EmbedderError.dimensionMismatch(expected: dimension, got: vector.count)
            }
            return Embedding(vector: vector, model: modelID)
        }
    }

    /// `Embedder.warmUp` is a requirement of a `nonisolated` protocol, so the witness is nonisolated
    /// too however the type is annotated — which is why the body is one hop and not the guard it
    /// looks like it should be. `SixCore` has no `defaultIsolation(MainActor)` (that setting is on
    /// the fronts' own targets), so nothing here is on the main actor unless it says so.
    nonisolated func warmUp() async {
        await prepareIfInstalled()
    }

    /// Loads the model before anybody is waiting on it — but only when it is already on the disk.
    /// A warm-up is worth a page and a wasm heap; it is not worth a hundred-and-forty megabyte
    /// download nobody asked for, which is the same line `MLXEmbedder.warmUp` draws.
    private func prepareIfInstalled() async {
        guard loaded.isEmpty, preparing == nil, store.isInstalled(choice) else { return }
        try? await prepare()
    }

    // MARK: Getting there

    /// Everything that has to be true before a text can be embedded: the runtime on disk, the
    /// weights on disk, the page open, the model in the page. Idempotent and cheap on the second
    /// call, which matters because it is called once per batch and a page is many batches.
    private func prepare() async throws {
        if loaded == signature { return }
        if let preparing { return try await preparing.value }
        let task = Task { [self] in
            defer { self.preparing = nil }
            do {
                try await install()
                try await open()
                try await loadModel()
                statusHandler?("") // ready: nothing left to say about the model
            } catch {
                statusHandler?("model unavailable: \(error.localizedDescription)")
                throw error
            }
        }
        preparing = task
        try await task.value
    }

    private var signature: String { "\(choice.modelID)@\(EmbeddingCatalog.runtimeVersion)" }

    private func install() async throws {
        if !store.isInstalled(choice) { statusHandler?("downloading model") }
        let runtime = try await store.runtime()
        _ = try await store.model(choice)
        try writePayload(runtimeFolder: runtime.lastPathComponent)
    }

    private func open() async throws {
        guard !isOpen else { return }
        statusHandler?("loading model")
        try await sandbox.open(root.appending(path: "six-embed.html"))
        isOpen = true
    }

    private func loadModel() async throws {
        let answer = try await ask("sixEmbed.load", LoadRequest(model: choice.modelID))
        if let complaint = answer.error { throw EmbedderError.unavailable(complaint) }
        loaded = signature
        Log.info(.bookmarks, "embedder: loaded \(signature)")
    }

    /// The page and its driver, written beside the weights they read.
    private func writePayload(runtimeFolder: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in EmbedderDriver.files(runtimeFolder: runtimeFolder, dtype: EmbeddingCatalog.dtype) {
            try Data(file.contents.utf8).write(to: root.appending(path: file.name))
        }
    }

    /// `SIX_EMBED_SELFTEST=1`, and the same four sentences the Mac's `MLXEmbedder.diagnostics`
    /// uses — two about pilaf in two languages, two about reserved domain names — so the numbers
    /// off this front can be read straight against the numbers off that one. What is being checked
    /// is not the arithmetic but the space: the pair that means the same thing has to sit closer
    /// than the pair that does not, whichever language each half is in.
    func diagnostics() async -> String {
        var lines: [String] = []
        do {
            try await prepare()
            let answer = try await ask("sixEmbed.report", LoadRequest(model: choice.modelID))
            // The complaint first, when there is one: a report that answers every field with "?" is
            // how a broken probe looks, and it looks exactly like a healthy page with nothing to say.
            if let complaint = answer.error { lines.append("page: \(complaint)") }
            lines.append("page: \(answer.version ?? "?") wasm \(answer.backend ?? "?") model \(answer.model ?? "?")")
            for file in answer.files ?? [] { lines.append("  \(file)") }
            let samples = [
                "плов — рисовое блюдо с мясом и морковью",
                "pilaf is a rice dish cooked with meat and carrots",
                "example domains reserved for documentation",
                "зарезервированные доменные имена для документации"
            ]
            let vectors = try await embed(samples, as: .passage)
            for i in samples.indices {
                for j in samples.indices where j > i {
                    let dot = zip(vectors[i].vector, vectors[j].vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    lines.append(String(format: "cos(%d,%d) = %.3f", i, j, dot))
                }
            }
            let norm = vectors[0].vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            lines.append("norm(0) = \(norm) head: \(vectors[0].vector.prefix(5))")
        } catch {
            lines.append("failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Talking to the page

    private func ask(_ function: String, _ request: some Encodable) async throws -> Answer {
        let input = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let body = "return JSON.stringify(await \(function)(JSON.parse(input)));"
        let text = try await sandbox.call(body, input: input)
        guard let data = text.data(using: .utf8) else {
            throw EmbedderError.unavailable("the page said nothing")
        }
        return try JSONDecoder().decode(Answer.self, from: data)
    }

    // MARK: The wire

    private struct LoadRequest: Encodable {
        var model: String
    }

    private struct EmbedRequest: Encodable {
        var texts: [String]
        var role: String
    }

    /// Every driver function answers in this shape; which fields are filled in says which function
    /// answered. One type rather than four, because the alternative is four decoders for three
    /// fields.
    private struct Answer: Decodable {
        var error: String?
        var vectors: [[Float]]?
        var version: String?
        var backend: String?
        var model: String?
        var files: [String]?
    }
}
