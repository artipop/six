import CRailInterop
import CWebKit2
import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// Files a page handed over, and the list the bar's button opens.
///
/// The transfer is WebKit's, which is the one way this front is simpler than the Mac. There the
/// SwiftUI `WebPage` has no download delegate, so six rebuilds the request — cookies, referrer, user
/// agent — and runs it through `URLSession` itself ([links.md](../../../docs/links.md#downloads)). The
/// C API has downloads: a navigation answered "download" (`RailWebView`'s navigation client) becomes
/// a `WKDownloadRef`, already carrying the page's cookies, and all six adds is a client — where the
/// file goes, how far it has got, and how it ended.
///
/// **Not built, and why.** The Mac resumes a stopped transfer from the blob `URLSession` hands back;
/// WebKit's C API hands a blob back too (`didFailWithError`'s `resumeData`) and has nothing to give it
/// to, so a stopped download here is stopped. For the same reason there is no Try Again — nothing in
/// the API starts a download from an address — and the unfinished rows are not written down for the
/// next launch, because a row that could only offer nothing is not worth restoring.
@MainActor
final class RailDownloads {
    struct Item {
        let id = Foundation.UUID()
        let url: String
        /// What it will be called — the server's suggestion once the response arrives.
        var filename: String
        /// Where it goes: a native path, set when WebKit asks.
        var destination: String?
        var received: Int64 = 0
        /// Unknown until the response says, and for a chunked one it never does.
        var expected: Int64 = -1
        var state: State = .running
        var error: String?

        var fraction: Double? {
            guard expected > 0 else { return nil }
            return min(1, Double(received) / Double(expected))
        }

        var host: String { URL(string: url)?.host() ?? "" }
    }

    enum State { case running, finished, failed, cancelled }

    /// Newest first, the order the list reads in.
    private(set) var items: [Item] = []
    /// Something finished while the list was closed, so the button can say so.
    private(set) var hasUnseen = false

    var isEmpty: Bool { items.isEmpty }
    var isRunning: Bool { items.contains { $0.state == .running } }
    /// One number for the button: the mean of what is in flight, the sizeless ones left out.
    var progress: Double? {
        let known = items.filter { $0.state == .running }.compactMap(\.fraction)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    private let changed: () -> Void
    private var transfers: [Foundation.UUID: Transfer] = [:]
    /// Paths handed to a transfer that has not finished writing them — `fileExists` cannot see a file
    /// two downloads of `report.pdf` are both about to create.
    private var reserved: Set<String> = []
    private var lastTick = Date.distantPast

    init(changed: @escaping () -> Void) {
        self.changed = changed
    }

    // MARK: Starting and stopping

    /// A download WebKit has started: a row, and a client that fills it in.
    func adopt(_ download: WKDownloadRef) {
        let url = Self.address(of: download)
        let item = Item(url: url, filename: Self.name(from: url))
        items.insert(item, at: 0)
        let transfer = Transfer(id: item.id, download: download, store: self)
        transfers[item.id] = transfer
        transfer.install()
        // Never the address or the name: both say what somebody was fetching.
        Log.info(.pages, "a download started")
        changed()
    }

    /// Stops a running download. WebKit answers with `didFailWithError` a moment later, which is where
    /// the transfer is let go — not here, where its client could still be called.
    func cancel(_ id: Foundation.UUID) {
        guard let transfer = transfers[id], items.first(where: { $0.id == id })?.state == .running else { return }
        update(id) { $0.state = .cancelled }
        WKDownloadCancel(transfer.download, nil, nil)
        changed()
    }

    /// Delete in the list: a running download is stopped, anything else leaves the list. The file,
    /// if there is one, stays where it was put — the Mac's rule.
    func stopOrForget(_ row: String) {
        guard let id = Foundation.UUID(uuidString: row),
              let item = items.first(where: { $0.id == id }) else { return }
        if item.state == .running {
            cancel(id)
        } else {
            items.removeAll { $0.id == id }
            changed()
        }
    }

    /// Enter in the list: a finished file, opened with whatever the system opens it with.
    func open(_ row: String) {
        guard let id = Foundation.UUID(uuidString: row),
              let item = items.first(where: { $0.id == id }), item.state == .finished,
              let destination = item.destination else { return }
        _ = destination.withCString(encodedAs: UTF16.self) { SixRailShellOpen($0) }
    }

    func markSeen() {
        guard hasUnseen else { return }
        hasUnseen = false
        changed()
    }

    // MARK: What the transfer says

    /// Where the file goes, asked once, when the response has arrived. `nil` stops the download,
    /// which is the answer for a folder that cannot be made.
    fileprivate func destination(for id: Foundation.UUID, suggested: String) -> String? {
        let folder = Self.folder
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            Log.error(.pages, "the downloads folder could not be made: \(error)")
            return nil
        }
        let row = items.first(where: { $0.id == id })
        let fallback = row?.filename ?? "download"
        let path = unique(Self.safe(Self.meaningful(suggested, for: row?.url ?? "") ? suggested : fallback), in: folder)
        reserved.insert(path)
        update(id) {
            $0.destination = path
            $0.filename = Self.lastComponent(of: path)
        }
        changed()
        return path
    }

