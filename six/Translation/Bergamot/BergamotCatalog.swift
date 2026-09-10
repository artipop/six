import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One file a translation model is made of, as Mozilla publishes it.
///
/// Five kinds exist and a model uses three of them: `model` (the weights), `lex` (the shortlist)
/// and either one `vocab` or a `srcvocab`/`trgvocab` pair. The alignment each wants in the wasm
/// heap is not stated in the record — it is a constant of the engine — so it lives beside the
/// JavaScript that allocates the memory, not here.
nonisolated struct BergamotFile: Sendable, Equatable, Codable {
    var name: String
    /// `model`, `lex`, `vocab`, `srcvocab`, `trgvocab` — the engine keys its heap allocation by it.
    var kind: String
    /// Where the attachment sits, relative to the CDN the server names for itself.
    var location: String
    var size: Int
    /// SHA-256, lowercase hex. What `Checksum` is for.
    var hash: String
    var version: String
}

/// One direction, and the files that translate it.
nonisolated struct BergamotModel: Sendable, Equatable, Codable {
    var from: String
    var to: String
    var files: [BergamotFile]

    var version: String { files.first?.version ?? "" }
    var bytes: Int { files.reduce(0) { $0 + $1.size } }
    /// What the cache calls this model's folder. The version is in the name because a model that
    /// moves is a different model, and the old one must not be read as the new one.
    var folder: String { "\(from)-\(to)@\(version)" }
}

