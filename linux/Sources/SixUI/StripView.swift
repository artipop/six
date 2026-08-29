import Foundation
import SixGtk

@testable import SixCore

/// The strip: `NiriLayout` says where columns go, this puts widgets there. That is the entire
/// relationship, and it is why the layout model crossed platforms without being touched.
///
/// Deliberately thin, and expected to be thrown away. The imperative widget code here is the part a
/// declarative layer would replace, so nothing clever is invested in it — the value is in `SixCore`
/// above and `SixGtk` below, both of which survive that change.
@MainActor
public final class StripView {
    public let canvas = Fixed()

    private let layout: NiriLayout
    private let session: NetworkSession
    private var columns: [UUID: Column] = [:]

    /// Told when a column's page reports something the chrome should show — a title, an address, the
    /// end of a load. The window listens; the strip does not know what a window is.
    public var onPageChanged: (@MainActor (UUID) -> Void)?
    public var onDidFinishLoad: (@MainActor (UUID, URL, String) -> Void)?
    /// A title almost always lands *after* the load has finished, so history writes the visit first
    /// and names it second — which is what `HistoryStore.updateTitle` is for.
    public var onDidChangeTitle: (@MainActor (URL, String) -> Void)?

    public init(layout: NiriLayout, session: NetworkSession) {
        self.layout = layout
        self.session = session
    }

    public func page(for tabID: UUID) -> WebView? { columns[tabID]?.page }

    public func focusedPage() -> WebView? { layout.focusedTabID.flatMap { columns[$0]?.page } }

    /// Lay the strip out from the model. Called after anything that could move a column: a new tab,
    /// a focus change, a resize.
    public func sync() {
        guard let workspace = layout.focusedWorkspace else { return }
        let frames = layout.columnFrames(workspace)
        let scroll = layout.resolvedOffset(workspace) - layout.horizontalPreview

        var live: Set<UUID> = []
        for (index, column) in workspace.columns.enumerated() where frames.indices.contains(index) {
            live.insert(column.tabID)
            let frame = frames[index]
            let widget = columns[column.tabID] ?? add(column.tabID)
            widget.setSizeRequest(width: Int(frame.width), height: Int(frame.height))
            canvas.move(widget, to: CGPoint(x: frame.minX - scroll, y: frame.minY))
            widget.isFocused = column.tabID == layout.focusedTabID
        }

        // A column the model no longer has takes its page with it.
        for (tabID, widget) in columns where !live.contains(tabID) {
            canvas.remove(widget)
            columns[tabID] = nil
        }
    }

    @discardableResult
    private func add(_ tabID: UUID) -> Column {
        let column = Column(tabID: tabID, session: session)
        column.page.onTitleChanged { [weak self] in
            column.title = column.page.title
            self?.onPageChanged?(tabID)
            if let url = column.page.url, !column.page.title.isEmpty {
                self?.onDidChangeTitle?(url, column.page.title)
            }
        }
        column.page.onURLChanged { [weak self] in self?.onPageChanged?(tabID) }
        column.page.onLoadChanged { [weak self] event in
            guard event == .finished, let url = column.page.url else { return }
            self?.onPageChanged?(tabID)
            self?.onDidFinishLoad?(tabID, url, column.page.title)
        }
        canvas.put(column, at: .zero)
        columns[tabID] = column
        return column
    }
}

/// One window in the strip: a title bar and the page under it. `WindowChrome` on the Mac.
@MainActor
final class Column: Box {
    let tabID: UUID
    let page: WebView
    private let titleLabel = Label()

    var title: String {
        get { titleLabel.text }
        set { titleLabel.text = newValue.isEmpty ? "Untitled" : newValue }
    }

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            if isFocused { addCSSClass("focused") } else { removeCSSClass("focused") }
        }
    }

    init(tabID: UUID, session: NetworkSession) {
        self.tabID = tabID
        self.page = WebView(session: session)
        super.init(.vertical, spacing: 0)
        titleLabel.truncate(to: 40)
        titleLabel.text = "Untitled"
        addCSSClass("column")
        append(titleLabel)
        append(page)
        // The page takes the rest of the column, the title bar only what it needs.
        page.expand(vertically: true)
    }
}
