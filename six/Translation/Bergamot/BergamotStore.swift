import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One model, on this machine, ready to be handed to the engine.
///
/// `files` is keyed by kind rather than by name because that is what the wasm heap wants — the
/// alignment it allocates with is per kind — and `modelName` survives alongside it for the one
/// thing the name decides: `intgemm8.bin` weights want a different gemm precision than
/// `intgemm.alphas.bin` ones, and getting that wrong translates fluent nonsense.
nonisolated struct BergamotInstalledModel: Sendable, Equatable {
    var from: String
    var to: String
    var modelName: String
    var files: [String: URL]
}

/// The engine and its weights, on disk.
///
/// Downloads are the slow, failing, resumable part of this feature and they are the part that has
/// nothing to do with translating: a model is thirty megabytes fetched once and then read from the
/// cache for years. So it is an actor and not a main-actor class — the SHA-256 of thirty megabytes
/// runs here, off the main thread, and the only thing the interface asks it is whether it is busy.
///
/// Everything lands under `Application Support/six/Translation/Bergamot`. Nothing in it is precious:
/// deleting the folder costs the next translation a download and nothing else, which is the property
/// that makes the atomic-move-after-verify below worth writing.
actor BergamotStore {
    /// How long a catalogue is believed before it is asked for again. Mozilla moves these records
    /// a few times a year; a week is short enough to pick up a new pair and long enough that the
    /// browser is not asking about it on every launch.
    static let catalogueLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let root: URL
    private let session: URLSession
    private let release: String

    private var catalogue: BergamotCatalog?
    /// One download at a time per file, shared by everyone who asked for it. Two windows
    /// translating into the same language at once is an ordinary thing, and it must not be two
    /// downloads into one path.
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// What `PageTranslating.isFetchingLanguages` reports. A count rather than a flag so that two
    /// overlapping fetches do not have the first one to finish declare the whole thing done.
    private(set) var fetching = 0
    /// Bytes, for a caller that wants to say more than "downloading". Reset when nothing is in
    /// flight, so it always describes the fetch that is happening now.
    private(set) var fetchedBytes = 0
    private(set) var expectedBytes = 0

    init(release: String, root: URL = AppSupport.folder("Translation/Bergamot"), session: URLSession = .shared) {
        self.release = release
        self.root = root
        self.session = session
    }

    var isFetching: Bool { fetching > 0 }

    // MARK: The catalogue

    /// The catalogue, from memory, then from disk, then from Mozilla.
    ///
    /// A stale copy on disk beats no copy: the network answer is better, but a browser that cannot
    /// translate an already-downloaded page because a settings server is down is worse than one
    /// working from last week's list. So a failed refresh falls back to whatever is cached, and only
    /// an empty cache turns into an error the reader sees.
    func catalog() async throws -> BergamotCatalog {
        if let catalogue { return catalogue }

        let cache = root.appending(path: "catalog.json")
        let cached = (try? Data(contentsOf: cache)).flatMap {
            try? JSONDecoder().decode(BergamotCatalog.self, from: $0)
        }
        let written = (try? FileManager.default.attributesOfItem(atPath: cache.path))?
            .compactMap { $0.key == .modificationDate ? $0.value as? Date : nil }.first
        if let cached, let written, Date().timeIntervalSince(written) < Self.catalogueLifetime {
            catalogue = cached
            return cached
        }

        do {
            let fresh = try await BergamotCatalog.fetch(release: release, session: session)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? JSONEncoder().encode(fresh).write(to: cache, options: .atomic)
            catalogue = fresh
            Log.info(.translation, "bergamot: catalogue has \(fresh.models.count) directions")
            return fresh
        } catch {
            guard let cached else { throw error }
            Log.error(.translation, "bergamot: keeping the cached catalogue — \(error.localizedDescription)")
            catalogue = cached
            return cached
        }
    }

    // MARK: What a pair needs

    /// The engine binary, fetched once and then read from the cache forever.
    func engine() async throws -> URL {
        let catalogue = try await catalog()
        return try await file(catalogue.wasm, in: "engine@\(catalogue.wasm.version)",
                              named: catalogue.wasm.name, base: catalogue.attachments)
    }

    /// Everything needed to translate this pair, downloading whatever is missing.
    ///
    /// One or two models: `route` decides, and a caller only ever hands the list straight to the
    /// engine. The order matters — pivoting applies them in it.
    func models(from source: String, to target: String) async throws -> [BergamotInstalledModel] {
        let catalogue = try await catalog()
        let route = catalogue.route(from: source, to: target)
        guard !route.isEmpty else { throw BergamotError.noRoute(source, target) }

        var installed: [BergamotInstalledModel] = []
        for model in route {
            var files: [String: URL] = [:]
            var modelName = ""
            for wanted in model.files {
                files[wanted.kind] = try await file(wanted, in: model.folder,
                                                    named: wanted.kind, base: catalogue.attachments)
                if wanted.kind == "model" { modelName = wanted.name }
            }
            installed.append(BergamotInstalledModel(from: model.from, to: model.to,
                                                    modelName: modelName, files: files))
        }
        return installed
    }

    /// Whether this pair could be translated without asking the network for anything.
    func isInstalled(from source: String, to target: String) async -> Bool {
        guard let catalogue = try? await catalog() else { return false }
        let route = catalogue.route(from: source, to: target)
        guard !route.isEmpty else { return false }
        let engine = root.appending(path: "engine@\(catalogue.wasm.version)")
            .appending(path: catalogue.wasm.name)
        guard FileManager.default.fileExists(atPath: engine.path) else { return false }
        return route.allSatisfy { model in
            model.files.allSatisfy {
                FileManager.default.fileExists(
                    atPath: root.appending(path: model.folder).appending(path: $0.kind).path)
            }
        }
    }

    /// How many bytes this pair still has to fetch. Zero means it is ready; the number is what a
    /// prompt says before a reader waits for thirty megabytes on a hotel connection.
    func missingBytes(from source: String, to target: String) async -> Int {
        guard let catalogue = try? await catalog() else { return 0 }
        var total = 0
        let engine = root.appending(path: "engine@\(catalogue.wasm.version)")
            .appending(path: catalogue.wasm.name)
        if !FileManager.default.fileExists(atPath: engine.path) { total += catalogue.wasm.size }
        for model in catalogue.route(from: source, to: target) {
            for wanted in model.files
            where !FileManager.default.fileExists(
                atPath: root.appending(path: model.folder).appending(path: wanted.kind).path) {
                total += wanted.size
            }
        }
        return total
    }

    /// Everything downloaded, and what it costs. For a settings pane that offers to remove it.
    func installedSize() -> Int {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = enumerator?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Forget every model and the engine. The catalogue stays: it is 400 kB and re-fetching it is
    /// the slow part of the next translation, not the fast part.
    func removeDownloads() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent != "catalog.json" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: One file

    /// A file in the cache, downloaded and verified if it is not there yet.
    ///
    /// The verify-then-move order is the whole point. A download interrupted half way leaves a
    /// partial file in the temporary directory and nothing at all in the cache, so the next launch
    /// tries again rather than handing five megabytes of a thirty megabyte model to the engine —
    /// which fails somewhere inside the wasm with nothing to say about why.
    private func file(_ wanted: BergamotFile, in folder: String, named: String, base: URL) async throws -> URL {
        let directory = root.appending(path: folder, directoryHint: .isDirectory)
        let destination = directory.appending(path: named)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let key = "\(folder)/\(named)"
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<URL, Error> {
            fetching += 1
            expectedBytes += wanted.size
            defer {
                fetching -= 1
                if fetching == 0 { fetchedBytes = 0; expectedBytes = 0 }
            }

            let source = base.appending(path: wanted.location)
            Log.info(.translation, "bergamot: fetching \(wanted.name) (\(wanted.size / 1024) kB)")
            let temporary = try await download(source)
            defer { try? FileManager.default.removeItem(at: temporary) }

            let digest = try Checksum.sha256(ofFileAt: temporary)
            guard digest == wanted.hash else { throw BergamotError.corrupt(wanted.name) }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Moved into place, not `replaceItemAt`. That call is the obvious one for exactly this
            // — verified file, atomic swap — and on Windows it is a `fatalError` inside
            // `FileManager`, not a thrown error, so the `try?` in front of it saves nothing and the
            // browser goes down with it. Measured: the first model six ever downloaded killed the
            // process the moment its hash checked out.
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            fetchedBytes += wanted.size
            return destination
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// `URLSession.download(from:)` again does not exist on Linux's `FoundationNetworking`, and a
    /// download task rather than a data task because these are tens of megabytes: the file goes to
    /// disk as it arrives instead of being assembled in memory first.
    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                    continuation.resume(throwing: BergamotError.server(url.absoluteString, code))
                    return
                }
                guard let location else {
                    continuation.resume(throwing: BergamotError.server(url.absoluteString, 0))
                    return
                }
                // The framework deletes its temporary the moment this closure returns, so it is
                // moved somewhere of our own before anything is awaited on it.
                let kept = FileManager.default.temporaryDirectory
                    .appending(path: "six-bergamot-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: location, to: kept)
                    continuation.resume(returning: kept)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }
}
