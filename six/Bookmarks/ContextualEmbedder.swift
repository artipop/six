import Foundation
import NaturalLanguage

/// On-device sentence embeddings from `NLContextualEmbedding` (NaturalLanguage): a BERT-style
/// multilingual model per script — Latin, Cyrillic, CJK — 512 dimensions, no network, no key.
/// Token vectors are mean-pooled into one per text. Each text is embedded with the model of its
/// dominant language, so a Russian query searches Russian passages and an English one English
/// passages; the spaces are not aligned across scripts. That is the price of local; a cross-lingual
/// remote embedder is the upgrade path, behind the same protocol.
///
/// Foundation Models has no embedding API in this SDK (macOS 27, 26A5406c); this is Apple's. Not the
/// default any more — `MLXEmbedder` is — but kept as the zero-download fallback.
actor ContextualEmbedder: Embedder {
    nonisolated let modelID = "NLContextualEmbedding"
    nonisolated let dimension = 512

    private var models: [String: NLContextualEmbedding] = [:]

    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [Embedding] {
        var result: [Embedding] = []
        result.reserveCapacity(texts.count)
        for text in texts {
            let language = Self.language(of: text)
            let model = try await model(for: language)
            let embedding = try model.embeddingResult(for: text, language: language)
            var sum = [Double](repeating: 0, count: model.dimension)
            var count = 0
            embedding.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for (i, value) in vector.enumerated() where i < sum.count { sum[i] += value }
                count += 1
                return true
            }
            guard count > 0 else { throw EmbedderError.unavailable("No tokens in text") }
            var pooled = sum.map { Float($0 / Double(count)) }
            // Unit length, so cosine distance is what the index computes and nothing else.
            let norm = pooled.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { pooled = pooled.map { $0 / norm } }
            guard pooled.count == dimension else { throw EmbedderError.dimensionMismatch(expected: dimension, got: pooled.count) }
            result.append(Embedding(vector: pooled, model: "\(modelID)/\(model.modelIdentifier)"))
        }
        return result
    }

    /// The model id a query for `text` would use — what the index has to be filtered by.
    nonisolated func modelIdentifier(for text: String) -> String? {
        NLContextualEmbedding(language: Self.language(of: text)).map { "\(modelID)/\($0.modelIdentifier)" }
    }

    private func model(for language: NLLanguage) async throws -> NLContextualEmbedding {
        guard let model = NLContextualEmbedding(language: language) else {
            throw EmbedderError.unavailable("No contextual embedding model for \(language.rawValue)")
        }
        if let loaded = models[model.modelIdentifier] { return loaded }
        if !model.hasAvailableAssets {
            let outcome = try await model.requestAssets()
            guard outcome == .available else {
                throw EmbedderError.unavailable("Embedding assets for \(language.rawValue) are not available on this Mac (\(outcome.rawValue))")
            }
        }
        try model.load()
        models[model.modelIdentifier] = model
        return model
    }

    nonisolated static func language(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        return recognizer.dominantLanguage ?? .english
    }
}
