#if os(macOS)
import AppKit
#endif
import Foundation
import Observation
import WebKit

/// One running MCP app: a tool's result drawn by the server's own HTML, in a window of the strip.
///
/// The session is the host end of the extension's protocol. It answers the app's `ui/initialize`,
/// tells it what the tool was called with and what came back, proxies the app's own `tools/call`
/// and `resources/read` down to the server it came from — and refuses everything else. An app is
/// somebody else's code: it gets the connection it was born on and no other.
@MainActor
@Observable
final class MCPAppSession: Identifiable {
    enum Status: Equatable {
        case loading
        case running
        case failed(String)
    }

    /// The revision of the extension six speaks, which is *not* the core protocol version the
    /// server and six agreed on — a server answering `2025-11-25` still carries `2026-01-26` apps.
    static let uiProtocolVersion = "2026-01-26"

    let id = UUID()
    let client: MCPClient
    let server: MCPServerDefinition
    let tool: MCPTool
    let resource: MCPUIResource
    let arguments: ACPJSON
    let url: URL

    private(set) var status: Status = .loading
    /// The app answered `ui/initialize` and said it was ready. Nothing is sent to it before this.
    private(set) var isReady = false
    private(set) var displayMode = "inline"
    /// What the app asked to be sized to (`ui/notifications/size-changed`). six draws it to fill the
    /// column either way; this is here for the day a column can size itself to its content.
    private(set) var requestedSize: CGSize?
    /// What the app logged (`notifications/message`), newest last, bounded.
    private(set) var log: [String] = []
    /// `ui/update-model-context`: what the app wants the model to know next turn. Overwritten, per
    /// the spec — the last update before the next user message is the one that counts.
    private(set) var modelContext: ACPJSON?
    /// The tool call this app is waiting to be allowed, drawn as a bar over the app's own column.
    private(set) var pendingToolRequest: ToolRequest?

    /// One `tools/call` from the app, suspended until somebody answers for it.
    ///
    /// Asked once per tool and then remembered for the life of the window. Asking every time is not
    /// caution, it is a modal dialog on a timer: an app that polls once a second would ask sixty
    /// times a minute, and the only thing a person learns from the sixtieth prompt is to stop
    /// reading them.
    struct ToolRequest: Identifiable {
        let id = UUID()
        let tool: MCPTool
        let arguments: ACPJSON
        let answer: (Bool) -> Void
    }

    /// The page showing the app, set by `BrowserTab` when it builds one.
    @ObservationIgnored weak var page: WebPage?
    /// A link the app asked six to open (`ui/open-link`). Set by `BrowserState`.
    @ObservationIgnored var onOpenLink: ((URL) -> Void)?
    /// Something the app wants said in the conversation (`ui/message`). Set by whoever owns the agent.
    @ObservationIgnored var onMessage: ((String) -> Void)?
    /// The window went away. Set by `MCPAppStore`, which forgets the session and may close the
    /// server with it.
    @ObservationIgnored var onClose: ((MCPAppSession) -> Void)?

    let contentController = WKUserContentController()
    private let handler = MCPAppMessageHandler()
    let schemeHandler: MCPAppSchemeHandler

    /// Outgoing requests six is waiting on — only `ui/resource-teardown` ever uses this, but a
    /// reply six asked for and then ignores is worse than not asking.
    private var pendingReplies: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextRequestID = 1
    /// Holds the page alive while the app answers a teardown. The window is already gone from the
    /// strip; this is the difference between "told it" and "gave it a moment".
    private var teardownHold: WebPage?
    private var allowedTools: Set<String> = []
    private var blockedTools: Set<String> = []
    /// The window is going. A question put up now is a question with nobody left to answer it.
    private var isClosing = false
    private var viewport: CGSize?
    private(set) var toolResult: ACPJSON?
    private var toolResultSent = false
    private var queued: [ACPJSON] = []

    var title: String { tool.display }

