import Foundation

/// A tool a page declared through `document.modelContext.registerTool` — its description, and
/// nothing that runs. The function stays in the page (`WebMCPScript` keeps it there); what crosses
/// into six is what an agent needs to decide whether to call it.
///
/// Everything in here is the page's own word about itself. The annotations especially: a page that
/// says `readOnlyHint` has said it, not proved it, which is why docs/webmcp.md makes them lower the
/// question about a call and never the question about the site.
nonisolated struct WebMCPTool: Equatable, Sendable {
    var name: String
    var title: String
    var description: String
    /// JSON Schema for the input, as the page wrote it. An object always — a tool that declared none
    /// gets the empty object schema, which is what the draft means by leaving it out.
    var inputSchema: ACPJSON
    var readOnly: Bool
    var untrustedContent: Bool
    var consequential: Bool
    /// The page's `location.origin` when it registered. Main frame only, so it is the window's.
    var origin: String

    /// For `list_page_tools`: the draft's own field names, so an agent that has read the spec reads
    /// this without a glossary.
    var json: ACPJSON {
        var tool: [String: ACPJSON] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": .bool(readOnly),
                "untrustedContentHint": .bool(untrustedContent),
                "consequentialHint": .bool(consequential),
            ],
            "origin": .string(origin),
        ]
        if !title.isEmpty { tool["title"] = .string(title) }
        return .object(tool)
    }
}

/// What the polyfill says over its channel. JSON text, one message per `postMessage`, and every one
/// of them stamped with the document it came from (`doc`, random per document) — that stamp is what
/// lets the registry tell a new page's first tool from an old page's last one without asking
/// anybody when the navigation happened.
///
/// **The page can write these itself.** The channel lives in the page's world
/// (`WebMCPScript` says why), so a script there can post a registration the polyfill never made.
/// What that buys it is a tool of its own listed under its own origin, which is what
/// `registerTool` gives it anyway. So parsing is strict about *shape* — a name the draft would
/// refuse, a schema that is not an object, sizes nobody writes by hand — and does not pretend to
/// be strict about *truth*.
nonisolated enum WebMCPMessage: Equatable, Sendable {
    /// The window is showing a new document — sent first, before anything else the polyfill does.
    case document(doc: String, url: String)
    case register(doc: String, tool: WebMCPTool)
    case unregister(doc: String, name: String)
    /// The end of a call six started: `text` is what the tool returned, or the error it threw.
    case result(doc: String, call: String, ok: Bool, text: String)

    var doc: String {
        switch self {
        case .document(let doc, _), .register(let doc, _), .unregister(let doc, _), .result(let doc, _, _, _): doc
        }
    }

    /// The draft's limit, and its alphabet: `[A-Za-z0-9_.-]`, 1 to 128 of them.
    static let nameLimit = 128
    /// Longer than any description written for a person to read, and short enough that forty tools
    /// do not become a prompt of their own.
    static let descriptionLimit = 4_000
    static let titleLimit = 200
    /// A schema is a page's to write and an agent's to read in full, every time it lists the tools.
    static let schemaLimit = 64 * 1024

    static func isValidName(_ name: String) -> Bool {
        guard (1...nameLimit).contains(name.utf8.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "-": true
            default: false
            }
        }
    }

    static func parse(_ text: String) -> WebMCPMessage? {
        guard let json = try? JSONDecoder().decode(ACPJSON.self, from: Data(text.utf8)),
              let doc = json["doc"]?.stringValue, !doc.isEmpty
        else { return nil }
        switch json["kind"]?.stringValue {
        case "document":
            return .document(doc: doc, url: json["url"]?.stringValue ?? "")
        case "register":
            guard let tool = json["tool"].flatMap({ Self.tool(from: $0, origin: json["origin"]?.stringValue ?? "") })
            else { return nil }
            return .register(doc: doc, tool: tool)
        case "unregister":
            guard let name = json["name"]?.stringValue, isValidName(name) else { return nil }
            return .unregister(doc: doc, name: name)
        case "result":
            guard let call = json["call"]?.stringValue, let ok = json["ok"]?.boolValue else { return nil }
            let text = ok ? (json["value"]?.stringValue ?? "") : (json["error"]?.stringValue ?? "the tool failed")
            return .result(doc: doc, call: call, ok: ok, text: text)
        default:
            return nil
        }
    }

    private static func tool(from json: ACPJSON, origin: String) -> WebMCPTool? {
        guard let name = json["name"]?.stringValue, isValidName(name),
              let description = json["description"]?.stringValue
        else { return nil }
        let schema: ACPJSON
        switch json["inputSchema"] {
        case nil, .null?: schema = ["type": "object", "properties": [:]]
        case .object?: schema = json["inputSchema"]!
        default: return nil
        }
        guard let encoded = try? JSONEncoder().encode(schema), encoded.count <= schemaLimit else { return nil }
        let hints = json["annotations"]
        return WebMCPTool(
            name: name,
            title: String((json["title"]?.stringValue ?? "").prefix(titleLimit)),
            description: String(description.prefix(descriptionLimit)),
            inputSchema: schema,
            readOnly: hints?["readOnlyHint"]?.boolValue ?? false,
            untrustedContent: hints?["untrustedContentHint"]?.boolValue ?? false,
            consequential: hints?["consequentialHint"]?.boolValue ?? false,
            origin: origin)
    }
}