/// What Mozilla is publishing today: the engine, and every pair it has weights for.
///
/// This is the same Remote Settings collection Firefox reads — `translations-wasm` for the engine
/// and `translations-models` for the weights, both public, both unauthenticated, both served as
/// plain attachments. (There are `-v2` collections beside them carrying the same files zstd
/// compressed; six reads v1 because it has no zstd, and thirty megabytes once per language is not
/// worth a decompressor in a dependency graph CLAUDE.md spends a chapter on keeping still.)
///
/// Nothing here touches the disk or decides anything about a page. It answers one question —
/// *which files, at which version, for which pair* — and `BergamotStore` fetches what it names.
nonisolated struct BergamotCatalog: Sendable, Codable {
    /// The CDN the settings server names for itself, so a move upstream needs no release here.
    var attachments: URL
    /// The engine binary, at the release the vendored glue was generated with.
    var wasm: BergamotFile
    /// One entry per direction, already reduced to the newest release version.
    var models: [BergamotModel]

    static let server = URL(string: "https://firefox.settings.services.mozilla.com/v1/")!
    /// What the server has answered for years, and what is used when the root document cannot be
    /// read. Losing the whole catalogue because one of three requests failed would be silly.
    static let fallbackAttachments = URL(string: "https://firefox-settings-attachments.cdn.mozilla.net/")!

    // MARK: Fetching

    /// Asks the settings server for both collections. `release` is the engine version the vendored
    /// glue belongs to, spelled as the record spells it — `v0.6.0`.
    static func fetch(release: String, session: URLSession = .shared) async throws -> BergamotCatalog {
        async let root = data(from: server, session: session)
        async let engines = data(from: records("translations-wasm"), session: session)
        async let models = data(from: records("translations-models"), session: session)
        return try decode(
            root: try? await root,
            wasm: try await engines,
            models: try await models,
            release: release
        )
    }

    private static func records(_ collection: String) -> URL {
        server.appending(path: "buckets/main/collections/\(collection)/records")
    }

    /// The continuation is spelled out rather than using `URLSession.data(from:)` because that
    /// async form is missing from `FoundationNetworking` on Linux, and this is the one place three
    /// call sites would otherwise each have to know that.
    static func data(from url: URL, session: URLSession) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: url) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                    continuation.resume(throwing: BergamotError.server(url.absoluteString, code))
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
            task.resume()
        }
    }

    // MARK: Reading the records

    /// Split out from `fetch` because it is the half worth a test: which of five versions of a
    /// model is the current one is exactly the sort of comparison that is quietly wrong for a year.
    static func decode(root: Data?, wasm: Data, models: Data, release: String) throws -> BergamotCatalog {
        let attachments = root.flatMap { data -> URL? in
            guard let object = try? JSONDecoder().decode(ServerRoot.self, from: data) else { return nil }
            return URL(string: object.capabilities.attachments.base_url)
        } ?? fallbackAttachments

        let engines = try JSONDecoder().decode(Records<WasmRecord>.self, from: wasm).data
        guard let engine = engines.first(where: {
            $0.name == "bergamot-translator" && $0.release == release
        }) else {
            throw BergamotError.noEngine(release)
        }

        let records = try JSONDecoder().decode(Records<ModelRecord>.self, from: models).data
        return BergamotCatalog(attachments: attachments, wasm: engine.file, models: reduce(records))
    }

    /// One record per file per version per pair goes in; one model per pair comes out.
    ///
    /// A pair carries every version Mozilla has ever shipped — five of them for Russian — including
    /// pre-releases (`1.1a1`), which are Nightly's and are skipped here for the reason Firefox skips
    /// them on release. The files of one model must all come from one version: weights and a
    /// shortlist from different builds load happily and then translate nonsense.
    private static func reduce(_ records: [ModelRecord]) -> [BergamotModel] {
        var byPair: [String: [ModelRecord]] = [:]
        for record in records where !record.fromLang.isEmpty && !record.toLang.isEmpty {
            byPair["\(record.fromLang)\u{1}\(record.toLang)", default: []].append(record)
        }
        return byPair.values.compactMap { forPair -> BergamotModel? in
            let versions = Set(forPair.map(\.version)).filter { isRelease($0) }
            guard let newest = versions.max(by: { isOlder($0, than: $1) }) else { return nil }
            let files = forPair.filter { $0.version == newest }.map(\.file)
            guard files.contains(where: { $0.kind == "model" }) else { return nil }
            return BergamotModel(from: forPair[0].fromLang, to: forPair[0].toLang, files: files)
        }
        .sorted { ($0.from, $0.to) < ($1.from, $1.to) }
    }

    /// `2.1` yes, `2.1a1` no. Anything with a letter in it is a pre-release.
    static func isRelease(_ version: String) -> Bool {
        !version.isEmpty && version.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Numeric, component by component — `1.10` is newer than `1.9`, which a string comparison gets
    /// backwards.
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    // MARK: Routing

    /// The models that get from one language to another, in the order they are applied.
    ///
    /// Mozilla trains against English and nothing else: there are 111 directions and every one of
    /// them has English at one end. So Russian to German is two models and a round trip through
    /// English — what Bergamot calls pivoting, and what its `translateViaPivoting` does in one pass
    /// without the intermediate text ever coming back to us. Empty when there is no route, which is
    /// the honest answer for a pair like Maltese to French where only `mt-en` was ever trained.
    func route(from source: String, to target: String) -> [BergamotModel] {
        if source == target { return [] }
        if let direct = models.first(where: { $0.from == source && $0.to == target }) {
            return [direct]
        }
        guard source != "en", target != "en",
              let first = models.first(where: { $0.from == source && $0.to == "en" }),
              let second = models.first(where: { $0.from == "en" && $0.to == target })
        else { return [] }
        return [first, second]
    }

    /// Everything six can translate *into* from this language. For a menu, so it is language codes
    /// and not pairs.
    func targets(from source: String) -> [String] {
        let direct = models.filter { $0.from == source }.map(\.to)
        guard source == "en" || direct.contains("en") else { return direct.sorted() }
        let viaEnglish = models.filter { $0.from == "en" }.map(\.to)
        return Array(Set(direct + viaEnglish).subtracting([source])).sorted()
    }

    /// Every language six can translate *from*.
    var sources: [String] { Array(Set(models.map(\.from))).sorted() }

    // MARK: The wire

    private struct Records<Record: Decodable>: Decodable { var data: [Record] }

    private struct ServerRoot: Decodable {
        struct Capabilities: Decodable {
            struct Attachments: Decodable { var base_url: String }
            var attachments: Attachments
        }
        var capabilities: Capabilities
    }

    private struct Attachment: Decodable {
        var hash: String
        var size: Int
        var filename: String
        var location: String
    }

    private struct WasmRecord: Decodable {
        var name: String
        var release: String
        var version: String
        var attachment: Attachment

        var file: BergamotFile {
            BergamotFile(name: attachment.filename, kind: "wasm", location: attachment.location,
                         size: attachment.size, hash: attachment.hash, version: version)
        }
    }

    private struct ModelRecord: Decodable {
        var name: String
        var fileType: String
        var fromLang: String
        var toLang: String
        var version: String
        var attachment: Attachment

        var file: BergamotFile {
            BergamotFile(name: attachment.filename, kind: fileType, location: attachment.location,
                         size: attachment.size, hash: attachment.hash, version: version)
        }
    }
}

/// What can go wrong before a word has been translated.
nonisolated enum BergamotError: LocalizedError, Equatable {
    case server(String, Int)
    case noEngine(String)
    case noRoute(String, String)
    case corrupt(String)
    case engine(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .server(let url, let code):
            "\(url) answered \(code)"
        case .noEngine(let release):
            "Mozilla is no longer publishing the Bergamot engine \(release)"
        case .noRoute(let source, let target):
            "There is no translation from \(source) to \(target)"
        case .corrupt(let name):
            "\(name) did not arrive intact"
        case .engine(let message):
            message
        case .notReady:
            "The translator has not finished loading"
        }
    }
}
