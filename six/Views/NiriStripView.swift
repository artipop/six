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
            .scaleEffect(layout.isOverview ? NiriLayout.overviewScale : 1, anchor: .center)
            .onChange(of: proxy.size, initial: true) { layout.updateViewport(proxy.size) }
        }
        .background(StripBackground())
        .clipped()
        .overlay(alignment: .leading) { StripEdgeButton(direction: -1) }
        .overlay(alignment: .trailing) { StripEdgeButton(direction: 1) }
        .overlay(alignment: .top) { OverviewChrome() }
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
        monitor.snapsHorizontally = { layout.centersFocus }
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

        ZStack(alignment: .topLeading) {
            Color.clear
            if workspace.isEmpty {
                EmptyWorkspaceHint()
                    .frame(width: size.width, height: size.height)
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
                    .allowsHitTesting(!layout.isOverview)
                    .overlay {
                        // In the overview a page is a picture, not a target; and elsewhere a click on a
                        // background window brings it into focus instead of reaching the page under it.
                        if layout.isOverview || !isFocused {
                            Color.white.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    browser.selectTab(tab.id)
                                    browser.exitOverview()
                                }
                        }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .opacity(layout.isOverview && !isCurrent ? 0.7 : 1)
    }

    /// Only nearby columns get a real web view; the rest are cheap cards, so a big strip stays cheap.
    private func isLive(workspaceDistance: Int, x: CGFloat, width: CGFloat, layout: NiriLayout) -> Bool {
        guard workspaceDistance <= 1 else { return false }
        let margin = layout.viewport.width
        return x + width > -margin && x < layout.viewport.width + margin
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

    var body: some View {
        VStack(spacing: 0) {
            WindowChrome(tab: tab, isFocused: isFocused, addressFocus: addressFocus)
                .contextMenu { ColumnMenu(tab: tab) }
            Divider()
            if isLive {
                WebView(tab.page)
                    .webViewBackForwardNavigationGestures(.enabled)
                    .id(tab.id)
            } else {
                ColumnPlaceholder(tab: tab, accent: accent)
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
                if let host = tab.page.url?.host() {
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
                       tinted: false) { browser.focusColumn(direction) }
            } else if direction > 0, layout.focusedWorkspace?.isEmpty == false {
                button(symbol: "plus", help: "New window (⌘T)", tinted: true) { browser.newTab() }
            }
        }
    }

    private func button(symbol: String, help: String, tinted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tinted ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.primary))
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

/// Workspace name plates, shown only while the overview is open.
private struct OverviewChrome: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        if layout.isOverview {
            VStack {
                Text("Workspace \(layout.focusedWorkspaceIndex + 1) of \(layout.workspaces.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                Spacer()
                Text("scroll to change workspace · click a window to open it · ⌥O to close")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }
            .transition(.opacity)
        }
    }
}
