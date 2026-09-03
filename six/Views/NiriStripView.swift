#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// The niri canvas: every workspace is a full-screen horizontal strip of columns; the workspaces are
/// stacked vertically and only one of them is on screen at a time.
struct NiriStripView: View {
    /// The strip's own coordinate space: the canvas *before* the overview scales it, which is the
    /// space every column frame is already in. A pointer position that arrives in these units can be
    /// compared with `columnFrames()` directly, at any zoom.
    static let canvasSpace = "six.strip.canvas"

    @Environment(BrowserState.self) private var browser
    @State private var monitor = NiriScrollMonitor()
    /// Where the strip sits in the window, for the scroll monitor: what is above it is the top bar,
    /// and scrolling there is nobody's layout gesture.
    @State private var stripFrame: CGRect = .infinite

    var body: some View {
        let layout = browser.layout
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                // Only the workspace on screen and the two it can slide in from are built. The rest of
                // the stack is a screen or more away and cannot be seen even mid-gesture; with a
                // workspace holding a dozen columns, not building them is the difference between a
                // strip that scrolls and one that thinks about it first. The overview is the exception:
                // there they are all on screen at once.
                ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    if layout.isOverview || abs(index - layout.focusedWorkspaceIndex) <= 1 {
                        WorkspaceView(workspace: workspace, size: proxy.size)
                            .offset(y: offset(of: index, height: proxy.size.height, layout: layout))
                    }
                }
                // Above every row, and last so it is: the window in the hand, and the layer that put
                // it there. Both live on the canvas rather than on a card, which is what lets a window
                // be carried out of the row that was drawing it.
                if layout.isOverview {
                    CarriedColumn()
                    OverviewPointerLayer(size: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.canvasSpace))
            .scaleEffect(layout.overviewScale, anchor: .center)
            .overlay { if layout.isOverview { WorkspacePlates(size: proxy.size) } }
            .onChange(of: proxy.size, initial: true) { layout.updateViewport(proxy.size) }
            .onChange(of: proxy.frame(in: .global), initial: true) { _, frame in stripFrame = frame }
        }
        .background(StripBackground())
        .clipped()
        .overlay { StripEdgeButtons() }
        .overlay { StripWalls() }
        .overlay(alignment: .bottom) { OverviewHint() }
        .contextMenu { StripMenu() }
        .onAppear(perform: startMonitor)
        .onDisappear { monitor.stop() }
    }

    private func offset(of index: Int, height: CGFloat, layout: NiriLayout) -> CGFloat {
        let step = height + layout.workspaceSpacing
        return CGFloat(index - layout.focusedWorkspaceIndex) * step + layout.verticalPreview
    }

    private func startMonitor() {
        let layout = browser.layout
        monitor.stripFrame = { stripFrame }
        monitor.modifierOptional = { layout.isOverview }
        monitor.onStepWorkspace = { browser.focusWorkspace($0) }
        monitor.onStepColumn = { browser.focusColumn($0) }
        // The rubber band belongs to the layout, not to the view: how far it gives, and what it means
        // when there is nothing behind the edge being pushed (`NiriLayout.previewColumn`), is the same
        // sentence on both front ends.
        monitor.onPreview = { layout.previewWorkspace($0) }
        monitor.snapsHorizontally = { layout.centersFocus && !layout.isOverview }
        monitor.onPreviewColumn = { layout.previewColumn($0) }
        monitor.onPan = { browser.panStrip(by: $0) }
        monitor.onPanEnded = { browser.endStripPan() }
        monitor.start()
    }
}

// MARK: - One workspace

