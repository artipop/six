import Foundation

/// One frame of a page, as a front reaches it: somewhere to run a function body, in the page's own
/// world or in six's. `origin` is the frame's real origin as the engine reports it, never the
/// page's word.
@MainActor
protocol WebMCPFrame: AnyObject {
    var origin: String { get }
    func run(_ body: String, isolated: Bool) async throws -> String
}

/// The page-side half of WebMCP across frames: what each document of a window registered, which of
/// them a given document may see (`exposedTo`, `fromOrigins`), whether a frame may use the API at
/// all (the `tools` permissions policy), and calls from one frame's `executeTool` to another
/// frame's tool. The browser is the only party that sees every frame, so the broker is six.
///
/// A front that has it answers every message of the polyfill (`WebMCPHost.request`); a front
/// without it never sends the messages that need it, and the polyfill keeps to its own document.
@MainActor
final class WebMCPBroker {
    struct Tool {
        var tool: WebMCPTool
        var exposedTo: [String]
        /// The schema and annotations as the page wrote them — JSON text, so key order survives —
        /// for another frame's `getTools()`.
        var page: String
    }

    @MainActor
    final class Document {
        let token: String
        let frame: any WebMCPFrame
        let path: [Int]
        var tools: [String: Tool] = [:]
        var allowed: Bool?

        init(token: String, frame: any WebMCPFrame, path: [Int]) {
            self.token = token
            self.frame = frame
            self.path = path
        }

        var origin: String { frame.origin }
        var isMain: Bool { path.isEmpty }
    }

    private struct Call {
        let windowID: UUID
        let caller: String
        let target: String
        let reply: (String) -> Void
    }

    private var windows: [UUID: [String: Document]] = [:]
    private var calls: [String: Call] = [:]

    // MARK: Messages