/// Which tools each window's page offers right now.
///
/// Tools belong to a **document**, not to a window: a navigation takes them away and the next page
/// declares its own. Nothing here waits to be told that a navigation happened, because on the Mac
/// that news arrives through an async sequence that can land *after* the new page's first
/// registration — clearing on it would erase the tools it was clearing for. Instead a window
/// remembers which document its tools came from, and a message stamped with a different one
/// starts the list over. The fronts' own navigation events are only a backstop (`settle`), for the
/// documents that never run the polyfill at all: a PDF, an image, an `http:` page.
nonisolated struct WebMCPRegistry: Equatable, Sendable {
    /// Per document. A page that registers more than this is not describing itself to an agent,
    /// it is filling the agent's context.
    static let toolLimit = 100

    private struct Page: Equatable, Sendable {
        var doc: String?
        var tools: [WebMCPTool] = []
    }

    private var pages: [UUID: Page] = [:]

    init() {}

    func tools(in windowID: UUID) -> [WebMCPTool] {
        pages[windowID]?.tools ?? []
    }

    /// The document the window's tools belong to — `nil` when nothing has been heard from it.
    func document(of windowID: UUID) -> String? {
        pages[windowID]?.doc
    }

    /// Takes one message from the window's page. Returns whether the tools it offers changed.
    /// `result` messages are not the registry's and change nothing.
    @discardableResult
    mutating func apply(_ message: WebMCPMessage, from windowID: UUID) -> Bool {
        if case .result = message { return false }
        var page = pages[windowID] ?? Page()
        var changed = false
        if page.doc != message.doc {
            changed = !page.tools.isEmpty
            page = Page(doc: message.doc)
        }
        switch message {
        case .register(_, let tool):
            if let index = page.tools.firstIndex(where: { $0.name == tool.name }) {
                // The same document announcing the same tool again: a page restored from the
                // back-forward cache does this, since six forgot it when the window left.
                if page.tools[index] != tool { page.tools[index] = tool; changed = true }
            } else if page.tools.count < Self.toolLimit {
                page.tools.append(tool)
                changed = true
            }
        case .unregister(_, let name):
            let before = page.tools.count
            page.tools.removeAll { $0.name == name }
            changed = changed || page.tools.count != before
        case .document, .result:
            break
        }
        pages[windowID] = page
        return changed
    }

    /// The front has asked the page which document it is showing, after a navigation: `nil` when
    /// there is no polyfill there to answer. Anything else than the document the tools came from
    /// empties the list.
    @discardableResult
    mutating func settle(_ windowID: UUID, document: String?) -> Bool {
        guard let page = pages[windowID] else {
            if let document { pages[windowID] = Page(doc: document) }
            return false
        }
        guard page.doc != document else { return false }
        pages[windowID] = Page(doc: document)
        return !page.tools.isEmpty
    }

    @discardableResult
    mutating func forget(_ windowID: UUID) -> Bool {
        pages.removeValue(forKey: windowID).map { !$0.tools.isEmpty } ?? false
    }
}