private struct WorkspaceView: View {
    let workspace: NiriWorkspace
    let size: CGSize

    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        // Which row this is, asked of the strip by identity rather than taken from the number the row
        // was built with. A row that has just been pruned — the last window of a workspace closed, and
        // `normalize` dropped that workspace — stays in the view tree for the length of its removal
        // transition, and by then its `index` names the row that has moved up into its place. Read the
        // strip by that number and a dying row draws the *other* row's windows: a window is a `WebView`
        // over a `WebPage`, of which WebKit allows exactly one, so the second view traps in
        // `makeViewProvider` and takes the whole browser down with it. It is the trap
        // `NiriLayout.unanimated` was written for, arriving from the other side — there a window
        // changed rows, here a row went out from under a window. A row the strip no longer has draws
        // nothing at all.
        if let row = layout.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            canvas(layout: layout, row: row)
        } else {
            Color.clear.frame(width: layout.visibleWidth, height: size.height)
        }
    }

    @ViewBuilder
    private func canvas(layout: NiriLayout, row: Int) -> some View {
        // What this row draws, which is its own columns unless a window is being carried across the
        // overview: then the carried one is out of the row it came from and holding a place open in the
        // row it would land in (`NiriLayout.arrangement`). The card itself is drawn above the canvas,
        // following the pointer, so here it is only ever the gap.
        let columns = layout.arrangement(workspaceAt: row)
        let frames = layout.columnFrames(columns)
        let isCurrent = row == layout.focusedWorkspaceIndex
        let scroll = layout.resolvedOffset(workspace) - (isCurrent ? layout.horizontalPreview + layout.edgeLean : 0)
        // The overview scales the canvas down, so a workspace layer covers proportionally more than the
        // window: it has to be that wide, and centred on the same point, or the strip is cut off at the
        // window edges instead of running the full width of the screen.
        let layerWidth = layout.visibleWidth
        let carried = layout.columnDrag?.tabID
        let focusedTabID = workspace.focusedColumn?.tabID

        ZStack(alignment: .topLeading) {
            Color.clear
            if columns.isEmpty {
                EmptyWorkspaceHint()
                    .frame(width: layerWidth, height: size.height)
            }
            // The window the `+` under the pointer would open, where it would open: the strip has
            // leaned aside to make room for it, and this is what stands in the room.
            if isCurrent, let outline = layout.newColumnFrame {
                NewColumnOutline()
                    .frame(width: outline.width, height: outline.height)
                    .offset(x: outline.minX - scroll, y: outline.minY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            ForEach(Array(columns.enumerated()), id: \.element.id) { position, column in
                if let tab = browser.tab(column.tabID), frames.indices.contains(position), column.tabID != carried {
                    let frame = frames[position]
                    let isFocused = isCurrent && column.tabID == focusedTabID
                    ColumnView(
                        tab: tab,
                        isFocused: isFocused,
                        isCurrentWorkspace: isCurrent,
                        isLive: isLive(workspaceDistance: abs(row - layout.focusedWorkspaceIndex),
                                       x: frame.minX - scroll, width: frame.width, layout: layout)
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX - scroll, y: frame.minY)
                    .zIndex(isFocused ? 1 : 0)
                    // A new window slides in from beside its neighbour and settles; a closed one fades
                    // out where it stood. The slide is a fraction of the column, not a point count.
                    .transition(.asymmetric(
                        insertion: .offset(x: frame.width * 0.35).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: .leading)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
                }
            }
        }
        // The row shuffles to open the gap, and only then: the carried card is a layer of its own and
        // has to keep up with the pointer, so animating every change here would make it swim.
        .animation(.smooth(duration: 0.22), value: layout.columnDrag.map { [$0.toWorkspace, $0.toIndex] })
        .frame(width: layerWidth, height: size.height, alignment: .topLeading)
        .clipped()
        .offset(x: -(layerWidth - size.width) / 2)
        .opacity(layout.isOverview && !isCurrent ? 0.7 : 1)
        // A workspace that is not on screen answers nothing. It is laid out a screen above or below,
        // and a screen above is where the top bar is: its cards, their shadows and the hosted views
        // underneath them all reach into that strip of window, and how far they reach depends on the
        // window's height (the gaps are fractions of it). That is how a button up there stops working
        // for no reason you can see. The same rule as the web views (`isLive`), for everything else.
        .allowsHitTesting(isCurrent || layout.isOverview)
    }

    /// Whether this column may mount a web view. Nearby columns do, the rest are cheap cards, so a big
    /// strip stays cheap.
    ///
    /// A workspace that is not on screen gets none at all, and that is not only about cost: a web view
    /// is a real AppKit view, SwiftUI's clipping does not reach it, and one sitting a screen above
    /// still answers the mouse over the top bar. Off screen it must not exist. The neighbours come
    /// back while a gesture is peeking at them.
    ///
    /// The overview is every window at once, and there they are all cards. A live page in the overview
    /// is a page being laid out and composited at a fraction of its size for a picture of itself, and
    /// a dozen of them are a dozen of that every time the view moves — which is exactly what the
    /// overview is for. The cards are the pictures taken on the way in.
    ///
    /// This only decides what is *shown*. Whether the window has a page to show at all is the live-page
    /// budget's business (`LivePageCache`), which pins the focused workspace's columns and lets the
    /// cold end of the strip go — so a neighbour workspace mid-gesture shows the pages it still has
    /// and cards for the rest, and never builds a web view in the middle of a scroll.
    private func isLive(workspaceDistance: Int, x: CGFloat, width: CGFloat, layout: NiriLayout) -> Bool {
        guard !layout.isOverview else { return false }
        let visibleWorkspace = workspaceDistance == 0 || layout.verticalPreview != 0
        guard visibleWorkspace, workspaceDistance <= 1 else { return false }
        let margin = layout.visibleWidth
        return x + width > -margin && x < layout.visibleWidth + margin
    }
}

private struct EmptyWorkspaceHint: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Button { browser.newTab() } label: {
                Label("New Window", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("or ⌘T")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Carrying a window across the overview

/// The window in the hand: the card the pointer picked up, drawn above every row at the place it has
/// been carried to and lifted off the canvas a little, so it reads as being in the air rather than in
/// the strip. The gap it left, and the one it would fill, are the rows' own business
/// (`NiriLayout.arrangement`).
private struct CarriedColumn: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        if let drag = layout.columnDrag, let frame = layout.carriedCardFrame, let tab = browser.tab(drag.tabID) {
            ColumnView(tab: tab, isFocused: true, isCurrentWorkspace: true, isLive: false)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(1.03)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }
}

/// Everything the pointer does in the overview, in one place.
///
/// Up there every window is a picture at a place the layout already knows, so which one is under the
/// pointer is arithmetic rather than a view's own opinion — and a gesture that belongs to the canvas
/// instead of to a card survives the card being carried out of the row that was drawing it, which is
/// exactly what this gesture does to it. A card's own click handling stays where it is for the strip;
/// in the overview this layer is on top and answers first.
///
/// It answers *only where the windows are*: the shape it presents to the mouse is the cards
/// themselves, so a click that lands between them still reaches whatever is underneath — the New
/// Window button on an empty workspace, for one.
private struct OverviewPointerLayer: View {
    let size: CGSize

    @Environment(BrowserState.self) private var browser
    /// The window being carried, if the press has travelled far enough to be a carry rather than a
    /// click. Held here as well as in the layout because it is what tells the two apart on the way up.
    @State private var carrying: UUID?

    var body: some View {
        let layout = browser.layout
        let cards = cards(layout)
        let bounds = bounds(layout)
        Color.clear
            .frame(width: bounds.width, height: bounds.height)
            .contentShape(CardsShape(rects: cards.map { $0.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }))
            .offset(x: bounds.minX, y: bounds.minY)
            .gesture(gesture(cards: cards))
    }

    /// Every window on the canvas, in canvas points.
    private func cards(_ layout: NiriLayout) -> [(id: UUID, rect: CGRect)] {
        var cards: [(id: UUID, rect: CGRect)] = []
        for index in layout.workspaces.indices {
            let columns = layout.arrangement(workspaceAt: index)
            let frames = layout.columnFrames(columns)
            let top = layout.rowY(index)
            for (position, column) in columns.enumerated() where frames.indices.contains(position) {
                let frame = frames[position]
                cards.append((column.tabID, CGRect(x: layout.canvasX(content: frame.minX, workspace: index),
                                                   y: top + frame.minY,
                                                   width: frame.width, height: frame.height)))
            }
        }
        return cards
    }

    /// The whole stack of rows, which reaches well above and below the window itself — the overview is
    /// zoomed out, and the rows it shows are laid out a screen apart at full size.
    private func bounds(_ layout: NiriLayout) -> CGRect {
        let width = layout.visibleWidth
        let step = size.height + layout.workspaceSpacing
        return CGRect(x: -(width - size.width) / 2,
                      y: layout.rowY(0),
                      width: width,
                      height: step * CGFloat(max(1, layout.workspaces.count)))
    }

    private func card(_ cards: [(id: UUID, rect: CGRect)], at point: CGPoint) -> UUID? {
        cards.first { $0.rect.contains(point) }?.id
    }

    private func gesture(cards: [(id: UUID, rect: CGRect)]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(NiriStripView.canvasSpace))
            .onChanged { value in
                if carrying == nil {
                    // A press is a click until it has gone somewhere. The threshold is in canvas
                    // points, which the overview then shrinks — so the hand has to move further than
                    // this on screen, and a click never turns into a carry by accident.
                    guard hypot(value.translation.width, value.translation.height) > 6,
                          let id = card(cards, at: value.startLocation) else { return }
                    carrying = id
                    browser.beginColumnDrag(tabID: id)
                }
                browser.updateColumnDrag(translation: value.translation)
            }
            .onEnded { value in
                if carrying != nil {
                    carrying = nil
                    browser.endColumnDrag()
                    return
                }
                guard let id = card(cards, at: value.startLocation) else { return }
                browser.selectTab(id)
                browser.exitOverview()
            }
    }
}

/// The cards, as one shape: what the pointer layer offers the mouse, so the space between the windows
/// is not covered by it.
private struct CardsShape: Shape {
    let rects: [CGRect]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for rect in rects { path.addRoundedRect(in: rect, cornerSize: CGSize(width: 12, height: 12)) }
        return path
    }
}

/// The window that isn't there yet: the place the `+` under the pointer would fill, drawn as an
/// outline so it reads as a promise rather than as a window. Most of it is off the edge of the
/// screen — the strip only leans far enough for a glance — and the part that is on it is the point.
private struct NewColumnOutline: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let accent = browser.selectedProfile.color
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(accent.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accent.opacity(0.5), lineWidth: 2)
            }
    }
}

