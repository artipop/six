import Foundation

/// One HTTP/1.1 request off a connection's bytes, as a WebDriver client sends it.
nonisolated struct WebDriverRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    enum Malformed: Error { case head, length }

    /// The first whole request in `buffer` and how many bytes it took; nil while more are to come.
    static func parse(_ buffer: Data) throws -> (request: WebDriverRequest, length: Int)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64 * 1024 { throw Malformed.head }
            return nil
        }
        let lines = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { throw Malformed.head }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Malformed.head }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let stated = headers["content-length"] {
            guard let count = Int(stated), count >= 0, count <= 64 * 1024 * 1024 else { throw Malformed.length }
            length = count
        } else if headers["transfer-encoding"] != nil {
            throw Malformed.length
        }
        let head = buffer.distance(from: buffer.startIndex, to: end.upperBound)
        guard buffer.count >= head + length else { return nil }
        let body = buffer.subdata(in: end.upperBound..<buffer.index(end.upperBound, offsetBy: length))
        let path = String(start[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        return (WebDriverRequest(method: String(start[0]), path: path, headers: headers, body: body), head + length)
    }

    /// A page in some browser cannot be the client: it names an origin, or reaches the port by another name.
    var isFromLocalClient: Bool {
        guard headers["origin"] == nil, var host = headers["host"]?.lowercased() else { return false }
        if host.hasPrefix("[") {
            host = String(host.prefix { $0 != "]" }) + "]"
        } else if let colon = host.lastIndex(of: ":") {
            host = String(host[..<colon])
        }
        return ["localhost", "127.0.0.1", "[::1]"].contains(host)
    }

    var keepsAlive: Bool { headers["connection"]?.lowercased() != "close" }
}

