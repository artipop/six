import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One file six has to have on disk before it can embed anything, and how to know it arrived whole.
nonisolated struct EmbeddingFile: Sendable, Equatable {
    /// Where it lands, relative to the folder it belongs to. Slashes are kept: transformers.js
    /// looks for the weights under `onnx/` and will not be talked out of it.
    var name: String
    var url: URL
    /// What the publisher says it weighs, for the progress the settings page draws. Zero when the
    /// publisher does not say.
    var size: Int
    /// Lower-case hex SHA-256, or empty when there is none to check against.
    var sha256: String
}

/// What to download for the embedder that is not MLX, and where from.
///
/// Two halves, with two different notions of trust. The **runtime** — transformers.js and the ONNX
/// Runtime wasm it drives — is pinned here by version *and* by digest: an npm version on a CDN is
/// immutable, so the honest thing is to write the digest down in the source and refuse anything
/// else. The **model** is fetched from the Hugging Face API at run time the way
/// `BergamotCatalog` fetches Mozilla's, because that is where its digests live: a file kept in Git
/// LFS carries its SHA-256 as its object id, and the API hands both over with the sizes.
///
/// The small JSON beside the weights (`config.json`, `tokenizer_config.json`) is not in LFS and so
/// has no SHA-256 to compare against. It is left unchecked rather than checked against the Git blob
/// id, which is a SHA-1 over a different byte string and would only look like an answer. Half a
/// kilobyte of JSON that does not parse fails loudly at load; half a model that does not decode
/// does not, which is the asymmetry the hashes are there for.
nonisolated enum EmbeddingCatalog {
    // MARK: The runtime

    /// The transformers.js release everything below is pinned to.
    ///
    /// 3.8.1 rather than the 4.x line, and the reason is one file: 4.x moved tokenisation into
    /// `@huggingface/tokenizers`, a second wasm to fetch and keep in step, and buys six nothing —
    /// the tokenizer for this model is XLM-RoBERTa's, which the JavaScript one has handled since 2.x.
    static let runtimeVersion = "3.8.1"

    /// transformers.js, the ONNX Runtime glue it imports, and the wasm that glue loads. Twenty-two
    /// megabytes, which is the same order as Bergamot's engine and for the same reason: what six is
    /// installing is a program, not a library it could have linked.
    ///
    /// The digests are jsDelivr's own, converted from the base64 its API publishes. They are
    /// written down rather than fetched because a pinned npm version cannot legitimately change,
    /// so a mismatch is news either way.
    static var runtime: [EmbeddingFile] {
        let base = URL(string: "https://cdn.jsdelivr.net/npm/@huggingface/transformers@\(runtimeVersion)/dist/")!
        return [
            EmbeddingFile(
                name: "transformers.min.js",
                url: base.appending(path: "transformers.min.js"),
                size: 888_173,
                sha256: "aa5002b70e789798da263f5f99c62bd3e8fcd0c119258a493c40c180648365fa"
            ),
            EmbeddingFile(
                name: "ort-wasm-simd-threaded.jsep.mjs",
                url: base.appending(path: "ort-wasm-simd-threaded.jsep.mjs"),
                size: 44_484,
                sha256: "08fb86ec433c78bfb032c5d84a68b8e8e5a8d81268fa39e24314179a5767a5b9"
            ),
            EmbeddingFile(
                name: "ort-wasm-simd-threaded.jsep.wasm",
                url: base.appending(path: "ort-wasm-simd-threaded.jsep.wasm"),
                size: 21_596_019,
                sha256: "c46655e8a94afc45338d4cb2b840475f88e5012d524509916e505079c00bfa39"
            )
        ]
    }

    // MARK: The model

    /// The Hugging Face repository the ONNX weights come from — not the one `MLXEmbedder` reads.
    ///
    /// Same model, same tokenizer, same vectors: `intfloat` publishes the PyTorch weights that MLX
    /// wants, and `Xenova` publishes the ONNX conversion of exactly those, which is what a
    /// JavaScript runtime can load. The stamp on a vector stays `EmbeddingModelChoice.modelID`,
    /// because the *model* is what a vector is comparable within, and the model is the same one.
    static func repository(for choice: EmbeddingModelChoice) -> String {
        switch choice {
        case .small: "Xenova/multilingual-e5-small"
        case .base: "Xenova/multilingual-e5-base"
        }
    }

    /// The weights file, out of the eight quantisations the repository carries.
    ///
    /// `model_quantized.onnx` — int8 — and that is a decision about where this runs rather than
    /// about quality. The Mac casts the same weights to fp16 and hands them to Metal; there is no
    /// GPU under this one, the arithmetic is wasm on a CPU, and int8 is both the format that build
    /// is fastest at and a quarter of the download. What it costs is the third decimal of a cosine
    /// distance, well under what the ranking sorts on — the same argument `MLXEmbedder` makes for
    /// fp16, one step further along.
    static let weightsFile = ProcessInfo.processInfo.environment["SIX_EMBED_WEIGHTS"] ?? "onnx/model_quantized.onnx"

    /// Everything transformers.js opens when it is pointed at a local model folder. The order is
    /// the order they are fetched in, smallest first, so a failure costs the least.
    static let modelFiles = ["config.json", "tokenizer_config.json", "tokenizer.json", weightsFile]

    /// What transformers.js has to be told the weights are, which is decided by which file was
    /// downloaded — `q8` reads `model_quantized.onnx`, `fp32` reads `model.onnx`.
    static var dtype: String {
        weightsFile.contains("quantized") || weightsFile.contains("int8") ? "q8"
            : weightsFile.contains("fp16") ? "fp16" : "fp32"
    }

    /// Asks Hugging Face what those files weigh and what they hash to.
    ///
    /// The `lfs.oid` of a file kept in Git LFS *is* its SHA-256, which is the whole reason this is
    /// a network call rather than four more constants: the digests then come from the same place
    /// the bytes do, and a model repository that is re-uploaded is caught rather than pinned to a
    /// hash six would have to chase.
    static func model(_ choice: EmbeddingModelChoice, session: URLSession) async throws -> [EmbeddingFile] {
        let repository = repository(for: choice)
        let listing = URL(string: "https://huggingface.co/api/models/\(repository)/tree/main?recursive=1")!
        // `BergamotCatalog.data(from:session:)` rather than `URLSession.data(from:)`, and it is not
        // a borrowed convenience: that async form is missing from `FoundationNetworking` on Linux,
        // and that function is where six keeps the continuation which stands in for it.
        let data = try await BergamotCatalog.data(from: listing, session: session)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let base = URL(string: "https://huggingface.co/\(repository)/resolve/main/")!
        return try modelFiles.map { path in
            guard let entry = byPath[path] else {
                throw EmbedderError.unavailable("\(repository) has no \(path)")
            }
            return EmbeddingFile(
                name: path,
                url: base.appending(path: path),
                size: entry.lfs?.size ?? entry.size,
                sha256: entry.lfs?.oid ?? ""
            )
        }
    }

    /// As much of the API's answer as this needs. `lfs` is absent for a small file kept in Git
    /// itself, which is exactly the case with no SHA-256 in it.
    private struct Entry: Decodable {
        struct LFS: Decodable {
            var oid: String
            var size: Int
        }
        var path: String
        var size: Int
        var lfs: LFS?
    }
}