    /// A progress tick, which arrives far more often than a window should repaint: a state change
    /// always repaints, a tick at most four times a second.
    fileprivate func note(_ id: Foundation.UUID, received: Int64, expected: Int64) {
        update(id) {
            $0.received = received
            if expected > 0 { $0.expected = expected }
        }
        let now = Date()
        guard now.timeIntervalSince(lastTick) >= 0.25 else { return }
        lastTick = now
        changed()
    }

    fileprivate func finish(_ id: Foundation.UUID) {
        var size: Int64 = 0
        update(id) {
            $0.received = max($0.received, $0.expected)
            // A file small enough to arrive in one piece finishes without a single `didWriteData`,
            // which left it "Done · 0 B" in the list; the file on disk knows better.
            if $0.received <= 0, let path = $0.destination,
               let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                $0.received = bytes.int64Value
            }
            $0.state = .finished
            size = $0.received
        }
        end(id)
        hasUnseen = true
        Log.info(.pages, "a download finished, \(size) bytes")
        changed()
    }

    fileprivate func fail(_ id: Foundation.UUID, _ message: String) {
        var stopped = false
        update(id) {
            // A cancel arrives here as a failure too; the row already says what happened.
            guard $0.state == .running else { stopped = true; return }
            $0.state = .failed
            $0.error = message.isEmpty ? nil : message
        }
        end(id)
        if !stopped { hasUnseen = true }
        Log.info(.pages, stopped ? "a download was stopped" : "a download failed")
        changed()
    }

    private func end(_ id: Foundation.UUID) {
        if let path = items.first(where: { $0.id == id })?.destination { reserved.remove(path) }
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        WKRelease(UnsafeRawPointer(transfer.download))
    }

    private func update(_ id: Foundation.UUID, _ body: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }

    // MARK: Where files go

    /// The user's Downloads folder, wherever they moved it — `SHGetKnownFolderPath`, not
    /// `%USERPROFILE%\Downloads`, which is only where it starts out — with `SIX_DOWNLOADS` in front of
    /// it, so a test run does not fill the real one, the way `SIX_URL` points a run at a test page.
    ///
    /// Called from Swift rather than from `CRailInterop`: the declaration lives in `WinSDK.Shell`, and
    /// a C header in a module of its own cannot see it there however it includes `shlobj_core.h`.
    /// `FOLDERID_Downloads` is spelled out so one GUID does not cost a link against `uuid.lib`.
    static let folder: String = {
        if let override = ProcessInfo.processInfo.environment["SIX_DOWNLOADS"], !override.isEmpty {
            return override
        }
        var downloads = GUID(Data1: 0x374D_E290, Data2: 0x123F, Data3: 0x4565,
                             Data4: (0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B))
        var path: PWSTR?
        if SHGetKnownFolderPath(&downloads, 0, nil, &path) >= 0, let path {
            defer { CoTaskMemFree(path) }
            return String(decodingCString: path, as: UTF16.self)
        }
        return NSHomeDirectory() + "\\Downloads"
    }()

    /// The Mac's rule — `report.pdf`, then `report 2.pdf` — against the files already there and the
    /// ones other downloads are about to write.
    private func unique(_ name: String, in folder: String) -> String {
        func path(_ file: String) -> String { folder.hasSuffix("\\") ? folder + file : folder + "\\" + file }
        let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
        let base = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[name.index(after: $0)...]) } ?? ""
        var candidate = path(name)
        var counter = 2
        while (FileManager.default.fileExists(atPath: candidate) || reserved.contains(candidate)) && counter < 1000 {
            candidate = path(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// A name Windows will take: none of `\ / : * ? " < > |`, no control characters, and no dot or
    /// space at the end, which Windows quietly drops and then cannot find the file by.
    static func safe(_ suggested: String) -> String {
        let forbidden = Set("\\/:*?\"<>|")
        var name = String(suggested.map { forbidden.contains($0) || $0.isNewline || ($0.asciiValue ?? 32) < 32 ? "-" : $0 })
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        return name.isEmpty ? "download" : name
    }

    /// A name from the address, for a server that suggested none: the Mac's `DownloadStore.name(from:)`,
    /// and "download" for a `data:` or `blob:` address, whose "last path component" is its payload —
    /// measured, a `data:application/octet-stream,…` link came down as `octet-stream,binary bytes`.
    static func name(from address: String) -> String {
        guard let url = URL(string: address) else { return "download" }
        if let scheme = url.scheme?.lowercased(), scheme == "data" || scheme == "blob" { return "download" }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host() ?? "download"
    }

    /// Is WebKit's suggestion a name, or the tail of the address? For a `data:` link with no
    /// `download` attribute WebKit suggests whatever follows the last slash — measured,
    /// `data:application/octet-stream,binary bytes` came down as `octet-stream,binary bytes` — and the
    /// comma that starts a `data:` payload is what gives it away. A name the page chose stays.
    static func meaningful(_ suggested: String, for address: String) -> Bool {
        guard !suggested.isEmpty else { return false }
        guard address.lowercased().hasPrefix("data:") else { return true }
        return !suggested.contains(",")
    }

    private static func lastComponent(of path: String) -> String {
        path.split(separator: "\\").last.map(String.init) ?? path
    }

    private static func address(of download: WKDownloadRef) -> String {
        guard let request = WKDownloadCopyRequest(download) else { return "" }
        defer { WKRelease(UnsafeRawPointer(request)) }
        guard let url = WKURLRequestCopyURL(request) else { return "" }
        defer { WKRelease(UnsafeRawPointer(url)) }
        return RailWebView.takeString(WKURLCopyString(url))
    }

    // MARK: The list

    /// The row's second line: how far, or how it ended, and from where.
    static func detail(of item: Item) -> String {
        let status: String
        switch item.state {
        case .running:
            status = item.expected > 0 ? "\(size(item.received)) of \(size(item.expected))" : "\(size(item.received))…"
        case .finished:
            status = "Done · \(size(item.received))"
        case .failed:
            status = "Failed" + (item.error.map { ": \($0)" } ?? "")
        case .cancelled:
            status = "Stopped"
        }
        return item.host.isEmpty ? status : "\(status) · \(item.host)"
    }

    static func size(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        switch value {
        case ..<1024: return "\(Int(value)) B"
        case ..<(1024 * 1024): return String(format: "%.0f KB", value / 1024)
        case ..<(1024 * 1024 * 1024): return String(format: "%.1f MB", value / 1024 / 1024)
        default: return String(format: "%.2f GB", value / 1024 / 1024 / 1024)
        }
    }
}

/// One transfer's client: the object WebKit's C callbacks find their way back to through
/// `clientInfo`, alive in `RailDownloads.transfers` for exactly as long as the download is.
@MainActor
private final class Transfer {
    let id: Foundation.UUID
    let download: WKDownloadRef
    weak var store: RailDownloads?

    init(id: Foundation.UUID, download: WKDownloadRef, store: RailDownloads) {
        self.id = id
        self.download = download
        self.store = store
        // Held until the download says how it ended; `RailDownloads.end` lets it go.
        WKRetain(UnsafeRawPointer(download))
    }

    func install() {
        var client = WKDownloadClientV0()
        client.base.version = 0
        client.base.clientInfo = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        client.decideDestinationWithResponse = { _, _, suggested, clientInfo in
            guard let clientInfo else { return nil }
            nonisolated(unsafe) let offered = suggested
            nonisolated(unsafe) var path: WKStringRef?
            let transfer = Unmanaged<Transfer>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                let name = RailWebView.string(from: offered)
                guard let chosen = transfer.store?.destination(for: transfer.id, suggested: name) else { return }
                // At +1: WebKit adopts the path it is handed, as MiniBrowser's own client assumes.
                path = chosen.withCString { WKStringCreateWithUTF8CString($0) }
            }
            return path
        }
        client.didWriteData = { _, _, total, expected, clientInfo in
            guard let clientInfo else { return }
            let transfer = Unmanaged<Transfer>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { transfer.store?.note(transfer.id, received: total, expected: expected) }
        }
        client.didFinish = { _, clientInfo in
            guard let clientInfo else { return }
            let transfer = Unmanaged<Transfer>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated { transfer.store?.finish(transfer.id) }
        }
        client.didFailWithError = { _, error, _, clientInfo in
            guard let clientInfo else { return }
            nonisolated(unsafe) let failure = error
            let transfer = Unmanaged<Transfer>.fromOpaque(clientInfo).takeUnretainedValue()
            MainActor.assumeIsolated {
                let message = failure.map { RailWebView.takeString(WKErrorCopyLocalizedDescription($0)) } ?? ""
                transfer.store?.fail(transfer.id, message)
            }
        }
        WKDownloadSetClient(download, &client.base)
    }
}

