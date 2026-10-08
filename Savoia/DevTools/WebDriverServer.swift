#if os(macOS)
import Foundation
import Network
import WebKit

/// W3C WebDriver over HTTP on loopback, while Allow Remote Automation is on: each command becomes
/// one or more of WebKit's automation protocol, as safaridriver does for Safari. docs/devtools.md.
@MainActor
@Observable
final class WebDriverServer {
    @ObservationIgnored weak var browser: BrowserState?
    @ObservationIgnored private let automation: Automation
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var session: WebDriverSession?
    /// Where it listens, once it does.
    private(set) var port: UInt16?

    /// `SAVOIA_WEBDRIVER_PORT` names the port; without it the system picks one.
    private nonisolated static let wantedPort = ProcessInfo.processInfo.environment["SAVOIA_WEBDRIVER_PORT"].flatMap(UInt16.init) ?? 0

    init(automation: Automation) {
        self.automation = automation
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.wantedPort) ?? .any)
        guard let listener = try? NWListener(using: parameters) else {
            return Log.error(.devtools, "webdriver: no listener on port \(Self.wantedPort)")
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                connection.start(queue: .main)
                self?.read(connection, buffer: Data())
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue
                    Log.info(.devtools, "webdriver: listening on 127.0.0.1:\(self.port ?? 0)")
                case .failed(let error):
                    Log.error(.devtools, "webdriver: the listener failed, \(error)")
                    self.stop()
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        session = nil
    }

    // MARK: HTTP

    private func read(_ connection: NWConnection, buffer: Data) {
        do {
            if let (request, length) = try WebDriverRequest.parse(buffer) {
                let rest = Data(buffer.dropFirst(length))
                Task { [weak self] in
                    guard let self else { return connection.cancel() }
                    let response = await self.answer(request)
                    let keepAlive = request.keepsAlive && self.listener != nil
                    connection.send(content: response.encoded(keepAlive: keepAlive), completion: .contentProcessed { [weak self] _ in
                        MainActor.assumeIsolated {
                            if keepAlive { self?.read(connection, buffer: rest) } else { connection.cancel() }
                        }
                    })
                }
                return
            }
        } catch {
            let refusal = WebDriverResponse(WebDriverError("unknown error", "The request is not HTTP this server reads."))
            connection.send(content: refusal.encoded(keepAlive: false), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let data, !data.isEmpty, error == nil else { return connection.cancel() }
                if isComplete { return connection.cancel() }
                self.read(connection, buffer: buffer + data)
            }
        }
    }

    private func answer(_ request: WebDriverRequest) async -> WebDriverResponse {
        guard request.isFromLocalClient else {
            var refusal = WebDriverResponse(WebDriverError("unknown error", "Only a client on this Mac is answered."))
            refusal.status = 403
            return refusal
        }
        let path = request.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        var body: [String: Any] = [:]
        if !request.body.isEmpty {
            guard let read = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
                return WebDriverResponse(WebDriverError("invalid argument", "The body is not a JSON object."))
            }
            body = read
        }
        do {
            return WebDriverResponse(value: try await run(request.method, path, body))
        } catch let error as WebDriverError {
            if error.code != "script timeout" { Log.info(.devtools, "webdriver: \(request.method) \(request.path) — \(error.code) \(error.message)") }
            return WebDriverResponse(error)
        } catch {
            Log.info(.devtools, "webdriver: \(request.method) \(request.path) — \(error.localizedDescription)")
            return WebDriverResponse(WebDriverError("unknown error", error.localizedDescription))
        }
    }

    private func run(_ method: String, _ path: [String], _ body: [String: Any]) async throws -> Any? {
        switch (method, path.first, path.count) {
        case ("GET", "status", 1):
            return ["ready": session == nil, "message": session == nil ? "" : "A session is open; one at a time."]
        case ("POST", "session", 1):
            guard session == nil else { throw WebDriverError("session not created", "A session is open; one at a time.") }
            guard let browser else { throw WebDriverError("session not created", "No browser.") }
            let opened = WebDriverSession(automation: automation, browser: browser)
            session = opened
            do {
                return try await opened.begin(body)
            } catch {
                session = nil
                automation.end()
                throw error
            }
        case (_, "session", 2...):
            guard let session, session.id == path[1] else { throw WebDriverError("invalid session id") }
            if method == "DELETE", path.count == 2 {
                self.session = nil
                automation.end()
                return nil
            }
            return try await session.run(method, Array(path.dropFirst(2)), body)
        default:
            throw WebDriverError("unknown command", "\(method) /\(path.joined(separator: "/"))")
        }
    }
}

