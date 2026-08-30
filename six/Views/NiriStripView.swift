#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// The niri canvas: every workspace is a full-screen horizontal strip of columns; the workspaces are
/// stacked vertically and only one of them is on screen at a time.
struct NiriStripView: View {
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
                        WorkspaceView(workspace: workspace, index: index, size: proxy.size)
                            .offset(y: offset(of: index, height: proxy.size.height, layout: layout))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .scaleEffect(layout.overviewScale, anchor: .center)
            .overlay { if layout.isOverview { WorkspacePlates(size: proxy.size) } }
            .onChange(of: proxy.size, initial: true) { layout.updateViewport(proxy.size) }
            .onChange(of: proxy.frame(in: .global), initial: true) { _, frame in stripFrame = frame }
        }
        .background(StripBackground())
        .clipped()
        .overlay { StripEdgeButtons() }
        .overlay(alignment: .top) { if layout.showsFullscreen { FullscreenBar() } }
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
        monitor.onPreview = { preview in
            if preview == 0 {
                withAnimation(NiriLayout.switchAnimation) { layout.verticalPreview = 0 }
            } else {
                layout.verticalPreview = preview
            }
        }
        monitor.snapsHorizontally = { layout.centersFocus && !layout.isOverview }
        monitor.onPreviewColumn = { preview in
            if preview == 0 {
                withAnimation(NiriLayout.switchAnimation) { layout.horizontalPreview = 0 }
            } else {
                layout.horizontalPreview = preview
            }
        }
        monitor.onPan = { browser.panStrip(by: $0) }
        monitor.onPanEnded = { browser.endStripPan() }
        monitor.onEscape = {
            if layout.isOverview { browser.exitOverview(); return true }
            if layout.fill == .screen { browser.exitFullscreen(); return true }
            return false
        }
        monitor.start()
    }
}

// MARK: - One workspace

private struct WorkspaceView: View {
    let workspace: NiriWorkspace
    let index: Int
    let size: CGSize

    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        let frames = layout.columnFrames(workspace)
        let isCurrent = index == layout.focusedWorkspaceIndex
        let scroll = layout.resolvedOffset(workspace) - (isCurrent ? layout.horizontalPreview : 0)
        // The overview scales the canvas down, so a workspace layer covers proportionally more than the
        // window: it has to be that wide, and centred on the same point, or the strip is cut off at the
        // window edges instead of running the full width of the screen.
        let layerWidth = layout.visibleWidth