// MARK: - One column (a "window")

private struct ColumnView: View {
    let tab: BrowserTab
    let isFocused: Bool
    /// Columns of another workspace are off screen entirely (except in the overview): their AppKit
    /// views are still there — SwiftUI's clipping doesn't reach them — but they must not be targets.
    let isCurrentWorkspace: Bool
    let isLive: Bool

    @Environment(BrowserState.self) private var browser
    @Environment(SitePermissions.self) private var permissions

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    /// A window that isn't the focused one is a target, not a page: the first click flies to it. Same in
    /// the overview, where every page is just a picture. `WKWebView` is a real AppKit view and takes the
    /// click before any SwiftUI overlay can, so the catcher has to be an AppKit view too.
    private var capturesClicks: Bool {
        browser.layout.isOverview || (isCurrentWorkspace && !isFocused)
    }

    /// A filled window is the page and nothing else: no title bar, no rounded corners, no border to
    /// separate a column from a neighbour that is a whole screen away.
    private var filled: Bool { browser.layout.fillsViewport }

    private func activate() {
        browser.selectTab(tab.id)
        browser.exitOverview()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the page even at full width: the page is suspended waiting for this answer, and a
            // window with nowhere to say yes is a window that seems to have broken the site.
            if let question = permissions.question(for: tab.id) {
                PermissionBar(tab: tab, question: question)
                Divider()
            }
            // An MCP app asking to run one of its server's tools — the same bar, one layer of
            // trust further out (docs/mcp-apps.md).
            if let app = tab.app, let request = app.pendingToolRequest {
                MCPAppBar(session: app, request: request)
                Divider()
            }
            // Only while it has something to say. A translated page keeps its state, and a bar
            // that stays up for as long as the page does is chrome charged against every page in
            // the strip — the address field carries "translated" from here on.
            if let translation = browser.translation[tab.id], translation.saysSomething {
                TranslateBar(tab: tab, state: translation)
                Divider()
            }
            if tab.showsStartPage {
                // Pure SwiftUI, so the plain overlay is enough to catch the first click here.
                StartPage(tab: tab, isActive: isFocused && !browser.layout.isOverview)
                    .allowsHitTesting(!capturesClicks)
                    .overlay {
                        if capturesClicks {
                            Color.white.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture(perform: activate)
                        }
                    }
            } else if let saved = tab.pendingApp {
                MCPAppRestoreView(tab: tab, saved: saved)
                    .allowsHitTesting(!capturesClicks)
                    .overlay {
                        if capturesClicks {
                            Color.white.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture(perform: activate)
                        }
                    }
            } else if let page = tab.builtIn {
                // One of six's own, and pure SwiftUI like the start page: no web content process is
                // spent on a list of servers.
                BuiltInPageView(page: page, tab: tab)
                    .allowsHitTesting(!capturesClicks)
                    .overlay {
                        if capturesClicks {
                            Color.white.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture(perform: activate)
                        }
                    }
            } else if let document = tab.document, isLive {
                // The editor is SwiftUI, the preview is a web view: the AppKit catcher covers both.
                DocumentView(tab: tab, document: document, isActive: isFocused && !browser.layout.isOverview)
                    .allowsHitTesting(!capturesClicks)
                    .overlay { if capturesClicks { ClickCatcher(action: activate) } }
            } else if isLive, let page = tab.livePage {
                // Identified by the page, not the window: a window whose page was discarded and built
                // again is showing a different `WebPage`, and the view has to be built again with it.
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
                    // A video asking for the whole screen gets it. WebKit's default here is
                    // `.automatic`, which on macOS means off — the same default `WKPreferences`
                    // has always had, and the reason the fullscreen button on YouTube did nothing
                    // at all. The window WebKit opens for it is already known to the key router.
                    .webViewElementFullscreenBehavior(.enabled)
                    .pageContextMenu(for: tab, in: browser)
                    .id(tab.generation)
                    .onAppear(perform: tab.resumeIfNeeded)
                    .overlay { if capturesClicks { ClickCatcher(action: activate) } }
            } else {
                ColumnPlaceholder(tab: tab, accent: accent, showsPicture: browser.layout.isOverview)
                    .contentShape(Rectangle())
                    .onTapGesture { if capturesClicks { activate() } }
            }
        }
        .background(.background)
        // The window's own progress, on the window: this is the one thing a *neighbour* still has
        // to be able to say. The focused window's own line is under the address field that is
        // already describing it, an inch above this one — two hairlines for one page is one of them
        // saying nothing.
        .overlay(alignment: .top) {
            if !tab.isDocument, tab.isLoading, !isFocused {
                LoadingLine(progress: tab.estimatedProgress, accent: accent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: filled ? 0 : 12, style: .continuous))
        .overlay {
            if !filled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? accent : Color.primary.opacity(0.12),
                                  lineWidth: isFocused ? 2.5 : 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !filled, isCurrentWorkspace, !browser.layout.isOverview {
                // Sitting on the corner rather than inside it: most of the button is over the gap
                // between the windows, so the page underneath keeps the clicks it should have.
                ColumnCloseBadge(tab: tab).offset(x: 11, y: -11)
            }
        }
        .shadow(color: .black.opacity(filled ? 0 : (isFocused ? 0.28 : 0.16)),
                radius: filled ? 0 : (isFocused ? 18 : 10), y: filled ? 0 : 5)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// The window's close button, moved off the title bar and onto the window itself: a × on the top
/// right corner of the card, out of sight until the pointer is on it. Hosted in AppKit, because the
/// corner it sits on is a page's corner and SwiftUI drawn over a `WKWebView` never sees the mouse.
private struct ColumnCloseBadge: View {
    let tab: BrowserTab

    @Environment(BrowserState.self) private var browser
    @State private var hovering = false

    var body: some View {
        HostedOverlay { content.environment(browser) }
            .frame(width: 26, height: 26)
    }

    private var content: some View {
        Button { browser.closeTab(tab.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
        .opacity(hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Close Window (⌘W)")
    }
}

/// What a window shows in place of a page it doesn't have live. Every window off the focused
/// workspace is one of these, and so is every window whose page was discarded for the budget (see
/// `LivePageCache`).
///
/// In the strip it is a card with the window's title: a picture of the page would only ever be seen
/// out of the corner of the eye, at the edge of the screen, for the moment before the real page
/// arrives — and a stale, soft screenshot flashing where a page is about to be is worse than a card
/// that never pretended to be one. The pictures are for the overview, where every window is a
/// picture and telling them apart is the whole point.
private struct ColumnPlaceholder: View {
    let tab: BrowserTab
    let accent: Color
    let showsPicture: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if showsPicture, let image = tab.thumbnail {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .allowsHitTesting(false)
                    .overlay(alignment: .bottom) {
                        Text(tab.title)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial)
                    }
            } else {
                card
            }
        }
    }

    private var card: some View {
        VStack(spacing: 8) {
            Image(systemName: tab.isDocument ? "doc.text" : "globe")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(accent)
            Text(tab.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let host = tab.currentURL?.host() {
                Text(host).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}


// MARK: - Mouse controls

/// The two step arrows, one on each side of the focused window.
///
/// They stand in the gap the layout already leaves beside that window — the strip between two
/// windows — rather than against the edge of the screen, where the neighbour peeking in is and where
/// they used to cover it. They follow the focused window as the strip scrolls, and when the window
/// fills the viewport there is no gap left to stand in, so they fall back to the edge. Either way they
/// are invisible until the pointer comes looking (`StripEdgeButton`).
private struct StripEdgeButtons: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        if !layout.isOverview {
            GeometryReader { proxy in
                let lane = StripEdgeButton.lane(layout)
                let frame = layout.focusedColumnFrame
                let inset = lane / 2
                // Half a gap out from the window's edge, and never off the screen: a window as wide as
                // the viewport leaves nowhere to stand but the edge itself. Half a lane and not one
                // point more — pushed against the edge the sliver has to *contain* it. With the window
                // maximised the strip's edge is the screen's, and throwing the pointer at the wall is
                // the way you reach a sliver you cannot see; a target starting one point in is a target
                // that wall never hits.
                let left = min(max(inset, (frame?.minX ?? 0) - layout.gap / 2), proxy.size.width - inset)
                let right = max(min(proxy.size.width - inset, (frame?.maxX ?? proxy.size.width) + layout.gap / 2), inset)
                StripEdgeButton(direction: -1)
                    .position(x: left, y: proxy.size.height / 2)
                StripEdgeButton(direction: 1)
                    .position(x: right, y: proxy.size.height / 2)
            }
            .animation(NiriLayout.switchAnimation, value: layout.focusedColumnFrame?.minX)
        }
    }
}

/// A sliver standing in the gap beside the focused window: one click steps one column. At either end
/// of the strip it opens a window instead — and the one at the near end opens it *there*, to the left
/// of the one you are reading, which is the only way the strip offers to grow backwards.
///
/// Either way it draws nothing until the pointer arrives. Resting on it leans the whole strip aside
/// far enough to show what is over there (`NiriLayout.edgeHover`): the next window, or an outline of
/// the one that would open. The button says what it does before it does it, and it says it with the
/// thing itself rather than with a symbol standing in for it — the glyph that fades in with the lean,
/// `‹ ›` or `+`, only names which of the two this is.
///
/// It is as narrow as the gap it stands in — a button wide enough to read comfortably is a button
/// covering the page next to it, and the page is what the window is for. The strip at rest is windows
/// and gaps: a chevron parked in every gap would be chrome charged against every window in it.
private struct StripEdgeButton: View {
    let direction: Int

    @Environment(BrowserState.self) private var browser
    @State private var hovering = false
    /// The `+` arrived under a pointer that was already here — the strip ran out of windows while it
    /// rested — so it does nothing and holds no peek until the pointer comes back of its own accord.
    @State private var disarmed = false

    /// The lane tracks the layout, not the screen: it is the gap the layout already leaves between
    /// two windows, floored so it stays clickable and capped so it never becomes a margin.
    static func lane(_ layout: NiriLayout) -> CGFloat {
        layout.fillsViewport ? 22 : max(13, min(28, layout.gap))
    }

    /// What answers the mouse. Nothing is drawn here until the pointer arrives, and a target you
    /// cannot see has to be one you cannot miss along the edge you are sweeping — so in the gap, where
    /// the whole lane is background and the height costs nothing, it runs the length of the window
    /// beside it. With the window filled the lane is over the page, and a page is not somewhere to put
    /// a strip that swallows the mouse for its full height: there it shrinks to a band around the
    /// middle, deep enough to sweep into and short enough to leave the page its edge.
    private func targetHeight(_ layout: NiriLayout) -> CGFloat {
        layout.fillsViewport ? max(52, min(280, layout.viewport.height * 0.3)) : layout.columnHeight
    }

    var body: some View {
        let layout = browser.layout
        // Hosted in AppKit, like every control drawn over a page: a SwiftUI button never sees the
        // mouse (see `ClickCatcher`), and with the window filled there is nothing but page here.
        HostedOverlay {
            content(layout: layout)
        }
        .frame(width: Self.lane(layout), height: targetHeight(layout))
    }

    /// One button for both jobs, and deliberately one: it is what keeps its identity when the strip
    /// runs out of windows under a resting pointer and the chevron becomes a `+`. Two views would make
    /// that an exit and an entry, and the entry would arm the `+` under a hand that never moved.
    @ViewBuilder
    private func content(layout: NiriLayout) -> some View {
        if let step = step(layout: layout) {
            Button {
                guard !(step.opens && disarmed) else { return }
                step.action()
            } label: {
                ZStack {
                    Color.clear
                    // Nothing is drawn until the pointer comes: the strip at rest is windows and gaps,
                    // and a symbol parked in every gap is chrome charged against every window in it.
                    // Invisible is not gone — a button behind a transparent label still answers the
                    // mouse, which is the whole trick: the sliver is its own hover target and nothing
                    // else has to be laid over the page.
                    //
                    // Both symbols, `‹ ›` and `+`, and neither of them carries the message: the strip
                    // leaning over is what says there is something on that side, and the outline is
                    // what says it does not exist yet. The glyph only names which of the two this is,
                    // the way a dashed edge used to name it before the outline went solid.
                    glyph(step.symbol, layout: layout)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: Self.lane(layout), height: targetHeight(layout))
            .onHover { inside in
                hovering = inside
                disarmed = false // the hand moved to get here, so it meant to be here
                if browser.peeksAtEdges { peek(layout, inside) }
            }
            // The strip just ran out this way with the pointer still resting in the lane: what is
            // under the hand is a `+` now, and a hand that has not moved has not asked for a window —
            // which is exactly what a run of clicks along the chevron ends in. Let go of the peek and
            // wait to be hovered again. Only where the button is invisible: a `+` you can see turn
            // into a `+` is one you meant to click, and refusing it would be the surprise.
            .onChange(of: step.opens) { _, opens in
                guard browser.peeksAtEdges else { return }
                disarmed = opens && hovering
                if disarmed { peek(layout, false) }
            }
            // Gone from under the cursor — the workspace emptied, or the overview opened — and a view
            // that is gone never reports the exit. The flag would stay set and the next button here
            // would come up already lit with the mouse nowhere near it; the strip would stay leaning.
            .onDisappear {
                hovering = false
                disarmed = false
                peek(layout, false)
            }
            // Switched off with the pointer resting here: the button stops asking for peeks, so it has
            // to hand back the one it is holding. `BrowserState` cannot — it does not know which side.
            .onChange(of: browser.peeksAtEdges) { _, peeks in
                disarmed = false
                if peeks, hovering { peek(layout, true) }
            }
            .help(step.help)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: disarmed)
        }
    }

    private func step(layout: NiriLayout) -> (symbol: String, help: String, opens: Bool, action: () -> Void)? {
        if layout.canFocusColumn(direction) {
            return (direction < 0 ? "chevron.left" : "chevron.right",
                    direction < 0 ? String(localized: "Previous window (⌥←)") : String(localized: "Next window (⌥→)"),
                    false,
                    { browser.focusColumn(direction) })
        }
        // Nothing that way, so the button offers the only other thing that can be there: a window.
        // An empty workspace is left alone — it says the same thing in the middle of the screen, with
        // room to say it properly.
        if layout.focusedWorkspace?.isEmpty == false {
            let side: NiriPlacement = direction < 0 ? .left : .right
            return ("plus",
                    direction < 0 ? String(localized: "New window on the left") : String(localized: "New window (⌘T)"),
                    true,
                    { browser.newTab(on: side) })
        }
        return nil
    }

    /// Every edge button peeks — the one that walks to the next window and the one that opens a new
    /// one — and each lets go of the side it took by name: the pointer going straight from one end of
    /// the strip to the other cannot leave it leaning the wrong way.
    private func peek(_ layout: NiriLayout, _ hovering: Bool) {
        withAnimation(NiriLayout.peekAnimation) { layout.hoverStripEdge(direction, hovering) }
    }

    /// The symbol: the glyph and nothing else — no plate, no border, no shadow. Where it is peeked at,
    /// the strip has already leaned aside to answer, and anything drawn around the glyph is a second,
    /// smaller answer sitting on top of the real one. Where it stands on the screen it is on its own
    /// against a page, and a plate there would be a permanent one.
    ///
    /// Peeked at, it follows the peek rather than the pointer: a `+` that arrived under a hand that
    /// never moved is disarmed, and drawing it would offer a window the next click would not open.
    /// Standing, it rests at a little under half and comes up to full under the pointer — quiet enough
    /// to live in every gap, and there is no lean coming to say anything louder.
    ///
    /// The profile's colour by name rather than `.tint`: an `NSHostingView` starts a fresh environment
    /// (see the `ClickCatcher` overlay, which has to hand `browser` back in), so a tint set on the
    /// window's root never reaches this far and the glyph would come up in the system accent.
    private func glyph(_ symbol: String, layout: NiriLayout) -> some View {
        let width = max(11, Self.lane(layout) - 2)
        let shown: Double
        if browser.peeksAtEdges {
            shown = hovering && !disarmed ? 1 : 0
        } else {
            shown = hovering ? 1 : 0.45
        }
        return Image(systemName: symbol)
            .font(.system(size: min(11, width), weight: .bold))
            .foregroundStyle(browser.selectedProfile.color)
            .opacity(shown)
    }
}

/// Transparent AppKit view that swallows the first click on an unfocused window and reports it.
private struct ClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(action: action) }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }

    final class CatcherView: NSView {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Focus the window even when the app itself isn't frontmost, like any macOS window would.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { action() }
    }
}

/// Right-click on the canvas.
private struct StripMenu: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Button("New Window") { browser.newTab() }
        Button("New Document") { browser.newDocument() }
        Divider()
        Button("Workspace Above") { browser.focusWorkspace(-1) }
            .disabled(!browser.layout.canFocusWorkspace(-1))
        Button("Workspace Below") { browser.focusWorkspace(1) }
            .disabled(!browser.layout.canFocusWorkspace(1))
        Toggle("Overview", isOn: Binding(get: { browser.layout.isOverview }, set: { _ in browser.toggleOverview() }))
        Toggle("Full Width", isOn: Binding(get: { browser.layout.fill == .window }, set: { _ in browser.toggleFullWindow() }))
        Divider()
        Button("Settings…") { browser.openBuiltIn(.settings) }
    }
}

