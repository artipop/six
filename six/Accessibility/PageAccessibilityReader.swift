#if os(macOS)
import AppKit
import ApplicationServices

/// A page as macOS accessibility sees it: WebKit's own accessibility tree, read the way VoiceOver
/// reads it, through `AXUIElement` — the tree lives in the web content process and only the client
/// API crosses to it ([accessibility.md](../../docs/accessibility.md)).
///
/// This half runs in `six --ax-read <pid>`, never in the browser: six asking itself deadlocks, because
/// the accessibility server inside six suspends the thread holding SwiftUI's update lock.
/// `AXReadProcess` launches it, which is also what makes it six in macOS's eyes.
nonisolated enum PageAccessibilityReader {
    static let flag = "--ax-read"
    /// The reader leaves by itself after this long without a request; the browser starts another.
    static let idleTimeout: TimeInterval = 30

    static var isRequested: Bool { CommandLine.arguments.dropFirst().contains(flag) }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to put the question to the person, once; answers what is true right now.
    @discardableResult
    static func askForTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// The child: one `AXReadRequest` per line on stdin, one `AXPageSnapshot` per line on stdout, until
    /// the browser closes the pipe or has asked nothing for `idleTimeout`.
    static func runChild() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
              let pid = pid_t(arguments[index + 1]) else {
            FileHandle.standardError.write(Data("six --ax-read: needs the pid of the browser\n".utf8))
            exit(2)
        }
        // Global for this process, which asks nothing else: a busy web content process costs a
        // missing subtree, not a stalled read.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var waiting = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while poll(&waiting, 1, Int32(idleTimeout * 1000)) > 0, let line = readLine() {
            guard let request = try? decoder.decode(AXReadRequest.self, from: Data(line.utf8)) else { continue }
            let snapshot = read(pid: pid, at: request.point, visible: request.visible, limit: request.limit)
            guard var data = try? encoder.encode(snapshot) else { continue }
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }

    // MARK: The walk

    /// One round trip per element for all of these; `AXChildren` rides along.
    private static let attributes: [String] = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue",
        "AXPlaceholderValue", "AXDOMIdentifier", "AXPosition", "AXSize", "AXEnabled", "AXFocused", "AXChildren",
    ]

    /// The walk stops here even with elements left, and says it was truncated.
    private static let budget: Duration = .seconds(5)

    /// `point` and `visible` are in accessibility coordinates (top-left of the primary screen, y down):
    /// subtrees wholly outside `visible` are not walked, which keeps a long page from costing a round
    /// trip per element of it.
    static func read(pid: pid_t, at point: CGPoint, visible: CGRect, limit: Int) -> AXPageSnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        var snapshot = AXPageSnapshot()
        guard AXIsProcessTrusted() else {
            snapshot.failure = .notTrusted
            return snapshot
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        if error == .apiDisabled {
            snapshot.failure = .notTrusted
            return snapshot
        }
        let hitArea = hit.flatMap { outermostWebArea(above: $0) ?? webArea(below: $0) }
        guard let area = hitArea.flatMap({ overlap(of: $0, with: visible) > 0 ? $0 : nil })
                ?? widestWebArea(in: app, over: visible) else {
            snapshot.failure = .noWebArea
            return snapshot
        }

        // Depth-first, children pushed in reverse so the numbers come out in document order.
        let margin = visible.insetBy(dx: -40, dy: -40)
        var stack: [(element: AXUIElement, depth: Int, parent: Int?)] = [(area, 0, nil)]
        var nodes: [AXPageNode] = []
        while let next = stack.popLast() {
            let (element, depth, parent) = next
            guard nodes.count < limit, clock.now - start < budget else {
                snapshot.truncated = true
                break
            }
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == attributes.count else { continue }
            let role = string(values[0])
            let position = Self.point(values[8]) ?? .zero
            let size = Self.size(values[9]) ?? .zero
            let frame = CGRect(origin: position, size: size)
            // Scrolled away, or laid out off the side. A zero-size box is not evidence of anything —
            // WebKit gives some containers none while their children are on screen — so only a box
            // that has a size and misses the window is left out.
            if depth > 0, frame.width > 0, frame.height > 0, !frame.intersects(margin) { continue }

            let isText = role == "AXStaticText"
            var actions: [String] = []
            var settable = false
            if !isText {
                var names: CFArray?
                if AXUIElementCopyActionNames(element, &names) == .success { actions = names as? [String] ?? [] }
                if Self.valueCanBeSet(role: role) {
                    var answer: DarwinBoolean = false
                    if AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &answer) == .success {
                        settable = answer.boolValue
                    }
                }
            }
            let subrole = string(values[1])
            let title = string(values[3])
            let description = string(values[4])
            let value = describe(values[5])
            let id = nodes.count + 1
            nodes.append(AXPageNode(
                id: id, parent: parent, depth: depth,
                role: role, subrole: subrole, roleDescription: string(values[2]),
                name: isText ? value : (title.isEmpty ? description : title),
                value: isText ? "" : value,
                placeholder: string(values[6]), domID: string(values[7]),
                frame: frame,
                enabled: (present(values[10]) as? Bool) ?? true,
                focused: (present(values[11]) as? Bool) ?? false,
                actions: actions, valueSettable: settable,
                kind: AXPageNode.kind(role: role, subrole: subrole, actions: actions, settable: settable)))

            // A text run's children are its lines; nothing an agent or a person would point at.
            guard !isText, let children = present(values[12]) as? [AXUIElement] else { continue }
            for child in children.reversed() { stack.append((child, depth + 1, id)) }
        }

        nameFromText(&nodes)
        snapshot.nodes = nodes
        snapshot.webAreaFrame = nodes.first?.frame ?? .zero
        snapshot.elapsed = clock.now - start
        return snapshot
    }

    /// The top-level page, not the iframe the middle of the window happens to be over.
    private static func outermostWebArea(above element: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        var here: AXUIElement? = element
        for _ in 0..<80 {
            guard let current = here else { break }
            if copy(current, "AXRole") as? String == "AXWebArea" { found = current }
            guard let parent = copy(current, "AXParent") else { break }
            here = (parent as! AXUIElement)
        }
        return found
    }

    /// Every web area of the app, the page wanted being the one covering most of the pane: the rail
    /// keeps off-screen columns as web areas too, so the first one found is a lottery.
    private static func widestWebArea(in app: AXUIElement, over visible: CGRect) -> AXUIElement? {
        var queue = [app]
        var best: (element: AXUIElement, overlap: CGFloat)?
        var seen = 0
        while !queue.isEmpty, seen < 6000 {
            let element = queue.removeFirst()
            seen += 1
            if copy(element, "AXRole") as? String == "AXWebArea" {
                let area = overlap(of: element, with: visible)
                if area > (best?.overlap ?? 0) { best = (element, area) }
                continue
            }
            queue += copy(element, "AXChildren") as? [AXUIElement] ?? []
        }
        return best?.element
    }

    private static func overlap(of element: AXUIElement, with visible: CGRect) -> CGFloat {
        guard let origin = point(copy(element, "AXPosition")), let size = size(copy(element, "AXSize")) else { return 0 }
        let common = CGRect(origin: origin, size: size).intersection(visible)
        return common.isNull ? 0 : common.width * common.height
    }

    /// The hit test can stop at the web view itself. `WKWebView` answers `accessibilityHitTest:` with
    /// its remote child whatever the point (`WebViewImpl::accessibilityHitTest`), and whether the
    /// runtime carries the test on into the web content process is not something the source says —
    /// so when climbing finds no web area, look a few levels down from where the test stopped.
    private static func webArea(below element: AXUIElement) -> AXUIElement? {
        var level = [element]
        for _ in 0..<4 {
            var next: [AXUIElement] = []
            for here in level {
                if copy(here, "AXRole") as? String == "AXWebArea" { return here }
                next += copy(here, "AXChildren") as? [AXUIElement] ?? []
            }
            guard !next.isEmpty, next.count < 200 else { return nil }
            level = next
        }
        return nil
    }

    /// A link or a button whose name is its text carries that text in a child, not in its own title.
    /// The name a person hears is the text; give it to the element, the way a screen reader does.
    private static func nameFromText(_ nodes: inout [AXPageNode]) {
        var children: [Int: [Int]] = [:]
        for node in nodes { if let parent = node.parent { children[parent, default: []].append(node.id) } }
        for index in nodes.indices where nodes[index].name.isEmpty && nodes[index].kind.wantsName {
            var text = ""
            var queue = children[nodes[index].id] ?? []
            while !queue.isEmpty, text.count < 80 {
                let next = nodes[queue.removeFirst() - 1]
                if next.role == "AXStaticText" {
                    text += (text.isEmpty ? "" : " ") + next.name
                } else {
                    queue.insert(contentsOf: children[next.id] ?? [], at: 0)
                }
            }
            nodes[index].name = String(text.prefix(80))
        }
    }

    private static func valueCanBeSet(role: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor", "AXDateField", "AXColorWell"].contains(role)
    }

    // MARK: Values

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// `AXUIElementCopyMultipleAttributeValues` answers a missing attribute with an `AXValue` holding
    /// the error rather than leaving a hole, so every read goes through this.
    private static func present(_ value: AnyObject?) -> AnyObject? {
        guard let value, !(value is NSNull) else { return nil }
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
        return value
    }

    private static func string(_ value: AnyObject?) -> String {
        (present(value) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A value is text for a field, a number for a slider or a checkbox, a URL for a link.
    private static func describe(_ value: AnyObject?) -> String {
        switch present(value) {
        case let text as String: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        case let number as NSNumber: number.stringValue
        case let url as URL: url.absoluteString
        default: ""
        }
    }

    private static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value = present(value), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: AnyObject?) -> CGSize? {
        guard let value = present(value), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// One element of the tree, as values: nothing here holds on to the `AXUIElement` it came from, so a
/// snapshot can cross to the main actor and outlive the page.
nonisolated struct AXPageNode: Sendable, Identifiable, Codable {
    /// What the overlay colours it as, and what the outline keeps.
    nonisolated enum Kind: String, Sendable, CaseIterable, Codable {
        case control, field, landmark, heading, image, text, other

        /// The kinds whose name is the whole point of them: an unnamed button is a question an agent
        /// cannot answer, and the overlay marks it.
        var wantsName: Bool { self == .control || self == .field || self == .heading || self == .landmark }
    }

    /// 1-based, in document order: the number the outline prints. Valid until the next read.
    let id: Int
    let parent: Int?
    let depth: Int
    let role: String
    let subrole: String
    /// Localized by the system ("button", «кнопка») — for the person looking at the overlay.
    let roleDescription: String
    var name: String
    let value: String
    let placeholder: String
    let domID: String
    /// Accessibility coordinates: top-left of the primary screen, y down.
    let frame: CGRect
    let enabled: Bool
    let focused: Bool
    let actions: [String]
    let valueSettable: Bool
    let kind: Kind

    var isUnnamed: Bool { name.isEmpty && kind.wantsName }

    /// What can be done with it, in words. `AXScrollToVisible` and `AXShowMenu` are left out: WebKit
    /// gives them to every element, so they say nothing about this one.
    var verbs: [String] {
        var verbs = actions.compactMap { action -> String? in
            switch action {
            case "AXScrollToVisible", "AXShowMenu", "AXShowDefaultUI", "AXShowAlternateUI": nil
            case "AXPress": "press"
            case "AXIncrement": "increment"
            case "AXDecrement": "decrement"
            case "AXConfirm": "confirm"
            case "AXCancel": "cancel"
            case "AXPick": "pick"
            case "AXRaise": "raise"
            default: action.hasPrefix("AX") ? String(action.dropFirst(2)).lowercased() : action
            }
        }
        if valueSettable { verbs.append(kind == .field ? "type" : "set") }
        return verbs
    }

    /// The role in the ARIA vocabulary a model already knows, not AppKit's: `button`, `textbox`,
    /// `navigation`. English on purpose — this is read by a model ([localization.md]).
    var ariaRole: String {
        switch subrole {
        case "AXSearchField": return "searchbox"
        case "AXSecureTextField": return "password"
        case "AXSwitch": return "switch"
        case "AXTabButton": return "tab"
        case "AXLandmarkBanner": return "banner"
        case "AXLandmarkNavigation": return "navigation"
        case "AXLandmarkMain": return "main"
        case "AXLandmarkSearch": return "search"
        case "AXLandmarkComplementary": return "complementary"
        case "AXLandmarkContentInfo": return "contentinfo"
        case "AXLandmarkRegion": return "region"
        case "AXLandmarkForm": return "form"
        case "AXApplicationDialog", "AXDialog": return "dialog"
        case "AXApplicationAlert", "AXApplicationAlertDialog": return "alert"
        case "AXDocumentArticle": return "article"
        default: break
        }
        switch role {
        case "AXWebArea": return "document"
        case "AXButton": return "button"
        case "AXLink": return "link"
        case "AXTextField": return "textbox"
        case "AXTextArea": return "textbox multiline"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "combobox"
        case "AXComboBox": return "combobox"
        case "AXMenuButton": return "button menu"
        case "AXSlider": return "slider"
        case "AXIncrementor": return "spinbutton"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXHeading": return "heading"
        case "AXImage": return "image"
        case "AXStaticText": return "text"
        case "AXList": return "list"
        case "AXTable", "AXGrid": return "table"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXTabGroup": return "tablist"
        case "AXMenu": return "menu"
        case "AXMenuItem": return "menuitem"
        case "AXProgressIndicator": return "progressbar"
        default: return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role
        }
    }

    static func kind(role: String, subrole: String, actions: [String], settable: Bool) -> Kind {
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXDateField"].contains(role) || subrole == "AXSearchField" {
            return .field
        }
        if ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
            "AXIncrementor", "AXDisclosureTriangle", "AXMenuItem", "AXColorWell"].contains(role) {
            return .control
        }
        if subrole.hasPrefix("AXLandmark") || ["AXApplicationDialog", "AXDialog", "AXDocumentArticle"].contains(subrole) {
            return .landmark
        }
        switch role {
        case "AXHeading": return .heading
        case "AXImage": return .image
        case "AXStaticText": return .text
        default: break
        }
        // A `div` with a click handler: WebKit gives it `AXPress`, and it is as much a control as a
        // `<button>` is — more of one, for an agent, since nothing in the markup says so.
        if actions.contains(where: { ["AXPress", "AXIncrement", "AXPick", "AXConfirm"].contains($0) }) { return .control }
        if settable { return .field }
        return .other
    }
}

nonisolated struct AXPageSnapshot: Sendable, Codable {
    nonisolated enum Failure: Sendable, Equatable, Codable {
        /// Privacy & Security ▸ Accessibility has not allowed six.
        case notTrusted
        /// The middle of the window is not over web content — a start page, a document, an app.
        case noWebArea
        /// The reader process could not be started, or did not answer in time.
        case noAnswer
    }

    var nodes: [AXPageNode] = []
    var webAreaFrame: CGRect = .zero
    /// The walk stopped at its limit before the visible part of the page was done.
    var truncated = false
    var elapsed: Duration = .zero
    var failure: Failure?
}

/// What the browser asks `six --ax-read` for, one per line.
nonisolated struct AXReadRequest: Codable, Sendable {
    let point: CGPoint
    let visible: CGRect
    let limit: Int
}
#endif