    func receive(_ json: ACPJSON, from windowID: UUID, frame: any WebMCPFrame, reply: @escaping (String) -> Void) {
        guard let token = json["doc"]?.stringValue, !token.isEmpty else { return reply(Self.error("SyntaxError", "no document")) }
        switch json["kind"]?.stringValue {
        case "document":
            let path = json["path"]?.arrayValue?.compactMap { $0.intValue } ?? []
            arrive(token, path: path, frame: frame, in: windowID)
            reply("{}")
        case "register":
            guard let document = windows[windowID]?[token] else {
                return reply(Self.error("InvalidStateError", "the document is not known"))
            }
            // A tool six cannot describe to an agent is still the page's to register.
            guard let tool = WebMCPMessage.parse(Self.text(json)).flatMap({ message -> WebMCPTool? in
                if case .register(_, let tool) = message { return tool } else { return nil }
            }) else { return reply("{}") }
            var registered = tool
            registered.origin = document.origin
            let exposedTo = json["exposedTo"]?.arrayValue?.compactMap(\.stringValue) ?? []
            Task { [weak self] in
                guard let self else { return }
                guard await allowed(document, in: windowID) else {
                    return reply(Self.error("NotAllowedError", "the tools permissions policy does not allow this frame"))
                }
                guard windows[windowID]?[token] === document else {
                    return reply(Self.error("InvalidStateError", "the document has gone"))
                }
                document.tools[registered.name] = Tool(tool: registered, exposedTo: exposedTo, page: json["page"]?.stringValue ?? "{}")
                reply("{}")
                changed(document, exposedTo: exposedTo, in: windowID)
            }
        case "unregister":
            guard let name = json["name"]?.stringValue, let document = windows[windowID]?[token],
                  let removed = document.tools.removeValue(forKey: name)
            else { return reply("{}") }
            reply("{}")
            changed(document, exposedTo: removed.exposedTo, in: windowID)
        case "getTools":
            guard let document = windows[windowID]?[token] else { return reply(#"{"tools":[]}"#) }
            let from = json["fromOrigins"]?.arrayValue?.compactMap(\.stringValue) ?? []
            Task { [weak self] in
                guard let self else { return }
                guard await allowed(document, in: windowID) else {
                    return reply(Self.error("NotAllowedError", "the tools permissions policy does not allow this frame"))
                }
                let tools = visible(to: document, in: windowID)
                    .filter { $0.owner.origin == document.origin || from.contains($0.owner.origin) }
                    .map { entry -> ACPJSON in
                        var json = entry.tool.tool.json
                        if case .object(var object) = json {
                            object["origin"] = .string(entry.owner.origin)
                            object["doc"] = .string(entry.owner.token)
                            object["path"] = .array(entry.owner.path.map { .number(Double($0)) })
                            object["page"] = .string(entry.tool.page)
                            json = .object(object)
                        }
                        return json
                    }
                reply(Self.encode(["tools": .array(tools)]))
            }
        case "execute":
            guard let caller = windows[windowID]?[token], let call = json["call"]?.stringValue,
                  let name = json["name"]?.stringValue
            else { return reply(Self.error("UnknownError", "the call could not be read")) }
            let targetToken = json["target"]?.stringValue
            let origin = json["origin"]?.stringValue
            let input = json["input"]?.stringValue ?? "{}"
            Task { [weak self] in
                guard let self else { return }
                guard await allowed(caller, in: windowID) else {
                    return reply(Self.error("NotAllowedError", "the tools permissions policy does not allow this frame"))
                }
                let candidates = visible(to: caller, in: windowID).filter { $0.tool.tool.name == name }
                guard let target = candidates.first(where: { $0.owner.token == targetToken })
                        ?? candidates.first(where: { $0.owner.origin == origin && targetToken == nil })
                else { return reply(Self.error("UnknownError", "no tool named \(name) is visible to this document")) }
                calls[call] = Call(windowID: windowID, caller: caller.token, target: target.owner.token, reply: reply)
                do {
                    _ = try await target.owner.frame.run(WebMCPScript.startBody(call: call, tool: name, input: input),
                                                         isolated: false)
                } catch {
                    gone(target.owner.token, in: windowID)
                }
            }
        case "cancel":
            guard let call = json["call"]?.stringValue, let entry = calls[call], entry.caller == token else { return reply("{}") }
            calls[call] = nil
            reply("{}")
            let reason = json["reason"]?.stringValue ?? "cancelled"
            if let target = windows[entry.windowID]?[entry.target] {
                Task { _ = try? await target.frame.run(WebMCPScript.cancelBody(call: call, reason: reason), isolated: false) }
            }
        case "result":
            reply("{}")
            guard let call = json["call"]?.stringValue, let entry = calls[call], entry.target == token else { return }
            calls[call] = nil
            let ok = json["ok"]?.boolValue ?? false
            entry.reply(ok
                ? Self.encode(["ok": .bool(true), "value": .string(json["value"]?.stringValue ?? "")])
                : Self.error("UnknownError", json["error"]?.stringValue ?? "the tool failed"))
        case "gone":
            reply("{}")
            gone(token, in: windowID)
        default:
            reply("{}")
        }
    }

    /// The window closed.
    func forget(_ windowID: UUID) {
        for token in windows[windowID]?.keys.map({ $0 }) ?? [] { gone(token, in: windowID) }
        windows[windowID] = nil
    }

    // MARK: Documents

    /// A document announced itself. The main frame's replaces the whole page; a subframe's replaces
    /// whatever was at its place in the frame tree, and everything below it.
    private func arrive(_ token: String, path: [Int], frame: any WebMCPFrame, in windowID: UUID) {
        if let existing = windows[windowID]?[token], existing.path == path { return }
        let replaced = (windows[windowID] ?? [:]).values.filter { $0.token != token && $0.path.starts(with: path) }
        for document in replaced { gone(document.token, in: windowID) }
        windows[windowID, default: [:]][token] = Document(token: token, frame: frame, path: path)
    }

    /// A document went away: its tools, the calls to them, and the calls it made.
    private func gone(_ token: String, in windowID: UUID) {
        guard let document = windows[windowID]?.removeValue(forKey: token) else { return }
        for (id, call) in calls where call.windowID == windowID {
            if call.target == token {
                calls[id] = nil
                call.reply(Self.error("UnknownError", "the document that offered the tool went away"))
            } else if call.caller == token {
                calls[id] = nil
                if let target = windows[windowID]?[call.target] {
                    Task { _ = try? await target.frame.run(WebMCPScript.cancelBody(call: id, reason: "the caller went away"),
                                                           isolated: false) }
                }
            }
        }
        if !document.tools.isEmpty {
            changed(document, exposedTo: document.tools.values.flatMap(\.exposedTo), in: windowID)
        }
    }

    // MARK: Who sees what

    private struct Visible {
        let owner: Document
        let tool: Tool
    }

    /// Every tool of another document that `document` may see: its own origin's, and those exposed to it.
    private func visible(to document: Document, in windowID: UUID) -> [Visible] {
        (windows[windowID] ?? [:]).values
            .filter { $0.token != document.token && $0.allowed != false }
            .flatMap { owner in owner.tools.values.map { Visible(owner: owner, tool: $0) } }
            .filter { Self.sees(document.origin, $0.owner.origin, exposedTo: $0.tool.exposedTo) }
    }

    nonisolated static func sees(_ viewer: String, _ owner: String, exposedTo: [String]) -> Bool {
        viewer == owner || exposedTo.contains { WebMCPBroker.origin(of: $0) == viewer }
    }

    /// Tells every other document that could see a tool of `owner`'s with this exposure that the
    /// tools changed. The owner has already told itself.
    private func changed(_ owner: Document, exposedTo: [String], in windowID: UUID) {
        for document in (windows[windowID] ?? [:]).values
        where document.token != owner.token && Self.sees(document.origin, owner.origin, exposedTo: exposedTo) {
            Task { [weak self] in
                guard let self, await allowed(document, in: windowID) else { return }
                _ = try? await document.frame.run(WebMCPScript.toolChangeBody, isolated: false)
            }
        }
    }

    // MARK: The tools permissions policy

    /// Whether a document may use the API: the main frame always; a subframe when its parent may and
    /// the parent's `<iframe allow>` lets its origin in — `'self'` by default, i.e. the parent's origin.
    private func allowed(_ document: Document, in windowID: UUID) async -> Bool {
        if let known = document.allowed { return known }
        let verdict = await decide(document, in: windowID)
        document.allowed = verdict
        return verdict
    }

    private func decide(_ document: Document, in windowID: UUID) async -> Bool {
        guard !document.isMain else { return true }
        let parentPath = Array(document.path.dropLast())
        guard let parent = windows[windowID]?.values.first(where: { $0.path == parentPath }),
              await allowed(parent, in: windowID)
        else { return false }
        let index = document.path.last ?? 0
        let attribute = (try? await parent.frame.run(Self.allowQuery(index), isolated: true)) ?? ""
        return Self.permits(allow: attribute, child: document.origin, parent: parent.origin)
    }

    /// Finds the parent's container for `frames[index]` and answers `allow` and the `src` origin as
    /// JSON — run in six's world, where the page cannot have replaced what it reads.
    nonisolated static func allowQuery(_ index: Int) -> String {
        """
        const target = window.frames[\(index)];
        for (const element of document.querySelectorAll('iframe, frame')) {
            if (element.contentWindow === target) {
                let src = '';
                try { src = new URL(element.getAttribute('src') || '', document.baseURI).origin; } catch (e) {}
                return JSON.stringify({ allow: element.getAttribute('allow') || '', src });
            }
        }
        return JSON.stringify({ allow: '', src: '' });
        """
    }

    /// The `tools` directive of an `allow` attribute, against the child's origin.
    nonisolated static func permits(allow json: String, child: String, parent: String) -> Bool {
        let parsed = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
        let allow = parsed["allow"] ?? ""
        let src = parsed["src"] ?? ""
        for directive in allow.split(separator: ";") {
            let words = directive.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.first == "tools" else { continue }
            let list = Array(words.dropFirst())
            if list.isEmpty { return child == src }
            for item in list {
                switch item {
                case "*": return true
                case "'none'": continue
                case "'self'": if child == parent { return true }
                case "'src'": if child == src { return true }
                default: if origin(of: item) == child { return true }
                }
            }
            return false
        }
        return child == parent
    }

    /// An origin as the web serialises it, from anything URL-shaped; `nil` for what is not one.
    nonisolated static func origin(of text: String) -> String? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased()
        else { return nil }
        let defaultPort = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        return "\(scheme)://\(host)" + ((url.port == nil || defaultPort) ? "" : ":\(url.port!)")
    }

    // MARK: Answers

    nonisolated static func error(_ name: String, _ message: String) -> String {
        encode(["error": .string(name), "message": .string(message)])
    }

    nonisolated static func encode(_ object: [String: ACPJSON]) -> String {
        (try? JSONEncoder().encode(ACPJSON.object(object))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private nonisolated static func text(_ json: ACPJSON) -> String {
        (try? JSONEncoder().encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
