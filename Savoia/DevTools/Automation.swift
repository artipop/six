#if os(macOS)
import Foundation
import WebKit

/// An automation tab's view takes a click as it comes, so the protocol's mouse lands with Savoia behind another app.
final class AutomatedWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ⌘C ⌘V ⌘X ⌘A as the Edit menu's actions: the menu bar leaves Paste off on a page with nothing editable.
    private func edits(_ event: NSEvent) -> Bool {
        guard KeyModifiers(event.modifierFlags) == .command, let action = Self.editing[event.charactersIgnoringModifiers ?? ""] else { return false }
        return NSApp.sendAction(action, to: self, from: nil)
    }

    override func keyDown(with event: NSEvent) {
        if !edits(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        event.type == .keyDown && edits(event) || super.performKeyEquivalent(with: event)
    }
}

/// WebKit's own automation — the protocol safaridriver drives Safari with — for the tabs opened
/// under it. SPI throughout, behind `responds(to:)`. docs/devtools.md.
@MainActor
final class Automation: NSObject {
    weak var browser: BrowserState?
    /// Nothing an automation tab does is anyone's site data; a new one for every session.
    private var ownStore = WKWebsiteDataStore.nonPersistent()
    /// The wpt stand's tabs keep their profile's store: WebKit gives a store that is not kept no notifications.
    var dataStore: WKWebsiteDataStore {
        if TestDriver.isOn, let browser { return browser.dataStore(for: browser.selectedProfile) }
        return ownStore
    }
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

    /// What a WebDriver client asked of the session's tabs: `webkit:alwaysAllowAutoplay` and `webkit:WebRTC`.
    struct Options {
        var alwaysAllowsAutoplay = false
        var allowsInsecureMediaCapture = false
        var suppressesICECandidateFiltering = false
    }
    var options = Options()

    /// Puts a tab's configuration under the session, starting one if there is none.
    func prepare(_ configuration: WKWebViewConfiguration) {
        guard let pool = start() else { return }
        configuration.perform(NSSelectorFromString("setProcessPool:"), with: pool)
        Self.set("_setControlledByAutomation:", true, on: configuration)
        // As Safari's automation windows: WebKit grants capture without asking anyone, so the devices are its mock ones.
        Self.set("_setMockCaptureDevicesEnabled:", true, on: configuration.preferences)
        if options.allowsInsecureMediaCapture { Self.set("_setMediaCaptureRequiresSecureConnection:", false, on: configuration.preferences) }
        if options.suppressesICECandidateFiltering { Self.set("_setICECandidateFilteringEnabled:", false, on: configuration.preferences) }
        if options.alwaysAllowsAutoplay { configuration.mediaTypesRequiringUserActionForPlayback = [] }
    }

    /// Through the setter itself: `setValue(_:forKey:)` for `_controlledByAutomation` never returns.
    private static func set(_ name: String, _ value: Bool, on object: NSObject) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let setter = class_getMethodImplementation(type(of: object), selector) else { return }
        typealias Setter = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(setter, to: Setter.self)(object, selector, value)
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
        guard session != nil else { throw BrowserTool.Failure(message: "No automation tab is open; open one with automation_open_window.") }
        let params = try params.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? [String: Any]()
        let reply = await exchange(method, params, timeout: .seconds(30))
        let seen = events
        events = []
        return seen.isEmpty ? reply : reply + "\n\nEvents since the last command:\n" + seen.joined(separator: "\n")
    }

    /// One command for the WebDriver server: its `result`, or the protocol's error in WebDriver's words.
    func command(_ name: String, _ params: [String: Any] = [:], timeout: Duration? = .seconds(30)) async throws -> [String: Any] {
        guard session != nil else { throw WebDriverError("no such window", "No automation tab is open.") }
        let text = await exchange("Automation." + name, params, timeout: timeout)
        let reply = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        if let error = reply["error"] as? [String: Any] { throw WebDriverError(protocolError: error) }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func exchange(_ method: String, _ params: Any, timeout: Duration?) async -> String {
        guard let session else { return #"{"error":{"message":"WindowNotFound;No automation session"}}"# }
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return #"{"error":{"message":"InvalidParameter;The parameters are not JSON"}}"#
        }
        return await withCheckedContinuation { continuation in
            waiting[id] = continuation
            session.perform(Self.dispatch, with: String(decoding: data, as: UTF8.self))
            guard let timeout else { return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.waiting.removeValue(forKey: id)?.resume(returning: #"{"error":{"message":"Timeout;No reply in \#(timeout)"}}"#)
            }
        }
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
        options = Options()
        guard session != nil else { return }
        if let browser { browser.closeTabs(browser.tabs.filter(\.isAutomated).map(\.id)) }
        pool?.perform(Self.attach, with: nil)
        waiting.values.forEach { $0.resume(returning: #"{"error":{"message":"WindowNotFound;Automation was switched off"}}"#) }
        waiting = [:]
        events = []
        session = nil
        pool = nil
        ownStore = .nonPersistent()
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
        waiting.values.forEach { $0.resume(returning: #"{"error":{"message":"UnexpectedAlertOpen;A JavaScript dialog opened before the reply; answer it, and the reply follows"}}"#) }
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