nonisolated struct WebDriverResponse {
    var status: Int
    var body: Data

    /// WebDriver's envelope: every answer is an object with `value`.
    init(value: Any?) {
        status = 200
        body = Self.encode(["value": value ?? NSNull()])
    }

    init(_ error: WebDriverError) {
        status = error.status
        var value: [String: Any] = ["error": error.code, "message": error.message, "stacktrace": ""]
        if let data = error.data { value["data"] = data }
        body = Self.encode(["value": value])
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data(#"{"value":null}"#.utf8)
    }

    func encoded(keepAlive: Bool) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Internal Server Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nCache-Control: no-cache\r\n"
            + "Content-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// An error as the WebDriver specification names it, with the status it travels under.
nonisolated struct WebDriverError: Error {
    var code: String
    var message: String
    var data: [String: Any]?

    init(_ code: String, _ message: String = "", data: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    var status: Int {
        switch code {
        case "invalid argument", "invalid selector", "invalid element state", "element click intercepted",
             "element not interactable", "element not selectable", "no such cookie": 400
        case "no such element", "no such frame", "no such window", "no such alert", "stale element reference",
             "invalid session id", "unknown command", "no such shadow root", "detached shadow root": 404
        case "unknown method": 405
        default: 500
        }
    }

    /// What WebKit's automation protocol answered, in WebDriver's words: its message is `Name;text`.
    init(protocolError error: [String: Any]) {
        let text = error["message"] as? String ?? ""
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let named: [String: String] = [
            "WindowNotFound": "no such window", "FrameNotFound": "no such frame", "NotImplemented": "unsupported operation",
            "ElementNotInteractable": "element not interactable", "JavaScriptError": "javascript error",
            "JavaScriptTimeout": "script timeout", "NodeNotFound": "no such element", "StaleNode": "stale element reference",
            "InvalidNodeIdentifier": "no such element", "MissingParameter": "invalid argument", "InvalidParameter": "invalid argument",
            "InvalidElementState": "invalid element state", "InvalidSelector": "invalid selector", "Timeout": "timeout",
            "NoJavaScriptDialog": "no such alert", "ElementNotSelectable": "element not selectable",
            "ScreenshotError": "unable to capture screen", "UnexpectedAlertOpen": "unexpected alert open",
            "TargetOutOfBounds": "move target out of bounds",
        ]
        if let code = named[String(parts[0])] {
            self.init(code, parts.count > 1 ? String(parts[1]) : "")
        } else {
            self.init("unknown error", text)
        }
    }
}

/// WebDriver's key code points and input actions, as WebKit's automation protocol takes them.
nonisolated enum WebDriverInput {
    static let element = "element-6066-11e4-a52e-4f735466cecf"

    private static let named: [UInt32: String] = [
        0xE001: "Cancel", 0xE002: "Help", 0xE003: "Backspace", 0xE004: "Tab", 0xE005: "Clear", 0xE006: "Return",
        0xE007: "Enter", 0xE008: "Shift", 0xE050: "Shift", 0xE009: "Control", 0xE051: "Control", 0xE00A: "Alternate",
        0xE052: "Alternate", 0xE00B: "Pause", 0xE00C: "Escape", 0xE00D: "Space", 0xE00E: "PageUp", 0xE054: "PageUpRight",
        0xE00F: "PageDown", 0xE055: "PageDownRight", 0xE010: "End", 0xE056: "EndRight", 0xE011: "Home", 0xE057: "HomeRight",
        0xE012: "LeftArrow", 0xE058: "LeftArrowRight", 0xE013: "UpArrow", 0xE059: "UpArrowRight", 0xE014: "RightArrow",
        0xE05A: "RightArrowRight", 0xE015: "DownArrow", 0xE05B: "DownArrowRight", 0xE016: "Insert", 0xE05C: "InsertRight",
        0xE017: "Delete", 0xE05D: "DeleteRight", 0xE018: "Semicolon", 0xE019: "Equals", 0xE01A: "NumberPad0",
        0xE01B: "NumberPad1", 0xE01C: "NumberPad2", 0xE01D: "NumberPad3", 0xE01E: "NumberPad4", 0xE01F: "NumberPad5",
        0xE020: "NumberPad6", 0xE021: "NumberPad7", 0xE022: "NumberPad8", 0xE023: "NumberPad9", 0xE024: "NumberPadMultiply",
        0xE025: "NumberPadAdd", 0xE026: "NumberPadSeparator", 0xE027: "NumberPadSubtract", 0xE028: "NumberPadDecimal",
        0xE029: "NumberPadDivide", 0xE031: "Function1", 0xE032: "Function2", 0xE033: "Function3", 0xE034: "Function4",
        0xE035: "Function5", 0xE036: "Function6", 0xE037: "Function7", 0xE038: "Function8", 0xE039: "Function9",
        0xE03A: "Function10", 0xE03B: "Function11", 0xE03C: "Function12", 0xE03D: "Meta", 0xE053: "Meta",
    ]
    private static let modifiers: Set = ["Shift", "Control", "Alternate", "Meta"]

    static func virtualKey(_ key: String) -> String? {
        key.unicodeScalars.first.flatMap { named[$0.value] }
    }

    /// Element Send Keys: a modifier's code point holds it until the same one or the null key lets go.
    static func typing(_ text: String) -> [[String: Any]] {
        var held: [String] = []
        var interactions: [[String: Any]] = []
        for scalar in text.unicodeScalars {
            if scalar.value == 0xE000 {
                interactions += held.reversed().map { ["type": "KeyRelease", "key": $0] }
                held = []
            } else if let key = named[scalar.value] {
                if !modifiers.contains(key) {
                    interactions.append(["type": "InsertByKey", "key": key])
                } else if let index = held.firstIndex(of: key) {
                    held.remove(at: index)
                    interactions.append(["type": "KeyRelease", "key": key])
                } else {
                    held.append(key)
                    interactions.append(["type": "KeyPress", "key": key])
                }
            } else {
                interactions.append(["type": "InsertByKey", "text": String(scalar)])
            }
        }
        return interactions + held.reversed().map { ["type": "KeyRelease", "key": $0] }
    }

    /// What an input source is holding between one Perform Actions and the next.
    struct Source {
        var type = "Null"
        var button: String?
        var characters: [String] = []
        var virtualKeys: [String] = []
    }

    /// Perform Actions' sources, turned into the protocol's `inputSources` and `steps`: one step per tick.
    static func sequence(_ actions: [[String: Any]], sources: inout [String: Source]) throws -> (inputSources: [[String: Any]], steps: [[String: Any]]) {
        var used: [String] = []
        var ticks: [[[String: Any]]] = []
        for source in actions {
            guard let id = source["id"] as? String, let kind = source["type"] as? String,
                  let items = source["actions"] as? [[String: Any]] else {
                throw WebDriverError("invalid argument", "An input source needs an id, a type and actions.")
            }
            let pointer = (source["parameters"] as? [String: Any])?["pointerType"] as? String ?? "mouse"
            let type: String
            switch kind {
            case "key": type = "Keyboard"
            case "wheel": type = "Wheel"
            case "none": type = "Null"
            case "pointer": type = ["mouse": "Mouse", "touch": "Touch", "pen": "Pen"][pointer] ?? "Mouse"
            default: throw WebDriverError("invalid argument", "No input source is of type \(kind).")
            }
            sources[id, default: Source()].type = type
            used.append(id)
            for (tick, action) in items.enumerated() {
                if ticks.count <= tick { ticks.append([]) }
                ticks[tick].append(try state(of: action, source: id, in: &sources))
            }
        }
        return (used.map { ["sourceId": $0, "sourceType": sources[$0]?.type ?? "Null"] }, ticks.map { ["states": $0] })
    }

    private static func state(of action: [String: Any], source id: String, in sources: inout [String: Source]) throws -> [String: Any] {
        var source = sources[id] ?? Source()
        defer { sources[id] = source }
        var state: [String: Any] = ["sourceId": id]
        guard let subtype = action["type"] as? String else { throw WebDriverError("invalid argument", "An action needs a type.") }
        if let duration = action["duration"] as? NSNumber { state["duration"] = duration }

        func place() throws {
            guard let x = action["x"] as? NSNumber, let y = action["y"] as? NSNumber else {
                throw WebDriverError("invalid argument", "\(subtype) needs x and y.")
            }
            state["location"] = ["x": x.intValue, "y": y.intValue]
            if let node = (action["origin"] as? [String: Any])?[element] as? String {
                state["origin"] = "Element"
                state["nodeHandle"] = node
            } else {
                state["origin"] = action["origin"] as? String == "pointer" ? "Pointer" : "Viewport"
            }
        }

        switch subtype {
        case "pause":
            break
        case "keyDown", "keyUp":
            guard let value = action["value"] as? String, !value.isEmpty else {
                throw WebDriverError("invalid argument", "\(subtype) needs a value.")
            }
            if let key = virtualKey(value) {
                source.virtualKeys.removeAll { $0 == key }
                if subtype == "keyDown" { source.virtualKeys.append(key) }
            } else {
                source.characters.removeAll { $0 == value }
                if subtype == "keyDown" { source.characters.append(value) }
            }
        case "pointerMove":
            try place()
            state["mouseInteraction"] = "Move"
        case "pointerDown", "pointerUp":
            let button = ["Left", "Middle", "Right"][min(max((action["button"] as? NSNumber)?.intValue ?? 0, 0), 2)]
            // The protocol reads an Up's button off the Up itself; without one it is sent as a move.
            state["pressedButton"] = button
            state["mouseInteraction"] = subtype == "pointerDown" ? "Down" : "Up"
            source.button = subtype == "pointerDown" ? button : nil
        case "pointerCancel":
            source.button = nil
        case "scroll":
            try place()
            guard let x = action["deltaX"] as? NSNumber, let y = action["deltaY"] as? NSNumber else {
                throw WebDriverError("invalid argument", "scroll needs deltaX and deltaY.")
            }
            state["delta"] = ["width": x.intValue, "height": y.intValue]
        default:
            throw WebDriverError("invalid argument", "No action is \(subtype).")
        }

        if source.type == "Keyboard" {
            if let last = source.characters.last {
                state["pressedCharKey"] = last
                state["pressedCharKeys"] = source.characters
            }
            if !source.virtualKeys.isEmpty { state["pressedVirtualKeys"] = source.virtualKeys }
        } else if state["pressedButton"] == nil, let button = source.button {
            state["pressedButton"] = button
        }
        return state
    }
}
