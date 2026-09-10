import Foundation

/// The engine, loaded, with a language pair in it.
///
/// Everything platform-shaped is behind `PageSandbox`; everything model-shaped is behind
/// `BergamotStore`. What is left here is the sequence — write the payload, open the page, put the
/// weights in it, hand it text — and it is the same sequence on Linux and on Windows.
@MainActor
final class BergamotRuntime {
    private let store: BergamotStore
    private let sandbox: any PageSandbox
    private let root: URL

    private var isOpen = false
    /// Which route the page is holding weights for, as `ru-en@2.1+en-de@1.1`. A pair that hashes
    /// the same needs no reload, and reloading is thirty megabytes through a wasm heap.
    private var loaded = ""

    init(store: BergamotStore, sandbox: any PageSandbox,
         root: URL = AppSupport.folder("Translation/Bergamot")) {
        self.store = store
        self.sandbox = sandbox
        self.root = root
    }

    var isLoaded: Bool { !loaded.isEmpty }

    /// Everything that has to be true before a word can be translated: the engine on disk, the
    /// weights on disk, the page open, and the weights in the page.
    ///
    /// Idempotent and cheap on the second call — which matters, because it is called once per batch
    /// and a page is a hundred batches.
    func prepare(from source: String, to target: String) async throws {
        let engine = try await store.engine()
        let models = try await store.models(from: source, to: target)
        // The folder a model was installed into carries its version, and that is what has to be in
        // the key: a model Mozilla has moved on from is a different model, not the same pair again.
        let route = models
            .map { $0.files["model"]?.deletingLastPathComponent().lastPathComponent ?? "\($0.from)-\($0.to)" }
            .joined(separator: "+")
            + "/" + engine.deletingLastPathComponent().lastPathComponent
        if loaded == route { return }

        try writePayload()
        if !isOpen {
            try await sandbox.open(root.appending(path: "bergamot.html"))
            isOpen = true
        }

        let request = LoadRequest(
            wasm: relative(engine),
            models: models.map { model in
                LoadRequest.Model(
                    from: model.from,
                    to: model.to,
                    // The one thing the file's *name* decides. Weights built as `intgemm8.bin` are
                    // quantised differently from `intgemm.alphas.bin` ones, and a decoder told the
                    // wrong one does not fail — it translates fluent nonsense.
                    gemm: model.modelName.hasSuffix("intgemm8.bin") ? "int8shiftAll" : "int8shiftAlphaAll",
                    files: model.files.mapValues { relative($0) }
                )
            }
        )
        let answer = try await ask("sixBergamot.load", request)
        if let complaint = answer.error { throw BergamotError.engine(complaint) }
        loaded = route
        Log.info(.translation, "bergamot: loaded \(route)")
    }

    /// One batch. Same order out as in, and an entry that came back empty is left to the caller to
    /// drop — a page is better nine tenths translated than not at all.
    func translate(_ texts: [String]) async throws -> [String] {
        guard isLoaded else { throw BergamotError.notReady }
        let answer = try await ask("sixBergamot.translate", TranslateRequest(texts: texts))
        if let complaint = answer.error { throw BergamotError.engine(complaint) }
        return answer.texts ?? []
    }

    /// The page holds two models and forty megabytes of wasm heap. When a window stops translating
    /// there is no reason to keep either.
    func unload() async {
        guard isLoaded else { return }
        loaded = ""
        _ = try? await ask("sixBergamot.unload", TranslateRequest(texts: []))
    }

    // MARK: Talking to the page

    private func ask(_ function: String, _ request: some Encodable) async throws -> Answer {
        let input = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let body = "return JSON.stringify(await \(function)(JSON.parse(input)));"
        let text = try await sandbox.call(body, input: input)
        guard let data = text.data(using: .utf8) else { throw BergamotError.engine("the engine said nothing") }
        return try JSONDecoder().decode(Answer.self, from: data)
    }

    /// Paths are relative to the page, which sits at the root of the cache beside the folders it
    /// reads. Absolute `file:` URLs would work on one platform and not the other — a Windows path
    /// is not a URL path, and half of six's own bug reports about `file:` have been that difference.
    private func relative(_ url: URL) -> String {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        let cut = full.dropFirst(base.count).drop { $0 == "/" || $0 == "\\" }
        return cut.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { part in
                part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(part)
            }
            .joined(separator: "/")
    }

    // MARK: The payload

    /// Emscripten's glue, six's driver and the page that loads them, written beside the models.
    ///
    /// Written on every launch rather than checked: it is a hundred kilobytes, it is generated
    /// output, and the alternative is a version file to keep in step with the one thing in this
    /// feature that is already a version file.
    private func writePayload() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(BergamotGlue.source.utf8).write(to: root.appending(path: "bergamot-translator.js"))
        try Data(BergamotDriver.source.utf8).write(to: root.appending(path: "six-bergamot.js"))
        try Data(BergamotDriver.page.utf8).write(to: root.appending(path: "bergamot.html"))
    }

    // MARK: The wire

    private struct LoadRequest: Encodable {
        struct Model: Encodable {
            var from: String
            var to: String
            var gemm: String
            var files: [String: String]
        }
        var wasm: String
        var models: [Model]
    }

    private struct TranslateRequest: Encodable {
        var texts: [String]
    }

    /// Every driver function answers in this shape. A thrown JavaScript exception reaches Swift as
    /// "a JavaScript exception occurred" and nothing else on at least one of these engines, so the
    /// driver catches its own and says what happened in a field.
    private struct Answer: Decodable {
        var error: String?
        var texts: [String]?
    }
}
