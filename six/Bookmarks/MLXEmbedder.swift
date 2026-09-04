import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXNN
import Tokenizers

/// Cross-lingual sentence embeddings on the GPU, through MLX: E5 multilingual, `small` or `base` as
/// `EmbeddingModelChoice` says — ~100 languages in one space, so «плов» finds *pilaf*. The weights
/// (an fp32 safetensors plus a 16 MB tokenizer: ~465 MB for `small`, ~1.1 GB for `base`) come from
/// the Hugging Face Hub on first use into `modelsDirectory` and are read from there afterwards;
/// `status` narrates the download for the UI. They are cast to fp16 once loaded — see
/// `loadedContainer`.
///
/// E5 wants a role prefix on every text (`query: ` / `passage: `) and is trained with mean pooling
/// and L2 normalisation. Both sizes are the same architecture over the same tokenizer, which is why
/// one embedder covers them and only the numbers differ.
actor MLXEmbedder: Embedder {
    /// Tokens per text before truncation (the model's window is 512).
    static let maxTokens = 510
    static let batchSize = 32
    /// E5 is a mean-pooled model. Said explicitly: the snapshot's `1_Pooling/config.json` doesn't
    /// reach the factory, and without it the container falls back to the CLS pooler — which for this
    /// model puts every sentence within a few percent of every other.
    static let pooling = Pooling(strategy: .mean)

    nonisolated let choice: EmbeddingModelChoice
    nonisolated let modelID: String
    nonisolated let dimension: Int
    nonisolated let configuration: ModelConfiguration

    private let hub: HubClient
    private var container: EmbedderModelContainer?
    private var loading: Task<EmbedderModelContainer, Error>?
    /// What is happening with the model — "downloading 42 %", an error — for whoever asked. Empty means ready.
    private var statusHandler: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - choice: which E5 to run; every model has its own vectors, its own table and its own download.
    ///   - modelsDirectory: where downloaded weights live (`~/Library/Application Support/org.deffun.six/Models`).
    ///     One cache for all of them: the hub lays repositories out side by side, so switching back to a
    ///     model that was used before finds its weights still there.
    init(choice: EmbeddingModelChoice, modelsDirectory: URL) {
        self.choice = choice
        modelID = choice.modelID
        dimension = choice.dimension
        configuration = ModelConfiguration(id: choice.repository)
        hub = HubClient(cache: HubCache(cacheDirectory: modelsDirectory))
    }

    func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) {
        statusHandler = handler
    }

    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [Embedding] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadedContainer()
        let prefix = role == .query ? "query: " : "passage: "
        let prefixed = texts.map { prefix + $0 }
        let vectors = await container.perform { context -> [[Float]] in
            let tokenizer = context.tokenizer
            let padID = tokenizer.convertTokenToId("<pad>") ?? tokenizer.convertTokenToId("[PAD]") ?? 0
            let tokenizingStarted = ContinuousClock.now
            let encoded = prefixed.map { text -> [Int] in
                let ids = tokenizer.encode(text: text, addSpecialTokens: true)
                guard ids.count > Self.maxTokens + 2 else { return ids }
                // Keep the closing special token when we cut the tail off.
                return Array(ids.prefix(Self.maxTokens + 1)) + [ids[ids.count - 1]]
            }
            let tokenizing = ContinuousClock.now - tokenizingStarted
            let modelStarted = ContinuousClock.now
            defer { FileHandle.standardError.write(Data("[six] embed: tokenized \(encoded.count) in \(tokenizing), model \(ContinuousClock.now - modelStarted)\n".utf8)) }
            // Batches of similar length pad the least: a batch is as long as its longest member.
            let order = encoded.indices.sorted { encoded[$0].count < encoded[$1].count }
            var vectors = [[Float]](repeating: [], count: encoded.count)
            for start in stride(from: 0, to: order.count, by: Self.batchSize) {
                let batch = Array(order[start..<min(start + Self.batchSize, order.count)])
                let length = batch.map { encoded[$0].count }.max() ?? 1
                let padded = batch.map { encoded[$0] + Array(repeating: padID, count: length - encoded[$0].count) }
                let mask = batch.map { Array(repeating: Int32(1), count: encoded[$0].count) + Array(repeating: Int32(0), count: length - encoded[$0].count) }
                let inputs = MLXArray(padded.flatMap { $0.map { Int32($0) } }, [batch.count, length])
                let attention = MLXArray(mask.flatMap { $0 }, [batch.count, length])
                let output = context.model(inputs, positionIds: nil, tokenTypeIds: nil, attentionMask: attention)
                let pooled = Self.pooling(output, mask: attention, normalize: true)
                pooled.eval()
                for (row, index) in batch.enumerated() { vectors[index] = pooled[row].asArray(Float.self) }
            }
            return vectors
        }
        return try vectors.map { vector in
            guard vector.count == dimension else { throw EmbedderError.dimensionMismatch(expected: dimension, got: vector.count) }
            return Embedding(vector: vector, model: modelID)
        }
    }

    /// Loads the model without embedding anything, so that whoever asks first is not the one waiting
    /// the three seconds it takes. Failures are the next caller's problem; this one has nobody to tell.
    ///
    /// Only when the weights are already on the machine. A warm-up is worth a disk read; it is not
    /// worth a 465 MB download nobody asked for, and the hub client answers that question without
    /// touching the network (`localFilesOnly`, which resolves out of the cache or throws).
    func warmUp() async {
        guard container == nil, loading == nil, let repo = Repo.ID(rawValue: configuration.name) else { return }
        let cached = try? await hub.downloadSnapshot(of: repo, revision: "main", matching: ["*.safetensors"], localFilesOnly: true)
        guard cached != nil else { return }
        _ = try? await loadedContainer()
    }

    /// `SIX_EMBED_SELFTEST=1`: what the tokenizer and the pooler make of a few sentences, on stderr.
    func diagnostics() async -> String {
        var lines: [String] = []
        do {
            let container = try await loadedContainer()
            let report = await container.perform { context -> String in
                let tokenizer = context.tokenizer
                var out = "pooling: \(Self.pooling.strategy) (container says \(context.pooling.strategy))\n"
                out += "max positions: \(String(describing: context.model.maxPositionEmbeddings)) vocab: \(context.model.vocabularySize)\n"
                for text in ["query: плов", "query: pilaf rice"] {
                    let ids = tokenizer.encode(text: text, addSpecialTokens: true)
                    out += "\(text) → \(ids) → \(ids.map { tokenizer.convertIdToToken($0) ?? "?" })\n"
                }
                out += "pad: \(String(describing: tokenizer.convertTokenToId("<pad>"))) unk: \(String(describing: tokenizer.unknownToken)) eos: \(String(describing: tokenizer.eosToken))\n"
                return out
            }
            lines.append(report)
            let samples = ["плов — рисовое блюдо с мясом и морковью", "pilaf is a rice dish cooked with meat and carrots", "example domains reserved for documentation", "зарезервированные доменные имена для документации"]
            let vectors = try await embed(samples, as: .passage)
            for i in samples.indices {
                for j in samples.indices where j > i {
                    let dot = zip(vectors[i].vector, vectors[j].vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    lines.append(String(format: "cos(%d,%d) = %.3f", i, j, dot))
                }
            }
            lines.append("norm(0) = \(vectors[0].vector.reduce(0) { $0 + $1 * $1 }.squareRoot()) head: \(vectors[0].vector.prefix(5))")
        } catch {
            lines.append("failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    /// Loads once; concurrent callers wait on the same task. A failed load is retried next time.
    private func loadedContainer() async throws -> EmbedderModelContainer {
        if let container { return container }
        if let loading { return try await loading.value }
        let task = Task { [hub, statusHandler, configuration] () throws -> EmbedderModelContainer in
            statusHandler?(String(localized: "loading model"))
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: HubDownloader(hub),
                using: TransformersTokenizerLoader(),
                configuration: configuration
            ) { progress in
                let percent = Int(progress.fractionCompleted * 100)
                statusHandler?(percent < 100 ? String(localized: "downloading model \(percent) %") : String(localized: "loading model"))
            }
            // The weights arrive as fp32 — that is what the Hub snapshot holds — and are run as fp16.
            // Measured on this M2, Debug, 64 passages of ~900 characters: 1.0–1.5 s and 470 MB of GPU
            // memory at fp32, 0.76–0.85 s and 235 MB at fp16. On an 8 GB machine the memory is the
            // half that matters, since MLX shares it with every WebKit process. The vectors move in
            // the third decimal, well under what cosine distance sorts on, so an index written before
            // this line stays valid — `BertModel` casts the attention mask to the embeddings' dtype
            // for exactly this case, and says so in a comment.
            await container.perform { context in
                _ = context.model.apply { $0.dtype.isFloatingPoint ? $0.asType(.float16) : $0 }
                eval(context.model)
            }
            statusHandler?("") // ready: nothing left to say about the model
            return container
        }
        loading = task
        defer { loading = nil }
        do {
            let container = try await task.value
            self.container = container
            return container
        } catch {
            statusHandler?(String(localized: "model unavailable: \(error.localizedDescription)"))
            throw EmbedderError.unavailable("Embedding model unavailable: \(error.localizedDescription)")
        }
    }
}

// MARK: - mlx-swift-lm adapters

// The adapters are `nonisolated` on purpose: the target defaults every type to the main actor, and a
// main-actor tokenizer would parse tokenizer.json and encode every chunk on the UI thread.

/// `HubClient` as mlx-swift-lm's `Downloader`: a snapshot of the repo into the cache directory.
nonisolated private struct HubDownloader: Downloader {
    let hub: HubClient

    init(_ hub: HubClient) { self.hub = hub }

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else { throw EmbedderError.unavailable("Bad model id \(id)") }
        return try await hub.downloadSnapshot(
            of: repo, revision: revision ?? "main", matching: patterns, localFilesOnly: false,
            progressHandler: { @MainActor progress in progressHandler(progress) }
        )
    }
}

/// swift-transformers' `AutoTokenizer` as mlx-swift-lm's `TokenizerLoader`.
nonisolated private struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// The few calls the embedder makes, mapped one to one; chat templates are not a thing here.
nonisolated private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw EmbedderError.unavailable("Chat templates are not supported by the embedding tokenizer")
    }
}
