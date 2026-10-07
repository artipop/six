#if os(macOS)
import Foundation
import WebKit

/// WebKit's own automation — the protocol safaridriver drives Safari with — for the tabs opened
/// under it. SPI throughout, behind `responds(to:)`. docs/devtools.md.
@MainActor
final class Automation: NSObject {
    weak var browser: BrowserState?
    /// Nothing an automation tab does is anyone's site data; a new one for every session.
    private(set) var dataStore = WKWebsiteDataStore.nonPersistent()
    private var session: NSObject?
    private var pool: NSObject?
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<String, Never>] = [:]
    private var events: [String] = []

    private static let controlled = Selector(("_setControlledByAutomation:"))
    private static let dispatch = Selector(("_dispatchMessageFromRemoteForTesting:"))
    private static let replies = Selector(("_setMessageToFrontendHandlerForTesting:"))
    private static let attach = Selector(("_setAutomationSession:"))

    static var isAvailable: Bool {
        NSClassFromString("_WKAutomationSession") != nil && WKWebViewConfiguration.instancesRespond(to: controlled)
    }

    /// Puts a tab's configuration under the session, starting one if there is none.
    func prepare(_ configuration: WKWebViewConfiguration) {
        guard let pool = start(), let setter = class_getMethodImplementation(WKWebViewConfiguration.self, Self.controlled) else { return }
        configuration.perform(NSSelectorFromString("setProcessPool:"), with: pool)
        // Through the setter itself: `setValue(_:forKey:)` for this key never returns.
        typealias Setter = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(setter, to: Setter.self)(configuration, Self.controlled, true)
    }

    private func start() -> NSObject? {
        if let pool { return pool }
        guard Self.isAvailable, let sessionType = NSClassFromString("_WKAutomationSession") as? NSObject.Type,
              let poolType = NSClassFromString("WKProcessPool") as? NSObject.Type else { return nil }
        let session = sessionType.init()
        let pool = poolType.init()
        guard session.responds(to: Self.dispatch), session.responds(to: Self.replies), pool.responds(to: Self.attach) else { return nil }
        let handler: @convention(block) (NSString) -> Void = { [weak self] text in
            let text = text as String
            MainActor.assumeIsolated { self?.received(text) }
        }
        session.perform(Self.replies, with: handler)
        session.perform(NSSelectorFromString("setDelegate:"), with: self)
        pool.perform(Self.attach, with: session)
        self.session = session
        self.pool = pool
        Log.info(.devtools, "automation: a session started")
        return pool
    }

    /// One command of the protocol, and its reply as WebKit wrote it. Events that arrived since the
    /// last command follow the reply.
    func send(_ method: String, params: ACPJSON?) async throws -> String {
        guard let session else { throw BrowserTool.Failure(message: "No automation tab is open; open one with automation_open_window.") }
        let id = nextID
        nextID += 1
        let message = ACPJSON.object(["id": .number(Double(id)), "method": .string(method), "params": params ?? .object([:])])
        let text = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        let reply = await withCheckedContinuation { continuation in
            waiting[id] = continuation
            session.perform(Self.dispatch, with: text)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                self?.waiting.removeValue(forKey: id)?.resume(returning: #"{"error":{"message":"No reply in 30 s"}}"#)
            }
        }
        let seen = events
        events = []
        return seen.isEmpty ? reply : reply + "\n\nEvents since the last command:\n" + seen.joined(separator: "\n")
    }

    private func received(_ text: String) {
        let id = (try? JSONDecoder().decode(ACPJSON.self, from: Data(text.utf8)))?["id"]?.doubleValue
        if let id, let continuation = waiting.removeValue(forKey: Int(id)) {
            continuation.resume(returning: text)
        } else {
            events = Array((events + [text]).suffix(100))
        }
    }

    /// Automation is switched off: its tabs close and the session goes.
    func end() {
        if let browser { browser.closeTabs(browser.tabs.filter(\.isAutomated).map(\.id)) }
        pool?.perform(Self.attach, with: nil)
        waiting.values.forEach { $0.resume(returning: #"{"error":{"message":"Automation was switched off"}}"#) }
        waiting = [:]
        events = []
        session = nil
        pool = nil
        dataStore = .nonPersistent()
    }

    // MARK: What the session asks of the browser

    @objc(_automationSession:requestNewWebViewWithOptions:completionHandler:)
    func automationSession(_ session: NSObject, requestNewWebViewWithOptions options: UInt,
                           completionHandler: @escaping (WKWebView?) -> Void) {
        completionHandler(browser?.openAutomationTab(url: nil)?.page)
    }

    @objc(_automationSession:requestSwitchToWebView:completionHandler:)
    func automationSession(_ session: NSObject, requestSwitchTo view: WKWebView, completionHandler: @escaping () -> Void) {
        if let browser, let tab = browser.tabs.first(where: { $0.livePage === view }) { browser.selectTab(tab.id) }
        completionHandler()
    }

    // MARK: The window, which is the person's

    /// An automation tab is a tab in the one window: these are answered, and nothing moves.
    @objc(_automationSession:requestMaximizeWindowOfWebView:completionHandler:)
    func automationSession(_ session: NSObject, requestMaximizeWindowOf view: WKWebView, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    @objc(_automationSession:requestHideWindowOfWebView:completionHandler:)
    func automationSession(_ session: NSObject, requestHideWindowOf view: WKWebView, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    @objc(_automationSession:requestRestoreWindowOfWebView:completionHandler:)
    func automationSession(_ session: NSObject, requestRestoreWindowOf view: WKWebView, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: A page's dialog, for the protocol's dialog commands

    /// WebKit holds a command's reply while a dialog is up; it follows a later command, with the events.
    func dialogOpened() {
        waiting.values.forEach { $0.resume(returning: #"{"error":{"message":"A JavaScript dialog opened before the reply; answer it, and the reply follows"}}"#) }
        waiting = [:]
    }

    private func dialog(in view: WKWebView) -> PageDialog? {
        browser?.tabs.first { $0.livePage === view }?.dialogs.stoppingScript
    }

    @objc(_automationSession:isShowingJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, isShowingJavaScriptDialogFor view: WKWebView) -> Bool {
        dialog(in: view) != nil
    }

    @objc(_automationSession:dismissCurrentJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, dismissCurrentJavaScriptDialogFor view: WKWebView) {
        dialog(in: view)?.resolve(.dismissed)
    }

    @objc(_automationSession:acceptCurrentJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, acceptCurrentJavaScriptDialogFor view: WKWebView) {
        guard let dialog = dialog(in: view) else { return }
        dialog.resolve(.accepted(dialog.input))
    }

    @objc(_automationSession:messageOfCurrentJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, messageOfCurrentJavaScriptDialogFor view: WKWebView) -> String? {
        dialog(in: view)?.message
    }

    @objc(_automationSession:defaultTextOfCurrentJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, defaultTextOfCurrentJavaScriptDialogFor view: WKWebView) -> String? {
        dialog(in: view)?.defaultText
    }

    @objc(_automationSession:userInputOfCurrentJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, userInputOfCurrentJavaScriptDialogFor view: WKWebView) -> String? {
        dialog(in: view)?.input
    }

    @objc(_automationSession:setUserInput:forCurrentJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, setUserInput text: String, forCurrentJavaScriptDialogFor view: WKWebView) {
        dialog(in: view)?.input = text
    }

    /// `_WKAutomationSessionJavaScriptDialogType`, which starts at 1 for none.
    @objc(_automationSession:typeOfCurrentJavaScriptDialogForWebView:)
    func automationSession(_ session: NSObject, typeOfCurrentJavaScriptDialogFor view: WKWebView) -> Int {
        switch dialog(in: view)?.kind {
        case .alert: 2
        case .confirm: 3
        case .prompt: 4
        default: 1
        }
    }
}
#endif
