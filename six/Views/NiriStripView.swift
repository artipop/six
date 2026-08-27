import AppKit
import SwiftUI
import WebKit

/// The niri canvas: every workspace is a full-screen horizontal strip of columns; the workspaces are
/// stacked vertically and only one of them is on screen at a time.
struct NiriStripView: View {
    @Environment(BrowserState.self) private var browser
    @FocusState private var addressFocus: UUID?
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
                        WorkspaceView(workspace: workspace, index: index, size: proxy.size, addressFocus: $addressFocus)
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
        .overlay(alignment: .leading) { StripEdgeButton(direction: -1) }
        .overlay(alignment: .trailing) { StripEdgeButton(direction: 1) }
        .overlay(alignment: .top) { if layout.showsFullscreen { FullscreenBar() } }
        .overlay(alignment: .bottom) { OverviewHint() }
        .contextMenu { StripMenu() }
        .onAppear(perform: startMonitor)
        .onDisappear { monitor.stop() }
        .focusedSceneValue(\.focusAddressBar, FocusAddressBarAction {
            browser.exitOverview()
            browser.restoreChrome() // the address bar is part of the chrome a filled window hides
            addressFocus = browser.layout.focusedTabID
        })
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
    var addressFocus: FocusState<UUID?>.Binding

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
                                       x: frame.minX - scroll, width: frame.width, layout: layout),
                        addressFocus: addressFocus
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
    var addressFocus: FocusState<UUID?>.Binding

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
            if !fullscreen {
                WindowChrome(tab: tab, isFocused: isFocused, addressFocus: addressFocus)
                    .contextMenu { ColumnMenu(tab: tab) }
                Divider()
            }
            // Above the page even in fullscreen: the page is suspended waiting for this answer, and a
            // window with nowhere to say yes is a window that seems to have broken the site.
            if let question = permissions.question(for: tab.id) {
                PermissionBar(tab: tab, question: question)
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
        .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 12, style: .continuous))
        .overlay {
            if !fullscreen {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isFocused ? accent : Color.primary.opacity(0.12),
                                  lineWidth: isFocused ? 2.5 : 1)
            }
        }
        .shadow(color: .black.opacity(fullscreen ? 0 : (isFocused ? 0.28 : 0.16)),
                radius: fullscreen ? 0 : (isFocused ? 18 : 10), y: fullscreen ? 0 : 5)
        .animation(.easeOut(duration: 0.18), value: isFocused)
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
                Image(nsImage: image)
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

/// Chevron parked on the left/right edge: one click scrolls the strip by one column. At the end of the
/// strip the right one turns into a `+`, so the way to add a window is where you run out of them; on the
/// left there is simply nothing, and the edge itself tells you whether the strip continues.
private struct StripEdgeButton: View {
    let direction: Int

    @Environment(BrowserState.self) private var browser
    @State private var hovering = false

    var body: some View {
        let layout = browser.layout
        // In fullscreen these give way to the bar at the top edge, which carries the same two steps.
        if !layout.isOverview, !layout.showsFullscreen {
            // Hosted in AppKit like the fullscreen bar: over a page a SwiftUI button never sees the
            // mouse (see `ClickCatcher`), and with the window filled there is nothing but page here.
            HostedOverlay {
                content(layout: layout)
            }
            .frame(width: 42, height: 60)
        }
    }

    @ViewBuilder
    private func content(layout: NiriLayout) -> some View {
        if layout.canFocusColumn(direction) {
            button(symbol: direction < 0 ? "chevron.left" : "chevron.right",
                   help: direction < 0 ? "Previous window (⌥←)" : "Next window (⌥→)",
                   action: { browser.focusColumn(direction) })
        } else if direction > 0, layout.focusedWorkspace?.isEmpty == false {
            button(symbol: "plus", help: "New window (⌘T)", action: { browser.newTab() })
        }
    }

    private func button(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 60)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator)
                }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .opacity(hovering ? 1 : 0.45)
        .onHover { hovering = $0 }
        // The button goes away under the cursor whenever the strip runs out of columns on this side,
        // and a view that is gone never reports the exit — the flag would stay set and the next
        // button to appear here would come up already lit, with the mouse nowhere near it.
        .onDisappear { hovering = false }
        .animation(.easeOut(duration: 0.15), value: hovering)
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
private struct ColumnWidthPicker: View {
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

/// Right-click on a window's title bar: everything the ⌥ bindings do, without ⌥.
private struct ColumnMenu: View {
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
