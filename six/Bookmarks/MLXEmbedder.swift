import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

/// Cross-lingual sentence embeddings on the GPU, through MLX: `intfloat/multilingual-e5-small` —
/// 118 M parameters, 384 dimensions, ~100 languages in one space, so «плов» finds *pilaf*. The
/// weights (~230 MB) come from the Hugging Face Hub on first use into `modelsDirectory` and are
/// read from there afterwards; `status` narrates the download for the UI.
///
/// E5 wants a role prefix on every text (`query: ` / `passage: `) and is trained with mean pooling
/// and L2 normalisation.
actor MLXEmbedder: Embedder {
    static let configuration = ModelConfiguration(id: "intfloat/multilingual-e5-small")
    /// Tokens per text before truncation (the model's window is 512).
    static let maxTokens = 510
    static let batchSize = 16
    /// E5 is a mean-pooled model. Said explicitly: the snapshot's `1_Pooling/config.json` doesn't
    /// reach the factory, and without it the container falls back to the CLS pooler — which for this
    /// model puts every sentence within a few percent of every other.
    static let pooling = Pooling(strategy: .mean)

    nonisolated let modelID = "multilingual-e5-small"
    nonisolated let dimension = 384

    private let hub: HubClient
    private var container: EmbedderModelContainer?
    private var loading: Task<EmbedderModelContainer, Error>?
    /// What is happening with the model — "downloading 42 %", "ready", an error — for whoever asked.
    private var statusHandler: (@Sendable (String) -> Void)?

    /// - Parameter modelsDirectory: where downloaded weights live (`~/Library/Application Support/six/Models`).
    init(modelsDirectory: URL) {
        hub = HubClient(cache: HubCache(cacheDirectory: modelsDirectory))
    }

    func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) {
        statusHandler = handler
    }

    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [Embedding] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadedContainer()
        let prefix = role == .query ? "query: " : "passage: "
        var result: [Embedding] = []
        result.reserveCapacity(texts.count)
        for batch in stride(from: 0, to: texts.count, by: Self.batchSize).map({ Array(texts[$0..<min($0 + Self.batchSize, texts.count)]) }) {
            let prefixed = batch.map { prefix + $0 }
            let vectors = try await container.perform { context -> [[Float]] in
                let tokenizer = context.tokenizer
                let padID = tokenizer.convertTokenToId("<pad>") ?? tokenizer.convertTokenToId("[PAD]") ?? 0
                let encoded = prefixed.map { text -> [Int] in
                    let ids = tokenizer.encode(text: text, addSpecialTokens: true)
                    guard ids.count > Self.maxTokens + 2 else { return ids }
                    // Keep the closing special token when we cut the middle out.
                    return Array(ids.prefix(Self.maxTokens + 1)) + [ids[ids.count - 1]]
                }
                let length = encoded.map(\.count).max() ?? 1
                let padded = encoded.map { $0 + Array(repeating: padID, count: length - $0.count) }
                let mask = encoded.map { Array(repeating: Int32(1), count: $0.count) + Array(repeating: Int32(0), count: length - $0.count) }
                let inputs = MLXArray(padded.flatMap { $0.map { Int32($0) } }, [padded.count, length])
                let attention = MLXArray(mask.flatMap { $0 }, [padded.count, length])
                let output = context.model(inputs, positionIds: nil, tokenTypeIds: nil, attentionMask: attention)
                let pooled = Self.pooling(output, mask: attention, normalize: true)
                pooled.eval()
                return (0..<padded.count).map { pooled[$0].asArray(Float.self) }
            }
            for vector in vectors {
                guard vector.count == dimension else { throw EmbedderError.dimensionMismatch(expected: dimension, got: vector.count) }
                result.append(Embedding(vector: vector, model: modelID))
            }
        }
        return result
    }

    /// `SIX_EMBED_SELFTEST=1`: what the tokenizer and the pooler make of a few sentences, on stderr.
    func diagnostics() async -> String {
        var lines: [String] = []
        do {
            let container = try await loadedContainer()
            let report = try await container.perform { context -> String in
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
        let task = Task { [hub, statusHandler] () throws -> EmbedderModelContainer in
            statusHandler?("loading model")
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: HubDownloader(hub),
                using: TransformersTokenizerLoader(),
                configuration: Self.configuration
            ) { progress in
                let percent = Int(progress.fractionCompleted * 100)
                statusHandler?(percent < 100 ? "downloading model \(percent) %" : "loading model")
            }
            statusHandler?("ready")
            return container
        }
        loading = task
        defer { loading = nil }
        do {
            let container = try await task.value
            self.container = container
            return container
        } catch {
            statusHandler?("model unavailable: \(error.localizedDescription)")
            throw EmbedderError.unavailable("Embedding model unavailable: \(error.localizedDescription)")
        }
    }
}

// MARK: - mlx-swift-lm adapters

/// `HubClient` as mlx-swift-lm's `Downloader`: a snapshot of the repo into the cache directory.
private struct HubDownloader: Downloader {
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
private struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// The few calls the embedder makes, mapped one to one; chat templates are not a thing here.
private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
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
