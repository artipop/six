import Foundation
import Observation
import WebKit

/// WebMCP on Apple's fronts: the polyfill in every window's pages and the channel it reports on.
/// Everything else — the registry, the calls, what a navigation means, the self-test — is
/// `WebMCPHost` and `WebMCPPage`, in `SixCore`; this file is the bridge, which is the only part
/// that is WebKit's.
///
/// Built the way `DevToolsStore` is, for the same reasons: a script **in the page's world**
/// (`WebMCPScript` says why that is the exception), a handler per window so a message cannot lie
/// about where it came from, and scripts registered by name in `PageControllers` so the blocker's
/// cosmetic rules are not wiped when this one changes.
///
/// Off by default, and a switch in Develop rather than anywhere a person would find it by accident:
/// until the per-site permission and the per-call confirmation exist (docs/webmcp.md, stage 3), a
/// page's tools are one agent call away from acting in the session the person is signed into.
@MainActor
@Observable
final class WebMCPStore {
    let host = WebMCPHost()
    private let settings: ConfigurationStore
    @ObservationIgnored private let controllers: PageControllers
    @ObservationIgnored weak var browser: BrowserState?
    @ObservationIgnored private var handlers: [UUID: WebMCPMessageHandler] = [:]

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            settings.webMCP = isEnabled
            controllers.forEach { windowID, controller in install(in: controller, for: windowID) }
            if !isEnabled { for tab in browser?.tabs ?? [] { host.forget(tab.id) } }
            // User scripts run at the *next* load, so the windows are built again.
            browser?.rebuildLivePages()
        }
    }

    init(settings: ConfigurationStore, controllers: PageControllers) {
        self.settings = settings
        self.controllers = controllers
        self.isEnabled = WebMCPHost.isWanted(setting: settings.webMCP)
        controllers.onController { [weak self] windowID, controller in
            self?.install(in: controller, for: windowID)
        }
    }

    private static let scriptName = "webmcp"

    private func install(in controller: WKUserContentController, for windowID: UUID) {
        controller.removeScriptMessageHandler(forName: WebMCPScript.handlerName, contentWorld: .page)
        handlers[windowID] = nil
        guard isEnabled else {
            controllers.setUserScripts([], named: Self.scriptName, for: windowID)
            return
        }
        let handler = WebMCPMessageHandler(windowID: windowID, host: host)
        handlers[windowID] = handler
        controller.add(handler, contentWorld: .page, name: WebMCPScript.handlerName)
        // At document start, so `document.modelContext` is there before the page's first script
        // looks for it.
        controllers.setUserScripts([WKUserScript(
            source: WebMCPScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page)], named: Self.scriptName, for: windowID)
    }

    func tools(in windowID: UUID) -> [WebMCPTool] {
        isEnabled ? host.tools(in: windowID) : []
    }

    /// A navigation committed. `WebPage`'s navigation events arrive through an async sequence, late
    /// enough that the new page has often announced its tools already — which is why this asks the
    /// page rather than clearing (`WebMCPHost.pageNavigated`).
    func noteNavigation(_ windowID: UUID) {
        guard isEnabled else { return }
        let tab = browser?.tab(windowID)
        host.pageNavigated(windowID, page: tab?.livePage == nil ? nil : tab)
    }

    func forget(_ windowID: UUID) {
        host.forget(windowID)
        handlers[windowID] = nil
    }

    /// Calls one of the tools a window's page declared, and waits for its answer.
    func call(_ name: String, arguments: ACPJSON, in tab: BrowserTab, timeout: Duration) async throws -> String {
        try await host.call(name, arguments: arguments, in: tab.id, on: { [weak tab] in tab }, timeout: timeout)
    }

    /// `SIX_WEBMCP_SELFTEST=<page>`, in the window on screen — the one way to watch this work on a
    /// machine where screenshots come back black (CLAUDE.md).
    func runSelfTestIfAsked() {
        host.runSelfTestIfAsked { [weak self] in
            guard let tab = self?.browser?.selectedTab else { return nil }
            return WebMCPSelfTest.Target(windowID: tab.id, page: tab, load: { [weak tab] address in
                if let url = URL(string: address) { tab?.load(url) }
            })
        }
    }
}

/// The third of a front's three things (`WebMCPPage`): a function body in the page's own world,
/// which is where the polyfill is.
extension BrowserTab: WebMCPPage {
    func evaluateInPage(_ body: String) async throws -> String {
        guard let page = livePage else { throw WebMCPError.navigatedAway }
        return (try await page.callJavaScript(body, contentWorld: .page) as? String) ?? ""
    }
}

/// One per window, because a message has to say which window it came from and the page cannot be
/// trusted to say so itself.
private final class WebMCPMessageHandler: NSObject, WKScriptMessageHandler {
    let windowID: UUID
    weak var host: WebMCPHost?

    init(windowID: UUID, host: WebMCPHost) {
        self.windowID = windowID
        self.host = host
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // The user script is main-frame only, so anything else on this channel is a frame
        // posting to it by hand.
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        let windowID = windowID
        Task { @MainActor [weak host] in
            host?.receive(text, from: windowID)
        }
    }
}
