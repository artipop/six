import Foundation
import SixGtk

@testable import SixCore

/// One window, always — the same constraint the Mac has and for a related reason: a page belongs to
/// exactly one place in exactly one widget tree. What look like tabs are columns in the strip inside
/// it, which is the whole niri idea.
@MainActor
public final class BrowserWindow {
    private let window: Window
    private let root = Box(.vertical, spacing: 0)
    private let topBar = Box(.horizontal, spacing: 6)
    private let address = Entry()
    private let strip: StripView

    private let layout: NiriLayout
    private let history: HistoryStore?
    private let profileID: UUID

    public init(application: Application, layout: NiriLayout, session: NetworkSession, history: HistoryStore?) {
        self.layout = layout
        self.history = history
        self.profileID = layout.activeProfileID
        self.strip = StripView(layout: layout, session: session)

        window = Window(application: application, title: "six")
        window.setDefaultSize(width: 1400, height: 900)

        buildTopBar()
        root.append(topBar)
        root.append(strip.canvas)
        strip.canvas.expand(vertically: true)
        window.setChild(root)

        // The chrome follows the focused page rather than being told twice.
        strip.onPageChanged = { [weak self] _ in self?.refreshAddress() }
        strip.onDidFinishLoad = { [weak self] _, url, title in self?.record(url, title) }
        strip.onDidChangeTitle = { [weak self] url, title in
            guard let self else { return }
            history?.updateTitle(title, for: url, in: profileID)
        }

        // The strip lays itself out in whatever room the window gives it, and re-lays itself when
        // that changes. `NiriLayout` works in "strip space" and does not care which axis that is.
        window.onNotify("default-width") { [weak self] in self?.viewportChanged() }
        window.onNotify("default-height") { [weak self] in self?.viewportChanged() }
    }

    public func present() {
        window.present()
        viewportChanged()
    }

    /// Open a column on this address, focus it, and lay the strip out again.
    public func open(_ url: URL) {
        let tabID = UUID()
        layout.insertColumn(tabID: tabID)
        strip.sync()
        strip.page(for: tabID)?.load(url)
        refreshAddress()
    }

    // MARK: Chrome

    private func buildTopBar() {
        let back = Button(label: "‹")
        back.onClick { [weak self] in self?.strip.focusedPage()?.goBack() }
        let forward = Button(label: "›")
        forward.onClick { [weak self] in self?.strip.focusedPage()?.goForward() }
        let reload = Button(label: "⟳")
        reload.onClick { [weak self] in self?.strip.focusedPage()?.reload() }
        let newColumn = Button(label: "+")
        newColumn.onClick { [weak self] in self?.open(Self.startPage) }

        address.expand(horizontally: true)
        address.onSubmit { [weak self] in self?.submitAddress() }

        topBar.addCSSClass("toolbar")
        for control in [back, forward, reload, address, newColumn] as [Widget] { topBar.append(control) }
    }

    /// Anything that is not an address is a search, which is the one decision an address bar makes.
    private func submitAddress() {
        let typed = address.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, let url = Self.destination(for: typed) else { return }
        if let page = strip.focusedPage() { page.load(url) } else { open(url) }
    }

    /// A single word with a dot and no spaces is a host; everything else is a query. Deliberately
    /// crude — the Mac's version knows about schemes, IDN and local names, and this is a skeleton.
    public static func destination(for typed: String) -> URL? {
        if let url = URL(string: typed), url.scheme != nil, url.host() != nil { return url }
        let looksLikeHost = !typed.contains(" ") && typed.contains(".")
        if looksLikeHost, let url = URL(string: "https://" + typed) { return url }
        return SearchEngine.current.searchURL(for: typed)
    }

    public static var startPage: URL { URL(string: "https://duckduckgo.com/")! }

    private func refreshAddress() {
        guard let page = strip.focusedPage() else { return }
        address.text = page.url?.absoluteString ?? ""
    }

    private func viewportChanged() {
        let size = window.contentSize
        guard size.width > 0, size.height > 0 else { return }
        layout.updateViewport(CGSize(width: size.width, height: size.height - 44))
        strip.sync()
    }

    private func record(_ url: URL, _ title: String) {
        history?.record(url, title: title, in: profileID)
    }
}
