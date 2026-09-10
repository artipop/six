import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The embedder's half of the disk: the JavaScript runtime, and the weights of whichever model is
/// chosen, downloaded once and verified before anything is allowed to read them.
///
/// The same shape as `BergamotStore`, deliberately and almost line for line, because it is the same
/// problem — a program and its weights, fetched from somebody else's server, wanted by a page that
/// cannot ask for them itself. Where the two differ is where they are allowed to: Bergamot's
/// digests come from Mozilla's catalogue, and this one's come half from a constant in
/// `EmbeddingCatalog` and half from the Hugging Face API. Whether those two stores should be one is
/// a fair question and the answer is not yet: what they share is forty lines of download-and-verify
/// and nothing about what is being downloaded.
///
/// Layout under `<Application Support>/Embedding`, and it is the page's own root, so everything in
/// it is named by a *relative* path:
///
///     runtime@3.8.1/transformers.min.js, …jsep.mjs, …jsep.wasm
///     models/multilingual-e5-small/{config.json, tokenizer.json, tokenizer_config.json, onnx/…}
///     six-embed.html, six-embed.js          ← written on every launch, not downloaded
///
/// The model folder is named after `EmbeddingModelChoice.modelID` because that is what
/// transformers.js is asked for by name, and because it is the same string a vector is stamped
/// with — one name for the model, in the index and on the disk.
@MainActor
final class EmbeddingStore {
    private let root: URL
    private let session: URLSession
    private var listings: [EmbeddingModelChoice: [EmbeddingFile]] = [:]
    /// One download per file, however many callers arrive: the first bookmark and the first search
    /// of a launch both want the model, and they are usually a second apart.
    private var inFlight: [String: Task<URL, Error>] = [:]

    /// How many files are in the air, and how far along they are, for whoever draws a progress line.
    private(set) var fetching = 0
    private(set) var fetchedBytes = 0
    private(set) var expectedBytes = 0

    var isFetching: Bool { fetching > 0 }

    init(root: URL = AppSupport.folder("Embedding"), session: URLSession = .shared) {
        self.root = root
        self.session = session
    }

    /// The folder the page reads everything out of.
    var pageRoot: URL { root }

    // MARK: What the page needs

    /// transformers.js and the wasm behind it, on disk. The folder carries the version, so a
    /// six that has moved on to a newer runtime downloads it beside the old one rather than over it
    /// — and `removeDownloads` is what actually reclaims the twenty-two megabytes.
    @discardableResult
    func runtime() async throws -> URL {
        let folder = "runtime@\(EmbeddingCatalog.runtimeVersion)"
        for file in EmbeddingCatalog.runtime {
            _ = try await install(file, in: folder)
        }
        return root.appending(path: folder, directoryHint: .isDirectory)
    }

    /// The chosen model's weights and tokenizer, on disk.
    @discardableResult
    func model(_ choice: EmbeddingModelChoice) async throws -> URL {
        let folder = "models/\(choice.modelID)"
        for file in try await listing(choice) {
            _ = try await install(file, in: folder)
        }
        return root.appending(path: folder, directoryHint: .isDirectory)
    }

    /// Whether everything is already here, asked without touching the network.
    ///
    /// The size is compared as well as the name, because the failure this is guarding against is a
    /// download that stopped half way — and a truncated 118 MB file is a file that exists. The
    /// digest is not re-checked: hashing a hundred megabytes to answer "may I show a button" is the
    /// wrong trade, and `install` has already checked it once, before the file was ever put here.
    func isInstalled(_ choice: EmbeddingModelChoice) -> Bool {
        let runtime = "runtime@\(EmbeddingCatalog.runtimeVersion)"
        guard EmbeddingCatalog.runtime.allSatisfy({ has($0.name, in: runtime, sized: $0.size) }) else { return false }
        let folder = "models/\(choice.modelID)"
        if let files = listings[choice] {
            return files.allSatisfy { has($0.name, in: folder, sized: $0.size) }
        }
        // Before the catalogue has been asked for there are no sizes to compare against, and the
        // question being asked this early — may this model be offered without a download — is
        // answered well enough by the four names being there with something in them.
        return EmbeddingCatalog.modelFiles.allSatisfy { has($0, in: folder, sized: 0) }
    }

