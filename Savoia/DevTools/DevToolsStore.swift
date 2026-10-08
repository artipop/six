import Foundation
import Observation
import WebKit

/// What an agent reads of a page: what it logged and what it requested, kept per window and cleared
/// when the window navigates. The page is instrumented for it (`PageInstrumentation`).
@MainActor
@Observable
final class DevToolsStore {
    static let consoleLimit = 500
    static let networkLimit = 500

    private let settings: ConfigurationStore
    @ObservationIgnored private let controllers: PageControllers
    @ObservationIgnored weak var browser: BrowserState?

    private(set) var console: [UUID: [ConsoleMessage]] = [:]
    private(set) var network: [UUID: [NetworkEntry]] = [:]
    /// Whoever has to hear that the tool list changed — `MCPHost.toolsChanged`, wired in `SavoiaApp`.
    @ObservationIgnored var onCaptureChanged: (() -> Void)?
    /// Per-window message handlers: the handler is what tells a message which window it came from.
    @ObservationIgnored private var handlers: [UUID: PageMessageHandler] = [:]

    #if os(macOS)
    let automation = Automation()
    @ObservationIgnored private(set) lazy var webDriver = WebDriverServer(automation: automation)

    /// Remote automation: it is also what puts the `automation_` tools in the MCP list.
    var allowsAutomation: Bool {
        didSet {
            guard allowsAutomation != oldValue else { return }
            settings.devToolsAutomation = allowsAutomation
            if allowsAutomation {
                webDriver.start()
            } else {
                webDriver.stop()
                automation.end()
            }
            onCaptureChanged?()
            Log.info(.devtools, allowsAutomation ? "remote automation allowed" : "remote automation off")
        }
    }
    #endif

    /// Console and network capture, for agents: it is also what puts `list_console_messages` and
    /// `list_network_requests` into Savoia's tool list. A person has the inspector for the same
    /// facts, told by the browser rather than by the page.
    var isCapturing: Bool {
        didSet {
            guard isCapturing != oldValue else { return }
            settings.devToolsCapture = isCapturing
            onCaptureChanged?()
            controllers.forEach { windowID, controller in install(in: controller, for: windowID) }
            if !isCapturing { console = [:]; network = [:] }
            // User scripts run at the *next* load, so the windows are built again.
            browser?.rebuildLivePages()
        }
    }

    init(settings: ConfigurationStore, controllers: PageControllers) {
        self.settings = settings
        self.controllers = controllers
        self.isCapturing = settings.devToolsCapture
        #if os(macOS)
        self.allowsAutomation = settings.devToolsAutomation && Automation.isAvailable
        if allowsAutomation { webDriver.start() }
        #endif
        controllers.onController { [weak self] windowID, controller in
            self?.install(in: controller, for: windowID)
        }
    }

    // MARK: The hooks

    private static let scriptName = "devtools"

    private func install(in controller: WKUserContentController, for windowID: UUID) {
        controller.removeScriptMessageHandler(forName: PageInstrumentation.handlerName, contentWorld: .page)
        handlers[windowID] = nil
        guard isCapturing else {
            controllers.setUserScripts([], named: Self.scriptName, for: windowID)
            return
        }
        let handler = PageMessageHandler(windowID: windowID, store: self)
        handlers[windowID] = handler
        controller.add(handler, contentWorld: .page, name: PageInstrumentation.handlerName)
        // Through the registry rather than the controller: the blocker's cosmetic rules are user
        // scripts too, and `removeAllUserScripts()` cannot tell whose is whose.
        controllers.setUserScripts([WKUserScript(
            source: PageInstrumentation.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page)], named: Self.scriptName, for: windowID)
    }

    /// The window closed, or is showing something else: what was captured belonged to the page that
    /// is gone.
    func forget(_ windowID: UUID) {
        console[windowID] = nil
        network[windowID] = nil
        handlers[windowID] = nil
    }

    func noteNavigation(_ windowID: UUID) {
        guard isCapturing else { return }
        console[windowID] = []
        network[windowID] = []
    }