/// Everything the ⌥ bindings do to one window, without ⌥. It used to hang off the window's title
/// bar; with the page running edge to edge it hangs off the page's own context menu instead, and off
/// the layout button in the top bar.
struct ColumnMenu: View {
    let tab: BrowserTab

    @Environment(BrowserState.self) private var browser

    var body: some View {
        Button("New Window") { browser.newTab() }
        Button("New Document") { browser.newDocument() }
        Button("Close Window") { browser.closeTab(tab.id) }
        Divider()
        Toggle("Full Width", isOn: Binding(
            get: { browser.layout.fill == .window && browser.selectedTabID == tab.id },
            set: { _ in browser.selectTab(tab.id); browser.toggleFullWindow() }
        ))
        Divider()
        Button("Move Left") { browser.selectTab(tab.id); browser.moveColumn(-1) }
        Button("Move Right") { browser.selectTab(tab.id); browser.moveColumn(1) }
        Button("Move to Workspace Above") { browser.selectTab(tab.id); browser.moveColumnToWorkspace(-1) }
        Button("Move to Workspace Below") { browser.selectTab(tab.id); browser.moveColumnToWorkspace(1) }
    }
}

/// The light along an edge the rail was pushed into with nothing behind it (`NiriLayout.hitWall`).
///
/// It is the answer to a gesture that changed nothing, so it has to be visible without being an
/// event: a rail that flashed a bar of colour every time you reached its end would be a rail that
/// scolds. What is drawn is a band of the profile's own colour lying along that edge, brightest
/// against it and gone within a fraction of the screen — the light a wall would catch, not a wall
/// drawn on the screen. It fades out towards both corners for the same reason: a band that ran the
/// full height, corner to corner, would read as a border the window had grown.
///
/// The depth is a fraction of the viewport like everything else here, and the brightness is the
/// layout's (`wallGlow`) — a push held by a finger keeps it lit for as long as it is held, a refused
/// step lights it once and lets it go.
private struct StripWalls: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        // Both read *here*, in the body itself, and handed down as plain numbers. A value read only
        // inside a `GeometryReader`'s closure is read during layout rather than during body, and an
        // `@Observable` change to it does not reliably invalidate this view: the light then waited
        // for something else to redraw it, which on a rail that is a wall on both sides meant the
        // press after the one you made.
        let lit = layout.wall
        let glow = layout.wallGlow
        if let lit, glow > 0.005 {
            GeometryReader { proxy in
                // All four edges are laid out, and the dark ones cost a transparent gradient each.
                // One band that moved to whichever edge was lit would be *animated* from edge to
                // edge, which is what it did: a rail with one window (or none) is a wall on both
                // sides, so ⌥← then ⌥→ sent the light flying across the window like something
                // thrown. Which edge is lit is a fact about a gesture, not a movement.
                ZStack {
                    ForEach(NiriEdge.allCases, id: \.self) { edge in
                        band(edge, glow: lit == edge ? glow : 0, in: proxy.size)
                    }
                }
            }
            .allowsHitTesting(false)
            // The brightness eases, the *place* never does: changing edges puts one out where it
            // stands and lights the other where it stands, in the same frame. Without this the swap
            // inherits whatever animation caused it — a layout step, a third of a second of it.
            .animation(nil, value: lit)
        }
    }

    private func band(_ edge: NiriEdge, glow: CGFloat, in size: CGSize) -> some View {
        let sideways = edge == .leading || edge == .trailing
        let depth = max(30, (sideways ? size.width : size.height) * 0.055)
        let accent = browser.selectedProfile.color
        let stops: [Gradient.Stop] = [
            .init(color: accent.opacity(0.5 * glow), location: 0),
            .init(color: accent.opacity(0.14 * glow), location: 0.4),
            .init(color: accent.opacity(0), location: 1)
        ]
        return Rectangle()
            .fill(LinearGradient(stops: stops, startPoint: from(edge), endPoint: to(edge)))
            .frame(width: sideways ? depth : nil, height: sideways ? nil : depth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(edge))
            // Softest at the corners: the light is on the edge the gesture pushed into, and the
            // corners belong to the two edges it did not.
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.16),
                    .init(color: .white, location: 0.84),
                    .init(color: .clear, location: 1)
                ], startPoint: sideways ? .top : .leading, endPoint: sideways ? .bottom : .trailing)
            }
    }

    private func alignment(_ edge: NiriEdge) -> Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .above: .top
        case .below: .bottom
        }
    }

    /// The gradient runs *from* the edge that was pushed into, inwards.
    private func from(_ edge: NiriEdge) -> UnitPoint {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .above: .top
        case .below: .bottom
        }
    }

    private func to(_ edge: NiriEdge) -> UnitPoint {
        switch edge {
        case .leading: .trailing
        case .trailing: .leading
        case .above: .bottom
        case .below: .top
        }
    }
}