    private func has(_ name: String, in folder: String, sized expected: Int) -> Bool {
        let url = root.appending(path: folder, directoryHint: .isDirectory).appending(path: name)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return expected == 0 ? size > 0 : size == expected
    }

    /// What the downloads are taking up, for the settings page that offers to remove them.
    func installedSize() -> Int {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Forget the runtime and every model. The page itself is written on every launch, so there is
    /// nothing here worth keeping.
    func removeDownloads() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in contents { try? FileManager.default.removeItem(at: url) }
        listings.removeAll()
    }

    // MARK: The catalogue

    /// The model's file list, asked for once per launch. Cached because it is the same four rows
    /// every time and the answer costs a round trip to Hugging Face.
    private func listing(_ choice: EmbeddingModelChoice) async throws -> [EmbeddingFile] {
        if let listings = listings[choice] { return listings }
        let fresh = try await EmbeddingCatalog.model(choice, session: session)
        listings[choice] = fresh
        return fresh
    }

    // MARK: One file

    /// A file in the cache, downloaded and verified if it is not there yet.
    ///
    /// Verify, then move — the order is the point, and it is `BergamotStore`'s for the same reason.
    /// A download interrupted half way leaves a partial file in the temporary directory and nothing
    /// at all in the cache, so the next launch tries again rather than handing sixty megabytes of a
    /// hundred-and-eighteen megabyte model to a wasm runtime, which fails somewhere inside ONNX
    /// with nothing useful to say about why.
    @discardableResult
    private func install(_ wanted: EmbeddingFile, in folder: String) async throws -> URL {
        let directory = root.appending(path: folder, directoryHint: .isDirectory)
        let destination = directory.appending(path: wanted.name)
        if has(wanted.name, in: folder, sized: wanted.size) { return destination }

        let key = "\(folder)/\(wanted.name)"
        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<URL, Error> {
            fetching += 1
            expectedBytes += wanted.size
            defer {
                fetching -= 1
                if fetching == 0 { fetchedBytes = 0; expectedBytes = 0 }
            }

            Log.info(.bookmarks, "embedder: fetching \(key) (\(wanted.size / 1024) kB)")
            let temporary = try await download(wanted.url)
            defer { try? FileManager.default.removeItem(at: temporary) }

            if !wanted.sha256.isEmpty {
                let digest = try Checksum.sha256(ofFileAt: temporary)
                guard digest == wanted.sha256 else {
                    throw EmbedderError.unavailable("\(wanted.name) did not match its digest")
                }
            }

            // `wanted.name` can carry a folder of its own — `onnx/model_quantized.onnx` — and the
            // page needs it to keep it, so the parent is made from the destination rather than
            // from `directory`.
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Moved into place, not `replaceItemAt` — the same trap `BergamotStore` documents, and
            // it is worth repeating because the call really is the obvious one for a verified file.
            // On Windows `replaceItemAt` is a `fatalError` inside swift-corelibs `FileManager`, not
            // a thrown error, so a `try?` in front of it saves nothing and the browser goes down
            // with it. It was measured on the other feature: the first model six ever downloaded
            // killed the process the moment its hash checked out.
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

    /// A download task rather than a data task, because one of these is a hundred megabytes: the
    /// file goes to disk as it arrives instead of being assembled in memory first. Spelled out with
    /// a continuation because `URLSession.download(from:)` is missing from `FoundationNetworking`
    /// on Linux — the same gap `BergamotStore` steps over in the same way.
    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                    continuation.resume(throwing: EmbedderError.unavailable("\(url.absoluteString) answered \(code)"))
                    return
                }
                guard let location else {
                    continuation.resume(throwing: EmbedderError.unavailable("\(url.absoluteString) returned nothing"))
                    return
                }
                // The framework deletes its temporary the moment this closure returns, so it is
                // moved somewhere of our own before anything is awaited on it.
                let kept = FileManager.default.temporaryDirectory
                    .appending(path: "six-embed-\(UUID().uuidString)")
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
