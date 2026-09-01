import Foundation
import Observation
import WebKit

/// Files six is fetching, and the ones it already has.
///
/// WebKit's SwiftUI `WebPage` has no download delegate — `.download` as a navigation policy has
/// nobody to hand the transfer to — so six does the transfer itself. That costs one thing and buys
/// another: the request has to be rebuilt (the page's cookies and its address as the referrer, or a
/// site that only serves a file to a signed-in session serves the sign-in page instead), and in
/// return a download is an ordinary object the strip can show, cancel and reveal.
///
/// Files land in the user's Downloads folder under the name the server suggested, never overwriting:
/// a second `report.pdf` is `report 2.pdf`, the way every browser does it.
@MainActor
@Observable
final class DownloadStore {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        /// What it will be called; the server's suggestion once the response arrives.
        var filename: String
        /// Where it ended up. Nil until it has.
        var destination: URL?
        var received: Int64 = 0
        /// -1 while the server hasn't said (a chunked response) — the row shows no bar for it.
        var expected: Int64 = -1
        var state: State = .running
        var error: String?
        let startedAt = Date()

        var fraction: Double? {
            guard expected > 0 else { return nil }
            return min(1, Double(received) / Double(expected))
        }
    }

    enum State: Equatable {
        case running, finished, failed, cancelled
    }

    /// Newest first — the order the popover reads in.
    private(set) var items: [Item] = []
    /// Set when something finishes while the popover is closed, so the button can say so.
    private(set) var hasUnseen = false

    var running: [Item] { items.filter { $0.state == .running } }
    var isRunning: Bool { !running.isEmpty }
    /// One number for the whole button: the mean of what is in flight, ignoring the sizeless ones.
    var progress: Double? {
        let known = running.compactMap(\.fraction)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    @ObservationIgnored private var transfers: Transfers!
    /// Item id per URLSession task, so a callback knows what it is talking about.
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]

    init() {
        transfers = Transfers(store: self)
    }

    // MARK: Starting one

    /// Starts a download for what the page asked to save. `dataStore` is the profile's, and the only
    /// place the session cookies live: without them a private file comes back as a login page.
    func start(_ request: URLRequest, suggestedName: String? = nil, referrer: URL? = nil,
               cookies dataStore: WKWebsiteDataStore?) {
        guard let url = request.url else { return }
        let item = Item(url: url, filename: suggestedName ?? Self.name(from: url))
        items.insert(item, at: 0)
        Task {
            var outgoing = request
            outgoing.setValue(UserAgent.full, forHTTPHeaderField: "User-Agent")
            if let referrer { outgoing.setValue(referrer.absoluteString, forHTTPHeaderField: "Referer") }
            if let dataStore {
                let jar = await dataStore.httpCookieStore.allCookies()
                let matching = jar.filter { $0.matches(url) }
                if !matching.isEmpty {
                    for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
                        outgoing.setValue(value, forHTTPHeaderField: field)
                    }
                }
            }
            let task = transfers.session.downloadTask(with: outgoing)
            transfers.note(item.id, for: task.taskIdentifier)
            tasks[item.id] = task
            task.resume()
            LinkTrace.log("downloading \(url.absoluteString) as \(item.filename)")
        }
    }

    func cancel(_ id: Item.ID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        update(id) { $0.state = .cancelled }
    }

    /// Takes the row off the list. The file, if there is one, stays where it was put.
    func forget(_ id: Item.ID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    func markSeen() { hasUnseen = false }


    // MARK: What the transfer says

    fileprivate func note(_ id: Item.ID, received: Int64, expected: Int64) {
        update(id) {
            $0.received = received
            $0.expected = expected
        }
    }

    fileprivate func finish(_ id: Item.ID, at destination: URL) {
        tasks[id] = nil
        update(id) {
            $0.destination = destination
            $0.filename = destination.lastPathComponent
            $0.received = max($0.received, $0.expected)
            $0.state = .finished
        }
        hasUnseen = true
    }

    fileprivate func fail(_ id: Item.ID, _ message: String) {
        tasks[id] = nil
        update(id) {
            guard $0.state == .running else { return } // a cancel is not a failure
            $0.state = .failed
            $0.error = message
        }
        hasUnseen = true
    }

    private func update(_ id: Item.ID, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    // MARK: Where files go

    /// The user's Downloads folder on a Mac; on a phone the app's own documents, which is the only
    /// folder there is.
    static let folder: URL = {
        #if os(macOS)
        let search = FileManager.SearchPathDirectory.downloadsDirectory
        #elseif os(iOS)
        let search = FileManager.SearchPathDirectory.documentDirectory
        #endif
        if let url = FileManager.default.urls(for: search, in: .userDomainMask).first { return url }
        return URL.homeDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }()

    /// A name from the address, for a server that suggested none: the last path component, or the
    /// host — never empty, and never a path.
    nonisolated static func name(from url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host() ?? "download"
    }
}

private extension HTTPCookie {
    /// Would this cookie be sent with a request for this URL? `HTTPCookie.requestHeaderFields` does
    /// not check — it writes down whatever it is given — so the domain, the path and `secure` are
    /// checked here, or a session cookie for one site travels to another.
    func matches(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let cookieDomain = domain.lowercased()
        let domainMatches = cookieDomain.hasPrefix(".")
            ? host == String(cookieDomain.dropFirst()) || host.hasSuffix(cookieDomain)
            : host == cookieDomain
        guard domainMatches else { return false }
        // The cookie's path is a prefix of the request's, on a path-component boundary: `/app` covers
        // `/app` and `/app/one`, and not `/application`.
        let requestPath = url.path().isEmpty ? "/" : url.path()
        let boundary = path.hasSuffix("/") ? path : path + "/"
        guard path == "/" || requestPath == path || requestPath.hasPrefix(boundary) else { return false }
        if isSecure, url.scheme?.lowercased() != "https" { return false }
        return true
    }
}

/// The URLSession side, off the main actor. It owns the move out of the temporary file, which has to
/// happen inside `didFinishDownloadingTo` — the file is gone the moment that call returns.
private final class Transfers: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Weak: the session holds its delegate for as long as it lives, and the store holds the session.
    private weak var store: DownloadStore?
    private var ids: [Int: UUID] = [:]
    private let lock = NSLock()

    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil // six brings the page's cookies itself
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(store: DownloadStore) {
        self.store = store
    }

    func note(_ id: UUID, for taskIdentifier: Int) {
        lock.withLock { ids[taskIdentifier] = id }
    }

    private func id(of task: URLSessionTask) -> UUID? {
        lock.withLock { ids[task.taskIdentifier] }
    }

    private func forget(_ task: URLSessionTask) {
        _ = lock.withLock { ids.removeValue(forKey: task.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = id(of: downloadTask), let store else { return }
        Task { @MainActor in
            store.note(id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = id(of: downloadTask), let store else { return }
        let suggested = downloadTask.response?.suggestedFilename
            ?? downloadTask.originalRequest?.url.map(DownloadStore.name(from:))
            ?? "download"
        do {
            let destination = try Self.place(location, named: suggested)
            Task { @MainActor in store.finish(id, at: destination) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in store.fail(id, message) }
        }
    }

    /// The same second reading a page's own handshake gets (`CertificateStore.decide(_:)`). Without
    /// it a site six can *show* — under an anchor the user switched on — is a site six cannot
    /// download a statement from, because the transfer is this session's and not WebKit's.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let certificates = await CertificateStore.shared else { return (.performDefaultHandling, nil) }
        return await certificates.decide(challenge)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { forget(task) }
        guard let error, let id = id(of: task), let store else { return }
        let message = (error as NSError).code == NSURLErrorCancelled ? "" : error.localizedDescription
        guard !message.isEmpty else { return }
        Task { @MainActor in store.fail(id, message) }
    }

    /// Moves the finished file next to the others, under a name nothing else has. Called on the
    /// session's queue, synchronously, because the temporary file outlives this call by nothing.
    private static func place(_ temporary: URL, named suggested: String) throws -> URL {
        let folder = DownloadStore.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = suggested
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safe.isEmpty ? "download" : safe
        var candidate = folder.appending(path: name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            var counter = 2
            repeat {
                let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                candidate = folder.appending(path: numbered)
                counter += 1
            } while FileManager.default.fileExists(atPath: candidate.path) && counter < 1000
        }
        try FileManager.default.moveItem(at: temporary, to: candidate)
        // A download session's temporary file is the process's alone (0600); a file in the Downloads
        // folder is the user's, the way every other browser leaves it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidate.path)
        return candidate
    }
}
