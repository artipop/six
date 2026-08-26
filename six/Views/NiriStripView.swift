import AppKit
import SwiftUI
import WebKit

/// The niri canvas: every workspace is a full-screen horizontal strip of columns; the workspaces are
/// stacked vertically and only one of them is on screen at a time.
struct NiriStripView: View {
    @Environment(BrowserState.self) private var browser
    @FocusState private var addressFocus: UUID?
    @State private var monitor = NiriScrollMonitor()

    var body: some View {
        let layout = browser.layout
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    WorkspaceView(workspace: workspace, index: index, size: proxy.size, addressFocus: $addressFocus)
                        .offset(y: offset(of: index, height: proxy.size.height, layout: layout))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .scaleEffect(layout.overviewScale, anchor: .center)
            .overlay { if layout.isOverview { WorkspacePlates(size: proxy.size) } }
            .onChange(of: proxy.size, initial: true) { layout.updateViewport(proxy.size) }
        }
        .background(StripBackground())
        .clipped()
        .overlay(alignment: .leading) { StripEdgeButton(direction: -1) }
        .overlay(alignment: .trailing) { StripEdgeButton(direction: 1) }
        .overlay(alignment: .bottom) { OverviewHint() }
        .contextMenu { StripMenu() }
        .onAppear(perform: startMonitor)
        .onDisappear { monitor.stop() }
        .focusedSceneValue(\.focusAddressBar, FocusAddressBarAction {
            browser.exitOverview()
            addressFocus = browser.layout.focusedTabID
        })
    }

    private func offset(of index: Int, height: CGFloat, layout: NiriLayout) -> CGFloat {
        let step = height + layout.workspaceSpacing
        return CGFloat(index - layout.focusedWorkspaceIndex) * step + layout.verticalPreview
    }

    private func startMonitor() {
        let layout = browser.layout
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
                        isLive: isLive(workspaceDistance: abs(index - layout.focusedWorkspaceIndex),
                                       x: frame.minX - scroll, width: frame.width, layout: layout),
                        addressFocus: addressFocus
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX - scroll, y: frame.minY)
                    .zIndex(isFocused ? 1 : 0)
                }
            }
        }
        .frame(width: layerWidth, height: size.height, alignment: .topLeading)
        .clipped()
        .offset(x: -(layerWidth - size.width) / 2)
        .opacity(layout.isOverview && !isCurrent ? 0.7 : 1)
    }

    /// Only nearby columns get a real web view; the rest are cheap cards, so a big strip stays cheap.
    private func isLive(workspaceDistance: Int, x: CGFloat, width: CGFloat, layout: NiriLayout) -> Bool {
        guard workspaceDistance <= 1 else { return false }
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
    let isLive: Bool
    var addressFocus: FocusState<UUID?>.Binding

    @Environment(BrowserState.self) private var browser

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    /// A window that isn't the focused one is a target, not a page: the first click flies to it. Same in
    /// the overview, where every page is just a picture. `WKWebView` is a real AppKit view and takes the
    /// click before any SwiftUI overlay can, so the catcher has to be an AppKit view too.
    private var capturesClicks: Bool { !isFocused || browser.layout.isOverview }

    private func activate() {
        browser.selectTab(tab.id)
        browser.exitOverview()
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowChrome(tab: tab, isFocused: isFocused, addressFocus: addressFocus)
                .contextMenu { ColumnMenu(tab: tab) }
            Divider()
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
            } else if isLive {
                WebView(tab.page)
                    .webViewBackForwardNavigationGestures(.enabled)
                    .id(tab.id)
                    .onAppear(perform: tab.resumeIfNeeded)
                    .overlay { if capturesClicks { ClickCatcher(action: activate) } }
            } else {
                ColumnPlaceholder(tab: tab, accent: accent)
                    .contentShape(Rectangle())
                    .onTapGesture { if capturesClicks { activate() } }
            }
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? accent : Color.primary.opacity(0.12),
                              lineWidth: isFocused ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(isFocused ? 0.28 : 0.16), radius: isFocused ? 18 : 10, y: 5)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct ColumnPlaceholder: View {
    let tab: BrowserTab
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "globe")
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
        if !layout.isOverview {
            if layout.canFocusColumn(direction) {
                button(symbol: direction < 0 ? "chevron.left" : "chevron.right",
                       help: direction < 0 ? "Previous window (⌥←)" : "Next window (⌥→)",
                       action: { browser.focusColumn(direction) })
            } else if direction > 0, layout.focusedWorkspace?.isEmpty == false {
                button(symbol: "plus", help: "New window (⌘T)", action: { browser.newTab() })
            }
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
        Divider()
        Button("Workspace Above") { browser.focusWorkspace(-1) }
            .disabled(!browser.layout.canFocusWorkspace(-1))
        Button("Workspace Below") { browser.focusWorkspace(1) }
            .disabled(!browser.layout.canFocusWorkspace(1))
        Button(browser.layout.isOverview ? "Close Overview" : "Overview") { browser.toggleOverview() }
        Divider()
        Toggle("Center Focused Window", isOn: Binding(
            get: { browser.layout.centersFocus },
            set: { _ in browser.toggleCenterFocus() }
        ))
    }
}

/// Right-click on a window's title bar: everything the ⌥ bindings do, without ⌥.
private struct ColumnMenu: View {
    let tab: BrowserTab

    @Environment(BrowserState.self) private var browser

    var body: some View {
        Button("New Window") { browser.newTab() }
        Button("Close Window") { browser.closeTab(tab.id) }
        Divider()
        Button("Cycle Width") { browser.selectTab(tab.id); browser.cycleColumnWidth() }
        Button("Full Width") { browser.selectTab(tab.id); browser.toggleFullWidth() }
        Divider()
        Button("Move Left") { browser.selectTab(tab.id); browser.moveColumn(-1) }
        Button("Move Right") { browser.selectTab(tab.id); browser.moveColumn(1) }
        Button("Move to Workspace Above") { browser.selectTab(tab.id); browser.moveColumnToWorkspace(-1) }
        Button("Move to Workspace Below") { browser.selectTab(tab.id); browser.moveColumnToWorkspace(1) }
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