// MARK: The bar's side of it

extension RailWindow {
    /// The model changed: the button repaints, and the list, if it is open, reads its rows again.
    func downloadsChanged() {
        invalidate()
        downloadsPanel?.refresh()
    }

    /// The list: the bar's button, or `Ctrl+J` — the key every Windows browser gives it.
    func showDownloads() {
        downloads.markSeen()
        let panel = RailListPanel(
            title: "Downloads",
            searchable: false,
            emptyText: "Files you download will show up here.",
            hint: "Enter opens a finished file · Delete stops a download or takes it off the list · Esc closes",
            rows: { [weak self] _ in
                self?.downloads.items.map {
                    RailListPanel.Row(id: $0.id.uuidString, title: $0.filename, detail: RailDownloads.detail(of: $0))
                } ?? []
            },
            activate: { [weak self] row in self?.downloads.open(row.id) },
            remove: { [weak self] row in self?.downloads.stopOrForget(row.id) }
        )
        present(panel)
        downloadsPanel = panel
    }

    /// A column opened only to carry a link that turned out to be a file — a `target=_blank` or a
    /// middle click on a download — closes itself and gives the focus back, the Mac's
    /// `closeIfOnlyCarriedALink`: it never showed anything, and would stand there blank beside the
    /// download it became. A column that has finished loading a page is no longer a carrier.
    func closeIfOnlyCarried(_ tabID: Foundation.UUID) {
        guard let source = carriers.removeValue(forKey: tabID) else { return }
        let wasFocused = model.focusedTabID == tabID
        model.closeColumn(tabID)
        if wasFocused, model.allTabIDs.contains(source) { model.focus(source) }
        Log.info(.pages, "a window that only carried a download was closed")
        invalidate()
    }

    /// The arrow, with what the Mac's button says around it: a bar under it while something is coming
    /// in, and a dot in the profile's colour when something finished that nobody has looked at.
    func drawDownloadsButton(_ hdc: HDC, in rect: RECT) {
        drawGlyph(hdc, ChromeFonts.Glyph.download, in: rect, enabled: true)
        let accent = Self.color(hex: model.activeProfile.colorHex)
        if downloads.isRunning {
            let track = RECT(left: rect.left + px(7), top: rect.bottom - px(5),
                             right: rect.right - px(7), bottom: rect.bottom - px(3))
            fill(hdc, track, with: Self.chipColor)
            if let progress = downloads.progress {
                var done = track
                done.right = track.left + Int32(Double(track.right - track.left) * progress)
                fill(hdc, done, with: accent)
            }
        } else if downloads.hasUnseen {
            let dot = px(6)
            let marker = RECT(left: rect.right - px(7) - dot, top: rect.top + px(5),
                              right: rect.right - px(7), bottom: rect.top + px(5) + dot)
            roundedRect(hdc, marker, radius: dot / 2, fill: accent, border: accent, borderWidth: 1)
        }
    }
}