        ZStack(alignment: .topLeading) {
            Color.clear
            if workspace.isEmpty {
                EmptyWorkspaceHint()
                    .frame(width: layerWidth, height: size.height)
            }
            ForEach(Array(workspace.columns.enumerated()), id: \.element.id) { position, column in
                if let tab = browser.tab(column.tabID), frames.indices.contains(position) {
                    let frame = frames[position]
                    let isFocused = isCurrent && position == workspace.focus
                    ColumnView(
                        tab: tab,
                        isFocused: isFocused,
                        isCurrentWorkspace: isCurrent,
                        isLive: isLive(workspaceDistance: abs(index - layout.focusedWorkspaceIndex),
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
    private var fullscreen: Bool { browser.layout.fillsViewport }

    private func activate() {
        browser.selectTab(tab.id)
        browser.exitOverview()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the page even in fullscreen: the page is suspended waiting for this answer, and a
            // window with nowhere to say yes is a window that seems to have broken the site.
            if let question = permissions.question(for: tab.id) {
                PermissionBar(tab: tab, question: question)
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
        // The window's own progress, on the window: the top bar's field carries a spinner for the
        // focused page, and this is the one thing a *neighbour* still has to be able to say.
        .overlay(alignment: .top) {
            if !tab.isDocument, tab.isLoading {
                LoadingLine(progress: tab.estimatedProgress, accent: accent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 12, style: .continuous))
        .overlay {
            if !fullscreen {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? accent : Color.primary.opacity(0.12),
                                  lineWidth: isFocused ? 2.5 : 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !fullscreen, isCurrentWorkspace, !browser.layout.isOverview {
                // Sitting on the corner rather than inside it: most of the button is over the gap
                // between the windows, so the page underneath keeps the clicks it should have.
                ColumnCloseBadge(tab: tab).offset(x: 11, y: -11)
            }
        }
        .shadow(color: .black.opacity(fullscreen ? 0 : (isFocused ? 0.28 : 0.16)),
                radius: fullscreen ? 0 : (isFocused ? 18 : 10), y: fullscreen ? 0 : 5)
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

/// The loading line, drawn by hand: a linear `ProgressView` brings a track and a thickness of its
/// own, and a browser wants a hairline the page seems to push along, not a control.
private struct LoadingLine: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(accent)
                .frame(width: max(3, proxy.size.width * min(max(progress, 0.03), 1)))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
        .transition(.opacity)
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
/// fills the viewport there is no gap left to stand in, so they fall back to the edge and stay out of
/// sight until the pointer comes looking (`StripEdgeButton`).
private struct StripEdgeButtons: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        if !layout.isOverview, !layout.showsFullscreen {
            GeometryReader { proxy in
                let lane = StripEdgeButton.lane(layout)
                let frame = layout.focusedColumnFrame
                let inset = lane / 2 + 1
                // Half a gap out from the window's edge, and never off the screen: a window as wide as
                // the viewport leaves nowhere to stand but the edge itself.
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

/// A sliver standing in the gap beside the focused window: one click steps one column. At the end of
/// the strip the right one turns into a `+`, so the way to add a window is where you run out of them;
/// on the left there is simply nothing, and the empty gap tells you the strip is over.
///
/// It is as narrow as the gap it stands in — a button wide enough to read comfortably is a button
/// covering the page next to it, and the page is what the window is for. Tiled, it rests at a quarter
/// and lights up under the pointer; with the window filled there is no gap left at all, so it stays
/// away entirely until the pointer comes to the edge looking for it.
private struct StripEdgeButton: View {
    let direction: Int

    @Environment(BrowserState.self) private var browser
    @State private var hovering = false

    /// The lane tracks the layout, not the screen: it is the gap the layout already leaves between
    /// two windows, floored so it stays clickable and capped so it never becomes a margin.
    static func lane(_ layout: NiriLayout) -> CGFloat {
        layout.fillsViewport ? 22 : max(13, min(28, layout.gap))
    }

    /// A tall thin pill — enough of a target to hit without aiming, and it reaches nowhere sideways.
    /// Taller with the window filled, where it is invisible until the pointer finds it: a target you
    /// cannot see has to be one you cannot miss along the edge you are sweeping.
    private func pillHeight(_ layout: NiriLayout) -> CGFloat {
        let fraction = layout.fillsViewport ? 0.3 : 0.16
        return max(52, min(280, layout.viewport.height * fraction))
    }

    var body: some View {
        let layout = browser.layout
        // Hosted in AppKit like the fullscreen bar: over a page a SwiftUI button never sees the
        // mouse (see `ClickCatcher`), and with the window filled there is nothing but page here.
        HostedOverlay {
            content(layout: layout)
        }
        .frame(width: Self.lane(layout), height: pillHeight(layout))
    }

    @ViewBuilder
    private func content(layout: NiriLayout) -> some View {
        if let step = step(layout: layout) {
            pill(symbol: step.symbol, help: step.help, layout: layout, action: step.action)
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    private func step(layout: NiriLayout) -> (symbol: String, help: String, action: () -> Void)? {
        if layout.canFocusColumn(direction) {
            return (direction < 0 ? "chevron.left" : "chevron.right",
                    direction < 0 ? String(localized: "Previous window (⌥←)") : String(localized: "Next window (⌥→)"),
                    { browser.focusColumn(direction) })
        }
        if direction > 0, layout.focusedWorkspace?.isEmpty == false {
            return ("plus", String(localized: "New window (⌘T)"), { browser.newTab() })
        }
        return nil
    }

    private func pill(symbol: String, help: String, layout: NiriLayout, action: @escaping () -> Void) -> some View {
        let width = max(11, Self.lane(layout) - 2)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: min(11, width), weight: .bold))
                .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: width, height: pillHeight(layout))
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        // Filled, the strip has no gap to stand in and the sliver is over the page: it stays out of
        // sight until the pointer is at the edge. Tiled it lives in the gap and can rest there faintly.
        // Invisible is not gone — a button at zero opacity still answers the mouse, which is the whole
        // trick: the sliver is its own hover target and nothing else has to be laid over the page.
        .opacity(hovering ? 1 : (layout.fillsViewport ? 0 : 0.3))
        .onHover { hovering = $0 }
        // The button goes away under the cursor whenever the strip runs out of columns on this side,
        // and a view that is gone never reports the exit — the flag would stay set and the next
        // button to appear here would come up already lit, with the mouse nowhere near it.
        .onDisappear { hovering = false }
        .help(help)
        .transition(.opacity)
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
        Toggle("Full Window", isOn: Binding(get: { browser.layout.fill == .window }, set: { _ in browser.toggleFullWindow() }))
        Toggle("Fullscreen", isOn: Binding(get: { browser.layout.fill == .screen }, set: { _ in browser.toggleFullscreen() }))
        Divider()
        ColumnWidthPicker()
        Divider()
        Toggle("Center Focused Window", isOn: Binding(
            get: { browser.layout.centersFocus },
            set: { _ in browser.toggleCenterFocus() }
        ))
    }
}

/// The shared width preset, with the current one checked — the same list as in the Layout menu.
struct ColumnWidthPicker: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Picker("Column Width", selection: Binding(
            get: { browser.layout.preferredWidthIndex },
            set: { browser.setColumnWidth($0) }
        )) {
            ForEach(Array(NiriLayout.widthPresetTitles.enumerated()), id: \.offset) { index, title in
                Text(title).tag(index)
            }
        }
        .pickerStyle(.inline)
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
        ColumnWidthPicker()
        Divider()
        Toggle("Compact Width", isOn: Binding(
            get: { browser.layout.isFullWidth(tabID: tab.id) },
            set: { _ in browser.selectTab(tab.id); browser.toggleCompactWidth() }
        ))
        Toggle("Full Window", isOn: Binding(
            get: { browser.layout.fill == .window && browser.selectedTabID == tab.id },
            set: { _ in browser.selectTab(tab.id); browser.toggleFullWindow() }
        ))
        Toggle("Fullscreen", isOn: Binding(
            get: { browser.layout.fill == .screen && browser.selectedTabID == tab.id },
            set: { _ in browser.selectTab(tab.id); browser.toggleFullscreen() }
        ))
        Divider()
        Button("Move Left") { browser.selectTab(tab.id); browser.moveColumn(-1) }
        Button("Move Right") { browser.selectTab(tab.id); browser.moveColumn(1) }
        Button("Move to Workspace Above") { browser.selectTab(tab.id); browser.moveColumnToWorkspace(-1) }
        Button("Move to Workspace Below") { browser.selectTab(tab.id); browser.moveColumnToWorkspace(1) }
    }
}

/// The strip's controls while fullscreen hides everything else: push the pointer against the top edge
/// and the bar comes down, move away and it goes. It is hosted in an AppKit view of its own, because
/// SwiftUI drawn over a page never sees the mouse — `WKWebView` is a real AppKit view and takes it
/// first, the same reason `ClickCatcher` exists.
private struct FullscreenBar: View {
    @Environment(BrowserState.self) private var browser
    @State private var revealed = false

    var body: some View {
        HostedOverlay {
            // A hosted view starts a SwiftUI hierarchy of its own: nothing is inherited, so the model
            // has to be handed over explicitly.
            content.environment(browser)
        }
        .frame(height: revealed ? 40 : 6)
    }

    private var content: some View {
        Group {
            if revealed {
                bar
            } else {
                Color.clear.contentShape(Rectangle()) // the strip of screen that brings the bar back
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Deliberately not animated: the hosted view's height changes with it, and an animation turns
        // one resize into a hundred, each one a layout pass through the window.
        .onHover { revealed = $0 }
    }

    private var bar: some View {
        let layout = browser.layout
        return HStack(spacing: 10) {
            Color.clear.frame(width: 68, height: 1) // the window buttons are still there, over the page
            button("chevron.left", "Previous window (⌥←)", enabled: layout.canFocusColumn(-1)) { browser.focusColumn(-1) }
            button("chevron.right", "Next window (⌥→)", enabled: layout.canFocusColumn(1)) { browser.focusColumn(1) }
            Text(browser.selectedTab?.title ?? "")
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            button("chevron.up", "Workspace above (⌥↑)", enabled: layout.canFocusWorkspace(-1)) { browser.focusWorkspace(-1) }
            button("chevron.down", "Workspace below (⌥↓)", enabled: layout.canFocusWorkspace(1)) { browser.focusWorkspace(1) }
            button("rectangle.grid.1x2", "Overview (⌥O)", enabled: true) { browser.toggleOverview() }
            button("arrow.down.right.and.arrow.up.left", "Leave fullscreen (⌥⇧F or ⎋)", enabled: true) {
                browser.exitFullscreen()
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func button(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(help)
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
            Text("scroll up/down for workspaces · sideways to run along a strip · click a window to open it · double-click a name to rename · ⌥O to close")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
                .transition(.opacity)
        }
    }
}
#endif