// MARK: - Background

private struct StripBackground: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let accent = browser.selectedProfile.color
        Rectangle()
            .fill(Color(nsColor: .underPageBackgroundColor))
            .overlay {
                LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.06)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
    }
}

/// Name plates riding above each strip in the overview. They sit outside the scaled canvas, so the
/// text stays readable however far the overview is zoomed out — which means placing them by hand:
/// a point `p` of the canvas lands at `centre + (p - centre) * scale` on screen.
private struct WorkspacePlates: View {
    let size: CGSize

    @Environment(BrowserState.self) private var browser
    @State private var editing: UUID?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let layout = browser.layout
        let centre = size.height / 2
        let step = size.height + layout.workspaceSpacing
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { index, workspace in
                let top = CGFloat(index - layout.focusedWorkspaceIndex) * step + layout.verticalPreview
                plate(index: index, workspace: workspace)
                    .position(x: size.width / 2, y: max(16, centre + (top - centre) * layout.overviewScale - 16))
            }
        }
    }

    @ViewBuilder
    private func plate(index: Int, workspace: NiriWorkspace) -> some View {
        let layout = browser.layout
        let isCurrent = index == layout.focusedWorkspaceIndex
        Group {
            if editing == workspace.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .frame(width: 160)
                    .focused($focused)
                    .onSubmit { commit(index) }
                    .onExitCommand { editing = nil }
            } else {
                Text(layout.title(at: index))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .onTapGesture(count: 2) { startEditing(workspace) }
                    .onTapGesture { browser.focusWorkspace(at: index) }
                    .contextMenu {
                        Button("Rename…") { startEditing(workspace) }
                        if !workspace.name.isEmpty {
                            Button("Clear Name") { browser.layout.rename(workspaceAt: index, to: "") }
                        }
                        // A row with nothing in it is normally asked about the moment it empties;
                        // this is the way out for one that was already empty before it was ever
                        // asked — an old rail, or an answer of "keep" that has since gone stale.
                        if workspace.isEmpty, !workspace.name.isEmpty {
                            Button("Delete Workspace", role: .destructive) {
                                browser.layout.removeWorkspace(workspace.id)
                            }
                        }
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay { if isCurrent { Capsule().strokeBorder(browser.selectedProfile.color, lineWidth: 1.5) } }
        .help("Double-click to rename")
    }

    private func startEditing(_ workspace: NiriWorkspace) {
        draft = workspace.name
        editing = workspace.id
        focused = true
    }

    private func commit(_ index: Int) {
        browser.layout.rename(workspaceAt: index, to: draft)
        editing = nil
    }
}

/// The one-line reminder along the bottom of the overview.
private struct OverviewHint: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        if browser.layout.isOverview {
            Text("scroll up/down for workspaces · sideways to run along a rail · click a window to open it · drag one to move it · double-click a name to rename · ⌥O to close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
                .transition(.opacity)
        }
    }
}
#endif
