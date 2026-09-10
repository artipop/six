import Foundation

/// One vector and the model that made it. Vectors from different models live in different spaces;
/// the model id travels with the vector so they are never compared.
nonisolated struct Embedding: Sendable {
    var vector: [Float]
    var model: String
}

/// What a text is for. Asymmetric models (E5) embed a question and a passage differently.
nonisolated enum EmbeddingRole: Sendable {
    case query
    case passage
}

/// The embedding seam (docs/storage.md): text in, vectors out. `MLXEmbedder` is the one the Mac
/// uses; `WebEmbedder` is the same model on the fronts that have no Metal, run through the page
/// engine they already ship; `ContextualEmbedder` is Apple's zero-download fallback; a remote one
/// (Voyage, OpenAI) would be another conformer with the same shape.
///
/// This half of the file is in `SixCore` and the conformers are not, which is the whole reason it
/// was split off: three of the four fronts need the protocol, and each of them can only build one
/// of the things behind it.
nonisolated protocol Embedder: Sendable {
    /// Family of models behind this embedder, stored on the bookmark; a change means re-indexing.
    var modelID: String { get }
    var dimension: Int { get }
    func embed(_ texts: [String], as role: EmbeddingRole) async throws -> [Embedding]
    /// Loads whatever the first `embed` would have to load, before anybody is waiting on an answer.
    func warmUp() async
}

nonisolated extension Embedder {
    /// An embedder with nothing to load is already warm; only the two that load weights —
    /// `MLXEmbedder` and `WebEmbedder` — have anything to do here.
    func warmUp() async {}
}

nonisolated enum EmbedderError: LocalizedError {
    case unavailable(String)
    case dimensionMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .dimensionMismatch(let expected, let got): "Embedding has \(got) dimensions, the index expects \(expected)"
        }
    }
}