    // MARK: What the page said

    fileprivate func receive(_ body: Any, from windowID: UUID) {
        guard isCapturing, let message = body as? [String: Any] else { return }
        let url = (message["url"] as? String) ?? browser?.tab(windowID)?.currentURL?.absoluteString ?? ""
        switch message["kind"] as? String {
        case "console":
            let entry = ConsoleMessage(
                level: (message["level"] as? String) ?? "log",
                text: (message["text"] as? String) ?? "",
                at: .now,
                url: url)
            console[windowID, default: []].append(entry)
            if console[windowID]!.count > Self.consoleLimit { console[windowID]!.removeFirst(console[windowID]!.count - Self.consoleLimit) }
        case "network":
            let entry = NetworkEntry(
                url: (message["url"] as? String) ?? "",
                method: (message["method"] as? String) ?? "GET",
                status: message["status"] as? Int,
                kind: (message["type"] as? String) ?? "other",
                milliseconds: message["ms"] as? Int ?? 0,
                bytes: (message["bytes"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                error: message["error"] as? String,
                at: .now)
            guard !entry.url.isEmpty else { return }
            network[windowID, default: []].append(entry)
            if network[windowID]!.count > Self.networkLimit { network[windowID]!.removeFirst(network[windowID]!.count - Self.networkLimit) }
        default:
            break
        }
    }

    /// A navigation that never happened — a certificate that did not check out, a host that does
    /// not resolve, a connection that was refused.
    ///
    /// It cannot arrive the way everything else here does. The instrumentation runs *in the page*,
    /// and a main frame that failed its provisional load has no page to run it: the one request
    /// that matters is the one request capture cannot see. So `BrowserTab` hands it over from the
    /// outside, and it lands where anyone looking for it will look — `list_console_messages` and
    /// `list_network_requests`, which is how a window is read on a machine where screenshots come
    /// back black.
    func noteLoadFailure(_ windowID: UUID, url: String, reason: String) {
        // Not silent when capture is off: this is one line per failed navigation, it is the answer
        // to "why is this window blank", and it is the only copy that survives the window being
        // closed. `Savoia.app/Contents/MacOS/Savoia` run from a terminal is where it appears.
        Log.error(.load, "\(url) failed: \(reason)")
        guard isCapturing else { return }
        console[windowID, default: []].append(ConsoleMessage(level: "error",
                                                             text: "Navigation failed: \(reason)",
                                                             at: .now,
                                                             url: url))
        network[windowID, default: []].append(NetworkEntry(url: url,
                                                           method: "GET",
                                                           status: nil,
                                                           kind: "document",
                                                           milliseconds: 0,
                                                           bytes: nil,
                                                           error: reason,
                                                           at: .now))
    }

    // MARK: Reading it back

    func consoleMessages(for windowID: UUID, level: String? = nil, limit: Int = 100) -> [ConsoleMessage] {
        let all = console[windowID] ?? []
        let filtered = level.map { wanted in all.filter { $0.level == wanted } } ?? all
        return Array(filtered.suffix(limit))
    }

    func networkRequests(for windowID: UUID, failedOnly: Bool = false, limit: Int = 100) -> [NetworkEntry] {
        let all = network[windowID] ?? []
        let filtered = failedOnly ? all.filter(\.isFailed) : all
        return Array(filtered.suffix(limit))
    }

    /// Where `take_screenshot` puts its files.
    static let screenshotFolder: URL = {
        AppSupport.folder("Screenshots")
    }()
}

/// One per window, because a message has to say which window it came from and the page cannot be
/// trusted to say so itself.
private final class PageMessageHandler: NSObject, WKScriptMessageHandler {
    let windowID: UUID
    weak var store: DevToolsStore?

    init(windowID: UUID, store: DevToolsStore) {
        self.windowID = windowID
        self.store = store
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let windowID = windowID
        Task { @MainActor [weak store] in
            store?.receive(body, from: windowID)
        }
    }
}