    /// What survives a relaunch: the question this window was, never the answer.
    var snapshot: AppWindowSnapshot {
        let arguments = (try? JSONEncoder().encode(self.arguments)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return AppWindowSnapshot(
            serverID: server.id,
            serverName: server.name,
            url: server.url,
            command: server.command,
            commandArguments: server.arguments,
            tool: tool.name,
            toolTitle: tool.display,
            toolArguments: arguments,
            resourceURI: resource.uri
        )
    }

    /// What an app window is, in words, for a model reading the strip (`get_page_content`).
    ///
    /// The app's own pixels are not readable: its document is in a frame of its own origin, and six
    /// deliberately injects nothing into it. What six *does* know is everything that went across the
    /// bridge — which tool, with what, what came back, and what the app has logged — and that is a
    /// better answer than the empty `innerText` of a shell.
    var summaryForModel: String {
        var lines = ["MCP app \(tool.name) from \(server.name) (\(resource.uri))"]
        if let description = tool.description, !description.isEmpty { lines.append(description) }
        lines.append("Called with: \(arguments.description)")
        let text = (toolResult?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        if !text.isEmpty { lines.append("Result:\n" + text.joined(separator: "\n")) }
        if let structured = toolResult?["structuredContent"] { lines.append("Structured result: \(structured.description)") }
        if case .failed(let message) = status { lines.append("Failed: \(message)") }
        if !log.isEmpty { lines.append("Logged:\n" + log.suffix(20).joined(separator: "\n")) }
        lines.append("The app draws this itself; the window is the answer.")
        return lines.joined(separator: "\n")
    }

    init(client: MCPClient, server: MCPServerDefinition, tool: MCPTool,
         resource: MCPUIResource, arguments: ACPJSON) {
        self.client = client
        self.server = server
        self.tool = tool
        self.resource = resource
        self.arguments = arguments
        schemeHandler = MCPAppSchemeHandler(resource: resource)
        url = MCPAppScheme.shellURL(host: MCPAppScheme.host(for: resource))
        handler.session = self
        contentController.add(handler, contentWorld: .page, name: MCPAppBridge.handlerName)
        contentController.addUserScript(WKUserScript(source: MCPAppBridge.source(host: MCPAppScheme.host(for: resource)),
                                                     injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: true,
                                                     in: .page))
    }

    // MARK: The tool call the app was opened for

    /// Runs the tool the app draws. Called once, as the window loads: the app initializes against a
    /// call that is already in flight, which is exactly the order the spec's diagram has.
    ///
    /// The raw `CallToolResult` comes back to the caller too, because when it was an *agent* that
    /// asked for this tool there is one call and two readers — the app draws it, the agent reads it.
    @discardableResult
    func callTool() async -> ACPJSON? {
        do {
            let result = try await client.callTool(tool.name, arguments: arguments)
            toolResult = result
            if status == .loading { status = .running }
            sendToolResultIfReady()
            return result
        } catch {
            status = .failed(error.localizedDescription)
            notify("ui/notifications/tool-cancelled", ["reason": .string(error.localizedDescription)])
            return nil
        }
    }

    /// The app's last `ui/update-model-context`, handed over once. Reading it clears it: an app that
    /// has said nothing new since the last turn adds nothing to this one.
    func takeModelContext() -> ACPJSON? {
        defer { modelContext = nil }
        return modelContext
    }

    /// Tells the app it is going and waits for it to say it is done — the spec asks a host to,
    /// because the alternative is taking the page away mid-save. Bounded: an app that does not
    /// answer costs a second, not the close.
    func teardown(reason: String) async {
        guard isReady, let page else { return }
        teardownHold = page
        defer { teardownHold = nil }
        let id = request("ui/resource-teardown", ["reason": .string(reason)])
        // The timer runs on this actor, so whichever of the two arrives first takes the
        // continuation out of the table and the other finds nothing to resume.
        let patience = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.pendingReplies.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { continuation in
            pendingReplies[id] = continuation
        }
        patience.cancel()
    }

    // MARK: What the app says

    /// One line from the shell: either six's own viewport report, or a JSON-RPC message the app sent.
    func receive(_ text: String) {
        guard let envelope = try? JSONDecoder().decode(ACPJSON.self, from: Data(text.utf8)) else { return }
        if let size = envelope["sixViewport"] {
            let width = size["width"]?.doubleValue ?? 0
            let height = size["height"]?.doubleValue ?? 0
            let measured = CGSize(width: width, height: height)
            guard measured != viewport, width > 0, height > 0 else { return }
            viewport = measured
            if isReady { notify("ui/notifications/host-context-changed", ["containerDimensions": dimensions]) }
            return
        }
        guard let message = envelope["sixMessage"] else { return }
        guard let method = message["method"]?.stringValue else {
            // No method: this is an answer to something six asked. Only teardown is ever asked.
            if let id = message["id"]?.intValue { pendingReplies.removeValue(forKey: id)?.resume() }
            return
        }
        if let id = message["id"], !id.isNull {
            Task { await answer(method: method, params: message["params"], id: id) }
        } else {
            handle(notification: method, params: message["params"])
        }
    }

    private func handle(notification method: String, params: ACPJSON?) {
        switch method {
        case "ui/notifications/initialized":
            isReady = true
            if status == .loading { status = .running }
            notify("ui/notifications/tool-input", ["arguments": arguments])
            sendToolResultIfReady()
            for message in queued { deliver(message) }
            queued = []
        case "ui/notifications/size-changed":
            let width = params?["width"]?.doubleValue ?? 0
            let height = params?["height"]?.doubleValue ?? 0
            if width > 0, height > 0 { requestedSize = CGSize(width: width, height: height) }
        case "notifications/message":
            let level = params?["level"]?.stringValue ?? "info"
            let text = params?["data"]?.description ?? ""
            log.append("[\(level)] \(text)")
            if log.count > 200 { log.removeFirst(log.count - 200) }
        default:
            break
        }
    }

    private func answer(method: String, params: ACPJSON?, id: ACPJSON) async {
        do {
            let result = try await result(for: method, params: params)
            deliver(.object(["jsonrpc": "2.0", "id": id, "result": result]))
        } catch let error as JSONRPCError {
            deliver(.object(["jsonrpc": "2.0", "id": id,
                             "error": ["code": .number(Double(error.code)), "message": .string(error.message)]]))
        } catch {
            deliver(.object(["jsonrpc": "2.0", "id": id,
                             "error": ["code": -32000, "message": .string(error.localizedDescription)]]))
        }
    }

    private func result(for method: String, params: ACPJSON?) async throws -> ACPJSON {
        switch method {
        case "ui/initialize":
            return initializeResult()

        case "ping":
            return [:]

        case "tools/call":
            guard let name = params?["name"]?.stringValue else { throw JSONRPCError.invalidParams("name") }
            // An app may call the tools of the server it came from, and only those the server marked
            // callable by an app. Everything else — another server's tools, a tool meant for the
            // model alone — is not a tool this app has.
            guard let called = await client.tool(named: name), called.visibility.contains(.app) else {
                throw JSONRPCError.invalidParams("\(name) is not callable by this app")
            }
            let arguments = params?["arguments"] ?? [:]
            guard await allows(called, arguments: arguments) else {
                throw JSONRPCError(code: -32000, message: "\(name) was refused by the user")
            }
            return try await client.callTool(name, arguments: arguments)

        case "resources/read":
            guard let uri = params?["uri"]?.stringValue else { throw JSONRPCError.invalidParams("uri") }
            return try await client.readResource(uri)

        case "ui/open-link":
            guard let text = params?["url"]?.stringValue, let link = URL(string: text),
                  let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { throw JSONRPCError.invalidParams("url") }
            onOpenLink?(link)
            return [:]

        case "ui/message":
            let text = params?["content"]?["text"]?.stringValue ?? ""
            guard !text.isEmpty else { throw JSONRPCError.invalidParams("content") }
            onMessage?(text)
            return [:]

        case "ui/update-model-context":
            modelContext = params
            return [:]

        case "ui/request-display-mode":
            // Only inline for now: a window of the strip is already the whole of a column, and
            // fullscreen is the strip's own gesture rather than the app's.
            return ["mode": .string(displayMode)]

        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    // MARK: Whether the app may

    /// Puts the question on the app's own window and suspends until it is answered — the same shape
    /// as a page asking for the camera (`SitePermissions`), and for the same reason: the app is one
    /// column of a strip, and stopping the whole browser to answer for it would be a mistake about
    /// what a window is.
    private func allows(_ tool: MCPTool, arguments: ACPJSON) async -> Bool {
        if allowedTools.contains(tool.name) { return true }
        if blockedTools.contains(tool.name) { return false }
        // Closing: what was already allowed still is — an app saving its work on the way out is the
        // whole reason six waits for it — and anything new is refused rather than asked about. The
        // bar would be drawn over a window that is no longer there, and the app would wait on an
        // answer nobody can give.
        if isClosing { return false }
        // One question at a time. A second call while the bar is up waits for the same answer.
        if pendingToolRequest != nil {
            while pendingToolRequest != nil { await Task.yield() }
            return allowedTools.contains(tool.name)
        }
        return await withCheckedContinuation { continuation in
            pendingToolRequest = ToolRequest(tool: tool, arguments: arguments) { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

    /// The answer, from the bar.
    func answerToolRequest(_ allowed: Bool) {
        guard let request = pendingToolRequest else { return }
        pendingToolRequest = nil
        if allowed { allowedTools.insert(request.tool.name) } else { blockedTools.insert(request.tool.name) }
        request.answer(allowed)
    }

    /// The window is closing. The app is told before its documents go, so it can stop what it was
    /// doing; six does not wait for the reply, because the page it would come back through is the
    /// one being taken away.
    func windowClosed() {
        isClosing = true
        answerToolRequest(false)
        Task {
            await teardown(reason: "window closed")
            onClose?(self)
        }
    }

    // MARK: What six says back

    private func initializeResult() -> ACPJSON {
        var context: [String: ACPJSON] = [
            "theme": .string(isDark ? "dark" : "light"),
            "styles": ["variables": MCPAppStyles.variables],
            "displayMode": .string(displayMode),
            "availableDisplayModes": ["inline"],
            "locale": .string(Locale.current.identifier(.bcp47)),
            "timeZone": .string(TimeZone.current.identifier),
            "userAgent": .string("six"),
            "platform": "desktop",
            "deviceCapabilities": ["touch": false, "hover": true],
            "toolInfo": ["tool": .object([
                "name": .string(tool.name),
                "description": .string(tool.description ?? ""),
                "inputSchema": tool.inputSchema ?? [:],
            ])],
        ]
        if viewport != nil { context["containerDimensions"] = dimensions }
        return [
            "protocolVersion": .string(Self.uiProtocolVersion),
            "hostInfo": ["name": "six", "version": "1.0"],
            "hostCapabilities": [
                "openLinks": [:],
                "serverTools": ["listChanged": false],
                "serverResources": ["listChanged": false],
                "logging": [:],
                "sandbox": .object([
                    "csp": .object([
                        "connectDomains": .array(resource.csp.connectDomains.map(ACPJSON.string)),
                        "resourceDomains": .array(resource.csp.resourceDomains.map(ACPJSON.string)),
                        "frameDomains": .array(resource.csp.frameDomains.map(ACPJSON.string)),
                        "baseUriDomains": .array(resource.csp.baseUriDomains.map(ACPJSON.string)),
                    ]),
                    // What the frame is *allowed* to ask for. Not what it will get: the camera is
                    // still the profile's question, asked of the app's origin when it is used. An
                    // app is told to feature-detect anyway, and this is why.
                    "permissions": grantedPermissions,
                ]),
            ],
            "hostContext": .object(context),
        ]
    }

    /// The Mac's appearance changed. An app that took six's palette is told the new one rather than
    /// left painted for the light it was opened in.
    func refreshTheme() {
        guard isReady else { return }
        notify("ui/notifications/host-context-changed", [
            "theme": .string(isDark ? "dark" : "light"),
            "styles": ["variables": MCPAppStyles.variables],
        ])
    }

    /// The permission-policy features six put on the app's frame, out of those it declared.
    private var grantedPermissions: ACPJSON {
        var granted: [String: ACPJSON] = [:]
        if resource.permissions.camera { granted["camera"] = [:] }
        if resource.permissions.microphone { granted["microphone"] = [:] }
        if resource.permissions.geolocation { granted["geolocation"] = [:] }
        if resource.permissions.clipboardWrite { granted["clipboardWrite"] = [:] }
        return .object(granted)
    }

    /// The column is a fixed viewport: the app fills it rather than growing inside it.
    private var dimensions: ACPJSON {
        guard let viewport else { return [:] }
        return ["width": .number(viewport.width), "height": .number(viewport.height)]
    }

    private var isDark: Bool {
        #if os(macOS)
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        #else
        false
        #endif
    }

    private func sendToolResultIfReady() {
        guard isReady, !toolResultSent, let toolResult else { return }
        toolResultSent = true
        notify("ui/notifications/tool-result", toolResult)
    }

    private func notify(_ method: String, _ params: ACPJSON) {
        deliver(.object(["jsonrpc": "2.0", "method": .string(method), "params": params]))
    }

    @discardableResult
    private func request(_ method: String, _ params: ACPJSON) -> Int {
        let id = nextRequestID
        nextRequestID += 1
        deliver(.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]))
        return id
    }

    /// Hands one message to the shell, which posts it into the app's frame. Before the app says it
    /// is initialized nothing goes out — the spec is explicit about that — so it waits here instead.
    private func deliver(_ message: ACPJSON) {
        let isHandshake = message["result"] != nil || message["error"] != nil
        guard isReady || isHandshake else {
            queued.append(message)
            return
        }
        guard let page, let data = try? JSONEncoder().encode(message) else { return }
        let text = String(decoding: data, as: UTF8.self)
        Task {
            _ = try? await page.callJavaScript(MCPAppBridge.deliverBody, arguments: ["text": text],
                                               contentWorld: .page)
        }
    }
}