/// One WebDriver session: the window and frame it is in, its timeouts, and the commands.
@MainActor
private final class WebDriverSession {
    let id = UUID().uuidString
    private let automation: Automation
    private unowned let browser: BrowserState
    private var top: String?
    private var frame = ""
    private var nodeKey = "session-node-"
    private var scriptTimeout: Double? = 30_000
    private var pageLoadTimeout: Double = 300_000
    private var implicitTimeout: Double = 0
    private var pageLoadStrategy = "Normal"
    private var promptBehavior = "dismiss and notify"
    private var sources: [String: WebDriverInput.Source] = [:]

    private static let shadow = "shadow-6066-11e4-a52e-4f735466cecf"

    init(automation: Automation, browser: BrowserState) {
        self.automation = automation
        self.browser = browser
    }

    // MARK: The session

    func begin(_ body: [String: Any]) async throws -> [String: Any] {
        let asked = (body["capabilities"] as? [String: Any])?["alwaysMatch"] as? [String: Any] ?? [:]
        if asked["acceptInsecureCerts"] as? Bool == true {
            throw WebDriverError("session not created", "acceptInsecureCerts is not offered; trust the authority in Configuration.")
        }
        if let strategy = asked["pageLoadStrategy"] as? String { pageLoadStrategy = strategy.capitalized }
        if let behavior = asked["unhandledPromptBehavior"] as? String { promptBehavior = behavior }
        if let timeouts = asked["timeouts"] as? [String: Any] { try setTimeouts(timeouts) }
        // safaridriver's own capabilities, which Safari applies to its automation windows and Savoia to its tabs.
        let media = asked["webkit:WebRTC"] as? [String: Any] ?? [:]
        automation.options = .init(alwaysAllowsAutoplay: asked["webkit:alwaysAllowAutoplay"] as? Bool == true,
                                   allowsInsecureMediaCapture: media["DisableInsecureMediaCapture"] as? Bool == true,
                                   suppressesICECandidateFiltering: media["DisableICECandidateFiltering"] as? Bool == true)
        guard browser.openAutomationTab(url: nil) != nil else {
            throw WebDriverError("session not created", "Remote automation is not allowed.")
        }
        guard let handle = try await handles().first else { throw WebDriverError("session not created", "The tab did not open.") }
        try await settle(handle)
        try await switchTo(window: handle)
        // The key WebKit files a node under carries its session's name, which is not ours to choose.
        if let node = try? await evaluate("function() { return document.documentElement; }", raw: true) as? [String: Any],
           let key = node.keys.first(where: { $0.hasPrefix("session-node-") }) {
            nodeKey = key
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return ["sessionId": id, "capabilities": [
            "browserName": "Savoia", "browserVersion": version, "platformName": "mac", "acceptInsecureCerts": false,
            "pageLoadStrategy": pageLoadStrategy.lowercased(), "unhandledPromptBehavior": promptBehavior,
            "setWindowRect": false, "strictFileInteractability": false, "proxy": [String: Any](), "timeouts": timeouts,
            "webkit:alwaysAllowAutoplay": automation.options.alwaysAllowsAutoplay,
        ] as [String: Any]]
    }

    private var timeouts: [String: Any] {
        ["script": scriptTimeout ?? NSNull(), "pageLoad": pageLoadTimeout, "implicit": implicitTimeout]
    }

    private func setTimeouts(_ wanted: [String: Any]) throws {
        func read(_ key: String) throws -> Double? {
            guard let value = wanted[key], !(value is NSNull) else { return nil }
            guard let number = (value as? NSNumber)?.doubleValue, number >= 0 else {
                throw WebDriverError("invalid argument", "\(key) is a number of milliseconds.")
            }
            return number
        }
        if wanted["script"] != nil { scriptTimeout = try read("script") }
        if let pageLoad = try read("pageLoad") { pageLoadTimeout = pageLoad }
        if let implicit = try read("implicit") { implicitTimeout = implicit }
    }

    // MARK: The commands

    func run(_ method: String, _ path: [String], _ body: [String: Any]) async throws -> Any? {
        let command = ([method] + path.prefix(1) + (path.count > 1 ? ["*"] + path.dropFirst(2) : [])).joined(separator: " ")
        switch (method, path.first ?? "", path.count) {
        case ("GET", "timeouts", 1): return timeouts
        case ("POST", "timeouts", 1): try setTimeouts(body); return nil

        case ("GET", "window", 1): return try window()
        case ("POST", "window", 1):
            guard let handle = body["handle"] as? String else { throw WebDriverError("invalid argument", "handle is required.") }
            try await switchTo(window: handle)
            return nil
        case ("DELETE", "window", 1):
            try await prompts()
            let closing = try window()
            top = nil
            frame = ""
            return try await close(closing)
        case ("GET", "window", 2) where path[1] == "handles": return try await handles()
        case ("POST", "window", 2) where path[1] == "new":
            try await prompts()
            let hint = body["type"] as? String == "window" ? "Window" : "Tab"
            let made = try await automation.command("createBrowsingContext", ["presentationHint": hint])
            guard let handle = made["handle"] as? String else { throw WebDriverError("unknown error", "No handle for the new tab.") }
            try await settle(handle)
            return ["handle": handle, "type": "tab"]
        case ("GET", "window", 2) where path[1] == "rect": return try await rect()
        // The window is the person's: these answer with where it is, and nothing moves.
        case ("POST", "window", 2) where ["rect", "maximize", "minimize", "fullscreen"].contains(path[1]): return try await rect()

        case ("POST", "url", 1):
            guard let url = body["url"] as? String else { throw WebDriverError("invalid argument", "url is required.") }
            try await prompts()
            frame = ""
            return try await navigate("navigateBrowsingContext", ["url": url])
        case ("GET", "url", 1):
            try await prompts()
            return try await context()["url"]
        case ("POST", "back", 1): try await prompts(); frame = ""; return try await navigate("goBackInBrowsingContext")
        case ("POST", "forward", 1): try await prompts(); frame = ""; return try await navigate("goForwardInBrowsingContext")
        case ("POST", "refresh", 1): try await prompts(); frame = ""; return try await navigate("reloadBrowsingContext")
        case ("GET", "title", 1):
            try await prompts()
            return try await evaluate("function() { return document.title; }", inFrame: "")
        case ("GET", "source", 1):
            try await prompts()
            return try await evaluate("function() { return document.documentElement.outerHTML; }")

        case ("POST", "frame", 1): try await switchTo(frame: body["id"]); return nil
        case ("POST", "frame", 2) where path[1] == "parent":
            try await prompts()
            guard !frame.isEmpty else { return nil }
            let parent = try await automation.command("resolveParentFrameHandle", ["browsingContextHandle": try window(), "frameHandle": frame])
            frame = parent["result"] as? String ?? ""
            _ = try await automation.command("switchToBrowsingContext", ["browsingContextHandle": try window(), "frameHandle": frame])
            return nil

        case ("POST", "execute", 2) where path[1] == "sync" || path[1] == "async":
            guard let script = body["script"] as? String, let arguments = body["args"] as? [Any] else {
                throw WebDriverError("invalid argument", "script and args are required.")
            }
            try await prompts()
            do {
                return try await evaluate(Self.script(script, callback: path[1] == "async"), arguments, callback: path[1] == "async",
                                          timeout: scriptTimeout)
            } catch let error as WebDriverError where error.code == "unexpected alert open" {
                // A dialog the script itself raised: the script's answer is null, and the dialog is the next command's.
                return nil
            }

        case ("POST", "element", 1), ("POST", "elements", 1):
            return try await find(body, from: nil, all: path[0] == "elements")
        case ("GET", "element", 2) where path[1] == "active":
            try await prompts()
            guard let found = try await evaluate("function() { return document.activeElement; }") else { throw WebDriverError("no such element") }
            return found
        case (_, "element", 3...): return try await element(method, path[1], Array(path.dropFirst(2)), body)
        case ("POST", "shadow", 3) where path[2] == "element" || path[2] == "elements":
            return try await find(body, from: path[1], all: path[2] == "elements")

        case ("GET", "cookie", 1): return try await cookies()
        case ("GET", "cookie", 2):
            guard let cookie = try await cookies().first(where: { $0["name"] as? String == path[1] }) else { throw WebDriverError("no such cookie") }
            return cookie
        case ("POST", "cookie", 1):
            guard let cookie = body["cookie"] as? [String: Any], let name = cookie["name"] as? String, let value = cookie["value"] as? String else {
                throw WebDriverError("invalid argument", "cookie needs a name and a value.")
            }
            try await prompts()
            let expiry = (cookie["expiry"] as? NSNumber)?.doubleValue
            let added: [String: Any] = [
                "name": name, "value": value, "path": cookie["path"] as? String ?? "/", "domain": cookie["domain"] as? String ?? "",
                "secure": cookie["secure"] as? Bool ?? false, "httpOnly": cookie["httpOnly"] as? Bool ?? false,
                "session": expiry == nil, "expires": expiry ?? 0, "size": name.utf8.count + value.utf8.count,
                "sameSite": cookie["sameSite"] as? String ?? "Lax",
            ]
            _ = try await automation.command("addSingleCookie", ["browsingContextHandle": try window(), "cookie": added])
            return nil
        case ("DELETE", "cookie", 1):
            try await prompts()
            _ = try await automation.command("deleteAllCookies", ["browsingContextHandle": try window()])
            return nil
        case ("DELETE", "cookie", 2):
            try await prompts()
            _ = try await automation.command("deleteSingleCookie", ["browsingContextHandle": try window(), "cookieName": path[1]])
            return nil

        case ("POST", "actions", 1):
            guard let actions = body["actions"] as? [[String: Any]] else { throw WebDriverError("invalid argument", "actions is required.") }
            try await prompts()
            let sequence = try WebDriverInput.sequence(actions, sources: &sources)
            guard !sequence.steps.isEmpty else { return nil }
            _ = try await automation.command("performInteractionSequence", [
                "handle": try window(), "frameHandle": frame, "inputSources": sequence.inputSources, "steps": sequence.steps,
            ], timeout: nil)
            return nil
        case ("DELETE", "actions", 1):
            sources = [:]
            _ = try await automation.command("cancelInteractionSequence", ["handle": try window(), "frameHandle": frame])
            return nil

        case ("POST", "alert", 2) where path[1] == "dismiss" || path[1] == "accept":
            let name = path[1] == "dismiss" ? "dismissCurrentJavaScriptDialog" : "acceptCurrentJavaScriptDialog"
            _ = try await automation.command(name, ["browsingContextHandle": try window()])
            return nil
        case ("GET", "alert", 2) where path[1] == "text":
            return try await automation.command("messageOfCurrentJavaScriptDialog", ["browsingContextHandle": try window()])["message"]
        case ("POST", "alert", 2) where path[1] == "text":
            guard let text = body["text"] as? String else { throw WebDriverError("invalid argument", "text is required.") }
            _ = try await automation.command("setUserInputForCurrentJavaScriptPrompt", ["browsingContextHandle": try window(), "userInput": text])
            return nil

        case ("GET", "screenshot", 1):
            try await prompts()
            return try await automation.command("takeScreenshot", ["handle": try window(), "clipToViewport": true])["data"]

        case ("POST", "permissions", 1):
            try await setPermission(body, origin: nil)
            return nil
        case ("POST", "storageaccess", 1):
            guard let blocked = body["blocked"] as? Bool else { throw WebDriverError("invalid argument", "blocked is required.") }
            _ = try await automation.command("setStorageAccessPolicy", ["browsingContextHandle": try window(), "blocked": blocked])
            return nil
        case ("POST", "reporting", 2) where path[1] == "generate_test_report":
            guard let message = body["message"] as? String else { throw WebDriverError("invalid argument", "message is required.") }
            _ = try await automation.command("generateTestReport", ["browsingContextHandle": try window(), "message": message,
                                                                    "group": body["group"] as? String ?? "default"])
            return nil

        // Savoia's own, for what the protocol and classic WebDriver have no command for.
        case ("POST", "savoia", 2) where path[1] == "permissions":
            try await setPermission(body, origin: body["origin"] as? String)
            return nil
        case ("POST", "savoia", 2) where path[1] == "geolocation":
            try answering { try TestDriver.setGeolocation(coordinates: body["coordinates"] as? [String: Any], unavailable: body["error"] != nil) }
            return nil
        case ("POST", "savoia", 2) where path[1] == "reset":
            TestDriver.reset(browser)
            return nil

        default:
            throw WebDriverError("unknown command", command)
        }
    }

    // MARK: Windows and frames

    private func window() throws -> String {
        guard let top else { throw WebDriverError("no such window") }
        return top
    }

    private func handles() async throws -> [String] {
        let contexts = try await automation.command("getBrowsingContexts")["contexts"] as? [[String: Any]] ?? []
        return contexts.compactMap { $0["handle"] as? String }
    }

    /// Close Window answers with the handles left, so it waits for the tab to be gone.
    private func close(_ handle: String) async throws -> [String] {
        // Weakly, and the tab by its id: a view held here is a browsing context still listed.
        let tab = try? await tab()
        weak let view = tab?.livePage
        let id = tab?.id
        _ = try await automation.command("closeBrowsingContext", ["handle": handle])
        for attempt in 0..<40 {
            let left = try await handles()
            guard left.contains(handle) else { return left }
            // A page with something to say on unload keeps its tab, and a page that captures keeps its view.
            if attempt == 10 {
                Log.info(.devtools, "webdriver: \(handle) stayed open after the protocol closed it; closing its tab and its page")
                if let id, browser.tab(id) != nil { browser.closeTabs([id]) }
                view?.perform(NSSelectorFromString("_close"))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try await handles()
    }

    /// A new tab is still loading its blank page, and a navigation asked for now would be answered by that load ending.
    private func settle(_ handle: String) async throws {
        _ = try await automation.command("waitForNavigationToComplete", ["browsingContextHandle": handle, "pageLoadStrategy": "Normal",
                                                                         "pageLoadTimeout": pageLoadTimeout])
    }

    private func context() async throws -> [String: Any] {
        try await automation.command("getBrowsingContext", ["handle": try window()])["context"] as? [String: Any] ?? [:]
    }

    private func switchTo(window handle: String) async throws {
        _ = try await automation.command("switchToBrowsingContext", ["browsingContextHandle": handle])
        top = handle
        frame = ""
    }

    private func switchTo(frame wanted: Any?) async throws {
        guard let wanted, !(wanted is NSNull) else {
            _ = try await automation.command("switchToBrowsingContext", ["browsingContextHandle": try window()])
            frame = ""
            return
        }
        try await prompts()
        var parameters: [String: Any] = ["browsingContextHandle": try window(), "frameHandle": frame]
        if let node = (wanted as? [String: Any])?[WebDriverInput.element] as? String {
            parameters["nodeHandle"] = node
        } else if let ordinal = (wanted as? NSNumber)?.intValue, ordinal >= 0, ordinal <= Int(UInt16.max) {
            parameters["ordinal"] = ordinal
        } else {
            throw WebDriverError("invalid argument", "A frame is an index, an element or null.")
        }
        guard let child = try await automation.command("resolveChildFrameHandle", parameters)["result"] as? String else {
            throw WebDriverError("no such frame")
        }
        _ = try await automation.command("switchToBrowsingContext", ["browsingContextHandle": try window(), "frameHandle": child])
        frame = child
    }

    private func rect() async throws -> [String: Any] {
        let context = try await context()
        let origin = context["windowOrigin"] as? [String: Any] ?? [:], size = context["windowSize"] as? [String: Any] ?? [:]
        return ["x": origin["x"] ?? 0, "y": origin["y"] ?? 0, "width": size["width"] ?? 0, "height": size["height"] ?? 0]
    }

    private func navigate(_ name: String, _ more: [String: Any] = [:]) async throws -> Any? {
        var parameters: [String: Any] = ["handle": try window(), "pageLoadStrategy": pageLoadStrategy, "pageLoadTimeout": pageLoadTimeout]
        parameters.merge(more) { $1 }
        _ = try await automation.command(name, parameters, timeout: .milliseconds(Int(pageLoadTimeout) + 5_000))
        return nil
    }

    /// A dialog nobody answered, dealt with as the session was told to, before a command that is not about it.
    private func prompts() async throws {
        let handle = try window()
        guard try await automation.command("isShowingJavaScriptDialog", ["browsingContextHandle": handle])["result"] as? Bool == true else { return }
        let text = try? await automation.command("messageOfCurrentJavaScriptDialog", ["browsingContextHandle": handle])["message"] as? String
        if promptBehavior != "ignore" {
            let accepts = promptBehavior.hasPrefix("accept")
            _ = try await automation.command(accepts ? "acceptCurrentJavaScriptDialog" : "dismissCurrentJavaScriptDialog", ["browsingContextHandle": handle])
            if !promptBehavior.hasSuffix("notify") { return }
        }
        throw WebDriverError("unexpected alert open", data: text.map { ["text": $0] })
    }

    // MARK: Scripts

    /// A function of the page's, with WebDriver's element references turned into the protocol's and back.
    private func evaluate(_ function: String, _ arguments: [Any] = [], callback: Bool = false, timeout: Double? = nil,
                          inFrame: String? = nil, raw: Bool = false) async throws -> Any? {
        var parameters: [String: Any] = [
            "browsingContextHandle": try window(), "frameHandle": inFrame ?? frame, "function": function,
            "arguments": try arguments.map { argument in
                String(decoding: try JSONSerialization.data(withJSONObject: outgoing(argument), options: [.fragmentsAllowed]), as: UTF8.self)
            },
        ]
        if callback { parameters["expectsImplicitCallbackArgument"] = true }
        if let timeout { parameters["callbackTimeout"] = timeout }
        let reply = try await automation.command("evaluateJavaScriptFunction", parameters, timeout: nil)
        guard let text = reply["result"] as? String, !text.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else { return nil }
        return raw ? value : incoming(value)
    }

    private static let window = "window-fcc6-11e5-b4f8-330a88ab9d7f"
    private static let frameKey = "frame-075b-4da1-b6ba-e579c2d3230a"

    /// The client's script, with a window in its answer written as WebDriver writes one: the protocol
    /// serializes a window as the cyclic object it is, and fails.
    private static func script(_ body: String, callback: Bool) -> String {
        let named = """
            const named = (value, seen) => {
                if (value === null || typeof value !== 'object' || seen.has(value)) return value;
                try { if (value.window === value) return value === value.top ? {'\(window)': ''} : {'\(frameKey)': ''}; } catch (error) { }
                const plain = Object.getPrototypeOf(value);
                if (!Array.isArray(value) && plain !== Object.prototype && plain !== null) return value;
                seen.add(value);
                const copy = Array.isArray(value) ? value.map(item => named(item, seen))
                    : Object.fromEntries(Object.entries(value).map(([key, item]) => [key, named(item, seen)]));
                seen.delete(value);
                return copy;
            };
            """
        let run = "(function(){\n\(body)\n})"
        if callback {
            return "function() { \(named) const given = [...arguments], done = given.pop(); "
                + "return \(run).apply(window, [...given, value => done(named(value, new Set()))]); }"
        }
        return "function() { \(named) const answer = \(run).apply(window, arguments); "
            + "return answer instanceof Promise ? answer.then(value => named(value, new Set())) : named(answer, new Set()); }"
    }

    private func outgoing(_ value: Any) -> Any {
        if let list = value as? [Any] { return list.map(outgoing) }
        guard let object = value as? [String: Any] else { return value }
        if let node = object[WebDriverInput.element] ?? object[Self.shadow] { return [nodeKey: node] }
        return object.mapValues(outgoing)
    }

    private func incoming(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let list = value as? [Any] { return list.map { incoming($0) ?? NSNull() } }
        guard let object = value as? [String: Any] else { return value }
        if object.count == 1, let node = object[nodeKey] { return [WebDriverInput.element: node] }
        return object.mapValues { incoming($0) ?? NSNull() }
    }

    // MARK: Elements

    private static let finder = """
        function(strategy, root, query, all, patience, done) {
            root = root || document;
            const until = performance.now() + patience;
            function look() {
                try {
                    switch (strategy) {
                    case 'css selector': return [...root.querySelectorAll(query)];
                    case 'tag name': return [...root.getElementsByTagName(query)];
                    case 'link text': return [...root.querySelectorAll('a')].filter(a => a.innerText.trim() === query);
                    case 'partial link text': return [...root.querySelectorAll('a')].filter(a => a.innerText.includes(query));
                    case 'xpath': {
                        const found = document.evaluate(query, root, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
                        return Array.from({length: found.snapshotLength}, (_, index) => found.snapshotItem(index));
                    }
                    }
                } catch (error) {
                    throw {name: 'InvalidSelector', message: error.message};
                }
                throw {name: 'InvalidParameter', message: 'Unsupported locator strategy: ' + strategy};
            }
            (function poll() {
                const found = look();
                if (found.length || performance.now() >= until) return done(all ? found : found[0] || null);
                setTimeout(poll, 50);
            })();
        }
        """

    private func find(_ body: [String: Any], from root: String?, all: Bool) async throws -> Any? {
        guard let strategy = body["using"] as? String, let query = body["value"] as? String else {
            throw WebDriverError("invalid argument", "using and value are required.")
        }
        try await prompts()
        let start: Any = root.map { [WebDriverInput.element: $0] } ?? NSNull()
        let found = try await evaluate(Self.finder, [strategy, start, query, all, implicitTimeout], callback: true,
                                       timeout: implicitTimeout + 1_000)
        if all { return found ?? [Any]() }
        guard let found else { throw WebDriverError("no such element") }
        return found
    }

    private static let reads: [String: String] = [
        "text": "function(e) { return e.innerText ?? e.textContent; }",
        "name": "function(e) { return e.localName; }",
        "selected": "function(e) { return !!(e.localName === 'option' ? e.selected : e.checked); }",
        "enabled": "function(e) { return !e.matches(':disabled'); }",
        "displayed": "function(e) { return e.checkVisibility ? e.checkVisibility({visibilityProperty: true, opacityProperty: true}) : !!e.getClientRects().length; }",
        "attribute": "function(e, name) { const value = e.getAttribute(name); return value === '' && typeof e[name] === 'boolean' ? 'true' : value; }",
        "property": "function(e, name) { return e[name]; }",
        "css": "function(e, name) { return getComputedStyle(e).getPropertyValue(name); }",
    ]

    private func element(_ method: String, _ id: String, _ rest: [String], _ body: [String: Any]) async throws -> Any? {
        let node: [String: Any] = [WebDriverInput.element: id]
        var place: [String: Any] { ["browsingContextHandle": top ?? "", "frameHandle": frame, "nodeHandle": id] }
        switch (method, rest[0]) {
        case ("POST", "element"), ("POST", "elements"):
            return try await find(body, from: id, all: rest[0] == "elements")
        case ("GET", let read) where Self.reads[read] != nil && rest.count <= 2:
            try await prompts()
            return try await evaluate(Self.reads[read] ?? "", [node as Any] + rest.dropFirst().map { $0 as Any })
        case ("GET", "rect"):
            try await prompts()
            let layout = try await automation.command("computeElementLayout", place.merging(["coordinateSystem": "Page"]) { $1 })
            let rect = layout["rect"] as? [String: Any] ?? [:]
            let origin = rect["origin"] as? [String: Any] ?? [:], size = rect["size"] as? [String: Any] ?? [:]
            return ["x": origin["x"] ?? 0, "y": origin["y"] ?? 0, "width": size["width"] ?? 0, "height": size["height"] ?? 0]
        case ("GET", "computedrole"):
            try await prompts()
            return try await automation.command("getComputedRole", place)["role"]
        case ("GET", "computedlabel"):
            try await prompts()
            return try await automation.command("getComputedLabel", place)["label"]
        case ("GET", "shadow"):
            try await prompts()
            guard let root = try await evaluate("function(e) { return e.shadowRoot; }", [node]) as? [String: Any],
                  let handle = root[WebDriverInput.element] else { throw WebDriverError("no such shadow root") }
            return [Self.shadow: handle]
        case ("GET", "screenshot"):
            try await prompts()
            return try await automation.command("takeScreenshot", ["handle": try window(), "frameHandle": frame, "nodeHandle": id,
                                                                    "scrollIntoViewIfNeeded": true, "clipToViewport": true])["data"]
        case ("POST", "click"):
            try await click(id, node)
            return nil
        case ("POST", "clear"):
            try await prompts()
            _ = try await evaluate("""
                function(e) {
                    if (e.isContentEditable) { e.focus(); e.textContent = ''; e.blur(); return; }
                    if (!('value' in e) || e.disabled || e.readOnly) throw {name: 'InvalidElementState', message: 'The element cannot be cleared.'};
                    e.focus(); e.value = ''; e.dispatchEvent(new Event('input', {bubbles: true}));
                    e.dispatchEvent(new Event('change', {bubbles: true})); e.blur();
                }
                """, [node])
            return nil
        case ("POST", "value"):
            guard let text = body["text"] as? String else { throw WebDriverError("invalid argument", "text is required.") }
            try await type(text, into: id, node)
            return nil
        default:
            throw WebDriverError("unknown command", "\(method) element * \(rest.joined(separator: " "))")
        }
    }

    private func isFileInput(_ node: [String: Any]) async throws -> Bool {
        try await evaluate("function(e) { return e.localName === 'input' && e.type === 'file'; }", [node]) as? Bool == true
    }

    private func click(_ id: String, _ node: [String: Any]) async throws {
        try await prompts()
        if try await isFileInput(node) { throw WebDriverError("invalid argument", "A file input is given its files with Send Keys.") }
        let handle = try window()
        let layout = try await automation.command("computeElementLayout", [
            "browsingContextHandle": handle, "frameHandle": frame, "nodeHandle": id, "scrollIntoViewIfNeeded": true,
            "coordinateSystem": "LayoutViewport",
        ])
        if layout["isObscured"] as? Bool == true { throw WebDriverError("element click intercepted") }
        guard let centre = layout["inViewCenterPoint"] as? [String: Any] else { throw WebDriverError("element not interactable") }
        if try await evaluate(Self.reads["name"] ?? "", [node]) as? String == "option" {
            _ = try await automation.command("selectOptionElement", ["browsingContextHandle": handle, "frameHandle": frame, "nodeHandle": id])
        } else {
            // Down and then Up: the protocol's SingleClick sends two downs and no up on this WebKit.
            for interaction in ["Down", "Up"] {
                _ = try await automation.command("performMouseInteraction", [
                    "handle": handle, "position": centre, "button": "Left", "interaction": interaction, "modifiers": [String](),
                ], timeout: .seconds(5))
            }
        }
        _ = try await automation.command("waitForNavigationToComplete", [
            "browsingContextHandle": handle, "frameHandle": frame, "pageLoadStrategy": pageLoadStrategy, "pageLoadTimeout": pageLoadTimeout,
        ], timeout: .milliseconds(Int(pageLoadTimeout) + 5_000))
    }

    private func type(_ text: String, into id: String, _ node: [String: Any]) async throws {
        try await prompts()
        let handle = try window()
        if try await isFileInput(node) {
            _ = try await automation.command("setFilesForInputFileUpload", [
                "browsingContextHandle": handle, "frameHandle": frame, "nodeHandle": id, "filenames": text.components(separatedBy: "\n"),
            ])
            return
        }
        _ = try await evaluate("""
            function(e) {
                const root = e.getRootNode(), before = (e.ownerDocument || e).activeElement;
                if (root.activeElement !== e && before) before.blur();
                e.focus();
                if (e.localName === 'body' || e === document.documentElement) return;
                const isText = e.localName === 'textarea' || (e.localName === 'input' && e.type === 'text');
                if (isText && e.selectionEnd == 0) e.setSelectionRange(e.value.length, e.value.length);
                if (root.activeElement !== e) throw {name: 'ElementNotInteractable', message: 'Element is not focusable.'};
            }
            """, [node])
        _ = try await automation.command("performKeyboardInteractions", ["handle": handle, "interactions": WebDriverInput.typing(text)], timeout: nil)
    }

    // MARK: What the protocol cannot do, and Savoia can

    private func cookies() async throws -> [[String: Any]] {
        try await prompts()
        let all = try await automation.command("getAllCookies", ["browsingContextHandle": try window()])["cookies"] as? [[String: Any]] ?? []
        return all.map { cookie in
            var told = cookie.filter { ["name", "value", "path", "domain", "secure", "httpOnly", "sameSite"].contains($0.key) }
            if cookie["session"] as? Bool != true, let expires = (cookie["expires"] as? NSNumber)?.intValue { told["expiry"] = expires }
            return told
        }
    }

    /// The tab the session's window is: the protocol's handle names no view, so the page is marked and looked for.
    private func tab() async throws -> BrowserTab {
        let token = "savoia" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = try await evaluate("function(token) { self[token] = true; }", [token], inFrame: "")
        for tab in browser.tabs where tab.isAutomated {
            let found = try? await tab.livePage?.callWithoutGesture("return delete self[token] && true;", arguments: ["token": token], in: .page)
            if found as? Bool == true { return tab }
        }
        throw WebDriverError("no such window")
    }

    /// Set Permission, for the origin of the frame the session is in, or for the one named.
    private func setPermission(_ body: [String: Any], origin named: String?) async throws {
        guard let name = (body["descriptor"] as? [String: Any])?["name"] as? String, let state = body["state"] as? String else {
            throw WebDriverError("invalid argument", "descriptor.name and state are required.")
        }
        // WebKit keeps this one itself, per frame, and the protocol has the command safaridriver sends.
        if name == "storage-access", named == nil {
            _ = try await automation.command("setStorageAccessPermissionState", ["browsingContextHandle": try window(), "frameHandle": frame,
                                                                                 "state": state])
            return
        }
        let tab = try await tab()
        // The protocol lets a page capture without asking anyone; the answer goes there too.
        if ["camera", "microphone"].contains(name) {
            _ = try await automation.command("setSessionPermissions", ["permissions": [["permission": "GetUserMedia", "value": state == "granted"]]])
        }
        let ask = "function() { return location.origin; }"
        let top = try await evaluate(ask, inFrame: "") as? String
        let origin: String? = if let named { named } else { try await evaluate(ask) as? String }
        try await answering { try await TestDriver.setPermission(name, to: state, origin: origin, top: top, tab: tab, browser: browser) }
    }

    private func answering(_ work: () async throws -> Void) async throws {
        do {
            try await work()
        } catch let failure as BrowserTool.Failure {
            throw WebDriverError("invalid argument", failure.message)
        }
    }

    private func answering(_ work: () throws -> Void) throws {
        do {
            try work()
        } catch let failure as BrowserTool.Failure {
            throw WebDriverError("invalid argument", failure.message)
        }
    }
}
#endif
