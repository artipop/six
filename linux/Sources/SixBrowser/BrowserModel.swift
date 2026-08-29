import Foundation
import SixWebKitCore

@testable internal import SixCore

/// What the views read and call into.
///
/// In a target of its own, and that is not tidiness. Adwaita depends unconditionally on its own
/// SQLite (`meta-sqlite` → `CSQLite`) and `SixCore` reaches GRDB's, and Clang refuses to have both
/// in one compilation unit — *"'sqlite3_api_routines' has different definitions in different
/// modules"*. So nothing imports Adwaita and `SixCore` together: the model sits here, the views sit
/// in `SixUI`, and the seam the plan asked for is enforced by the compiler rather than by discipline.
public final class BrowserModel {
    /// A column, flattened for the view: what the strip needs to draw one, and nothing else.
    public struct Column: Identifiable {
        public let id: UUID
        public var frame: CGRect
        public var url: URL?
        public var title: String
        public var isFocused: Bool
    }

    /// One model for the app, reached statically rather than stored in a view.
    ///
    /// Not a style choice: Meta collects a view's `@State` by reflecting over its stored properties,
    /// and a class sitting in one crashes the runtime inside `swift_getTypeByMangledName` — the
    /// window comes up, draws once, and dies. So the views hold value types only, and the model is
    /// here.
    public static let shared = BrowserModel()

    let layout = NiriLayout()
    public let session: NetworkSession

    private var history: HistoryStore?
    private var profileID = UUID()
    private var titles: [UUID: String] = [:]
    private var urls: [UUID: URL] = [:]

    private init() {
        let profiles = AppSupport.folder("Profiles/Default")
        try? FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        session = NetworkSession(directory: profiles)

        // The same file, in the same format, the Mac build writes; only the folder differs, and only
        // inside `AppSupport.root`. A browser without history is still a browser, so a database that
        // will not open is reported and stepped over rather than fatal.
        do {
            history = HistoryStore(database: try AppDatabase.open())
        } catch {
            FileHandle.standardError.write(Data("[six] database unavailable: \(error)\n".utf8))
        }
        profileID = layout.activeProfileID
        // Populated here rather than from the app's `init` or the view's `onAppear`. `init` runs
        // before `g_application_run`, and this creates a `NetworkSession`, which is a GObject —
        // building one before GTK is up is the kind of mistake that fires later, in someone else's
        // code. `shared` is lazy, so the first touch happens inside the first render, by which time
        // the toolkit is running.
        fill()
    }

    // MARK: What the strip draws

    public var columns: [Column] {
        guard let workspace = layout.focusedWorkspace else {
            trace("columns: no workspace")
            return []
        }
        trace("columns: \(workspace.columns.count)")
        let frames = layout.columnFrames(workspace)
        let scroll = layout.resolvedOffset(workspace) - layout.horizontalPreview
        return workspace.columns.enumerated().compactMap { index, column in
            guard frames.indices.contains(index) else { return nil }
            let frame = frames[index].offsetBy(dx: -scroll, dy: 0)
            return Column(
                id: column.tabID,
                frame: frame,
                url: urls[column.tabID],
                title: titles[column.tabID] ?? "",
                isFocused: column.tabID == layout.focusedTabID
            )
        }
    }

    var focusedID: UUID? { layout.focusedTabID }
    /// Where the strip should be scrolled to: the offset `NiriLayout` computes for the focused
    /// column, which is what centres it when `centersFocus` is on. The same number the Mac uses.
    public var scrollOffset: Double {
        guard let workspace = layout.focusedWorkspace else { return 0 }
        return Double(layout.resolvedOffset(workspace))
    }

    /// The layout's own gap, so the front never invents a spacing of its own.
    public var gap: Double { Double(layout.gap) }
    /// What a column should be, in points, from the same presets the Mac cycles with ⌥R.
    public var columnSize: CGSize {
        CGSize(width: layout.width(of: .init(tabID: UUID(), widthIndex: layout.preferredWidthIndex)),
               height: layout.columnHeight)
    }
    public var canGoBack: Bool { focusedID.map(PageRegistry.canGoBack) ?? false }
    public var canGoForward: Bool { focusedID.map(PageRegistry.canGoForward) ?? false }

    // MARK: Driving it

    private func fill() {
        trace("fill")
        layout.updateViewport(CGSize(width: 1400, height: 820))
        if let width = ProcessInfo.processInfo.environment["SIX_WIDTH"].flatMap(Int.init) {
            layout.preferredWidthIndex = width
        }
        let requested = (ProcessInfo.processInfo.environment["SIX_URL"] ?? "")
            .split(separator: " ")
            .compactMap { URL(string: String($0)) }
        for url in requested.isEmpty ? [Self.startPage] : requested { open(url) }
    }

    public func openColumn() { open(Self.startPage) }

    public func open(_ url: URL) {
        trace("open \(url)")
        let tabID = UUID()
        urls[tabID] = url
        layout.insertColumn(tabID: tabID)
    }

    /// Anything that is not an address is a search, which is the one decision an address bar makes.
    public func go(to typed: String) {
        trace("go \(typed)")
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.destination(for: trimmed) else { return }
        if let focused = focusedID { urls[focused] = url } else { open(url) }
    }

    public func goBack() { focusedID.map(PageRegistry.goBack) }
    public func goForward() { focusedID.map(PageRegistry.goForward) }
    public func reload() { focusedID.map(PageRegistry.reload) }

    /// The address bar shows where the focused page actually is, which after a redirect or a
    /// followed link is not the address it was asked for.
    public var focusedURL: URL? {
        guard let focused = focusedID else { return nil }
        return PageRegistry.url(of: focused) ?? urls[focused]
    }

    // MARK: What the pages report

    /// Returns whether anything changed, so the front can redraw for a new title and stay still for
    /// the dozen identical ones a loading page sends. Redrawing on every one of them is what sent
    /// the view tree into a 248-render runaway.
    @discardableResult
    public func setTitle(_ title: String, for tabID: UUID) -> Bool {
        guard titles[tabID] != title else { return false }
        titles[tabID] = title
        if let url = urls[tabID], !title.isEmpty {
            history?.updateTitle(title, for: url, in: profileID)
        }
        return true
    }

    @discardableResult
    public func setURL(_ url: URL, for tabID: UUID) -> Bool {
        guard urls[tabID] != url else { return false }
        urls[tabID] = url
        return true
    }

    public func didFinishLoad(_ url: URL, title: String, for tabID: UUID) {
        urls[tabID] = url
        history?.record(url, title: title, in: profileID)
    }

    /// `SIX_UI_DEBUG=1`, the same switch `NiriLayout` already uses: what the model was asked to do
    /// and what it thought it was doing. A front that draws nothing is either not being told or not
    /// listening, and this says which.
    func trace(_ message: @autoclosure () -> String) {
        guard NiriLayout.tracesUI else { return }
        FileHandle.standardError.write(Data("[six] model: \(message())\n".utf8))
    }

    // MARK: Addresses

    public static var startPage: URL { URL(string: "https://duckduckgo.com/")! }

    /// A word with a dot and no spaces is a host; everything else is a query. Deliberately crude —
    /// the Mac's knows about schemes, IDN and local names, and this is a skeleton.
    public static func destination(for typed: String) -> URL? {
        if let url = URL(string: typed), url.scheme != nil, url.host() != nil { return url }
        if !typed.contains(" "), typed.contains("."), let url = URL(string: "https://" + typed) { return url }
        return SearchEngine.current.searchURL(for: typed)
    }
}
