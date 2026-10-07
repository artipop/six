#if os(macOS)
import SwiftUI

/// One tab's page and the bars above it: the whole of the window below the tab bar, or one half of
/// it when two tabs are shown side by side.
struct TabPageView: View {
    let tab: BrowserTab
    let isFocused: Bool

    @Environment(BrowserState.self) private var browser
    @Environment(SitePermissions.self) private var permissions
    @Environment(AssistantStore.self) private var assistant

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    /// The other half of a pair is a target, not a page: the first click selects it. `WKWebView` takes
    /// the click before any SwiftUI overlay can, so the catcher has to be an AppKit view too.
    private var capturesClicks: Bool { !isFocused }

    private func activate() {
        browser.selectTab(tab.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Above the page: the page is suspended waiting for this answer.
            if let question = permissions.question(for: tab.id) {
                PermissionBar(tab: tab, question: question)
                Divider()
            }
            // An MCP app asking to run one of its server's tools (docs/mcp-apps.md).
            if let app = tab.app, let request = app.pendingToolRequest {
                MCPAppBar(session: app, request: request)
                Divider()
            }
            if let translation = browser.translation[tab.id], translation.saysSomething {
                TranslateBar(tab: tab, state: translation)
                Divider()
            }
            // Above the page, not over it: a `TextField` drawn over a `WKWebView` never sees the keyboard.
            if let find = browser.find[tab.id], find.isActive {
                FindBar(tab: tab, state: find)
                Divider()
            }
            page
        }
        .background(.background)
    }

    @ViewBuilder
    private var page: some View {
        if tab.showsStartPage {
            StartPage(tab: tab, isActive: isFocused)
                .allowsHitTesting(!capturesClicks)
                .overlay { if capturesClicks { tapCatcher } }
        } else if let saved = tab.pendingApp {
            MCPAppRestoreView(tab: tab, saved: saved)
                .allowsHitTesting(!capturesClicks)
                .overlay { if capturesClicks { tapCatcher } }
        } else if let page = tab.builtIn {
            BuiltInPageView(page: page, tab: tab)
                .allowsHitTesting(!capturesClicks)
                .overlay { if capturesClicks { tapCatcher } }
        } else if let document = tab.document {
            DocumentView(tab: tab, document: document, isActive: isFocused)
                .allowsHitTesting(!capturesClicks)
                .overlay { if capturesClicks { ClickCatcher(action: activate) } }
        } else if let page = tab.livePage {
            // A page discarded and built again is another view, and gets another host.
            PageHost(view: page)
                .id(tab.generation)
                .onAppear(perform: tab.resumeIfNeeded)
                .overlay {
                    if isFocused { AccessibilityOverlayView(tab: tab) }
                }
                // The ⌘E line, where the text is: the page's coordinates are this view's box.
                .overlay(alignment: .topLeading) {
                    if isFocused, assistant.line == .page(tab.id) {
                        AnchoredAssistantLine(tab: tab)
                    }
                }
                .overlay {
                    if let failure = tab.loadFailure {
                        PageFailureView(tab: tab, failure: failure)
                    }
                }
                .overlay { if capturesClicks { ClickCatcher(action: activate) } }
        } else {
            TabPlaceholder(tab: tab, accent: accent)
                .contentShape(Rectangle())
                .onTapGesture { if capturesClicks { activate() } }
        }
    }

    private var tapCatcher: some View {
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .onTapGesture(perform: activate)
    }
}

/// What a tab shows while its page is being built: the site's mark and its address.
private struct TabPlaceholder: View {
    let tab: BrowserTab
    let accent: Color

    @Environment(BrowserState.self) private var browser

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 10) {
                mark(size: 34)
                if let host = tab.currentURL?.host() {
                    Text(host)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func mark(size: CGFloat) -> some View {
        if tab.isWebPage, let icon = browser.siteIcons.icon(for: tab.currentURL?.host()) {
            Image(platform: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: tab.isDocument ? "doc.text" : tab.builtIn != nil ? "gearshape" : "globe")
                .font(.system(size: size * 0.9, weight: .light))
                .foregroundStyle(accent)
                .frame(width: size, height: size)
        }
    }
}

/// Transparent AppKit view that swallows the first click on the other half of a pair and reports it.
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

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { action() }
    }
}
#endif
