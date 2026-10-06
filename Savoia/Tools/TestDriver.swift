import AppKit
import WebKit

/// `SAVOIA_TESTDRIVER=1`: what wpt's testdriver asks of a browser, as tools for the runner (docs/test-suites.md).
@MainActor
enum TestDriver {
    nonisolated static let isOn = ProcessInfo.processInfo.environment["SAVOIA_TESTDRIVER"] != nil

    static func tools(browser: BrowserState, tab: @escaping (ACPJSON) throws -> BrowserTab) -> [BrowserTool] {
        let window = BrowserTool.Parameter(name: "window_id", description: "Window id.", required: true)
        let context = BrowserTool.Parameter(name: "context", description: "The frame's `__wptrunner_id`; the top frame when absent.")
        return [
            BrowserTool(
                name: "testdriver_set_permission",
                description: "Files an answer for an origin, as the permission bar would: `granted`, `denied`, or `prompt` to forget it.",
                parameters: [window,
                             .init(name: "origin", description: "The origin, as `location.origin` writes it.", required: true),
                             .init(name: "permission", description: "The permission's name in the Permissions API.", required: true),
                             .init(name: "state", description: "`granted`, `denied` or `prompt`.", required: true),
                             .init(name: "top", description: "The top-level origin, for `storage-access`.")],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    let name = args["permission"]?.stringValue ?? ""
                    if name == "storage-access" {
                        return try await grantStorageAccess(args, tab: tab, browser: browser)
                    }
                    guard let permission = SitePermission(rawValue: name), permission != .pageTools else {
                        throw BrowserTool.Failure(message: "Savoia keeps no answer for \(name)")
                    }
                    guard let origin = args["origin"]?.stringValue, let permissions = browser.permissions else {
                        throw BrowserTool.Failure(message: "origin is required")
                    }
                    switch args["state"]?.stringValue {
                    case "granted": permissions.set(true, permission, forOrigin: origin, profileID: tab.profileID)
                    case "denied": permissions.set(false, permission, forOrigin: origin, profileID: tab.profileID)
                    case "prompt": permissions.forget(permission, forOrigin: origin, profileID: tab.profileID)
                    default: throw BrowserTool.Failure(message: "state must be granted, denied or prompt")
                    }
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_click",
                description: "A mouse click in the page, at a point of its viewport in CSS pixels.",
                parameters: [window,
                             .init(name: "x", description: "From the viewport's left edge.", type: .integer, required: true),
                             .init(name: "y", description: "From the viewport's top edge.", type: .integer, required: true),
                             context],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue else {
                        throw BrowserTool.Failure(message: "x and y are required")
                    }
                    var point = CGPoint(x: x, y: y)
                    if let wanted = args["context"]?.stringValue {
                        let offset = try await offset(ofFrame: wanted, in: tab)
                        point.x += offset.x
                        point.y += offset.y
                    }
                    guard tab.click(atViewport: point) else {
                        throw BrowserTool.Failure(message: "The window's page is not on screen")
                    }
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_in_context",
                description: "Runs a function body in the frame testdriver named, and returns the string it returns.",
                parameters: [window, context, .init(name: "script", description: "JavaScript function body.", required: true)],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    let frames = try await frames(of: tab)
                    let index = try await find(args["context"]?.stringValue ?? "", among: frames, in: tab)
                    let value = try await tab.callWithoutGesture(args["script"]?.stringValue ?? "", in: .page,
                                                                 frame: frames[index].info)
                    return value as? String ?? ""
                }
            ),
            BrowserTool(
                name: "testdriver_delete_all_cookies",
                description: "Removes every cookie of the window's profile.",
                parameters: [window],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let profile = browser.profiles.first(where: { $0.id == tab.profileID }) else {
                        throw BrowserTool.Failure(message: "The window's profile is gone")
                    }
                    let cookies = browser.dataStore(for: profile).httpCookieStore
                    for cookie in await cookies.allCookies() { await cookies.deleteCookie(cookie) }
                    return "ok"
                }
            ),
        ]
    }

    // MARK: Frames

    private struct Frame {
        let info: WKFrameInfo
        let parent: Int?
    }

    private static func frames(of tab: BrowserTab) async throws -> [Frame] {
        guard let view = WebViewResponder.shared.webView(for: tab.id), view.responds(to: #selector(FrameTrees.frames(_:))) else {
            throw BrowserTool.Failure(message: "The window's page is not on screen")
        }
        let root: Box<NSObject?> = await withCheckedContinuation { continuation in
            unsafeBitCast(view, to: FrameTrees.self).frames { continuation.resume(returning: Box(value: $0 as? NSObject)) }
        }
        var found: [Frame] = []
        func walk(_ node: NSObject, parent: Int?) {
            guard let info = node.value(forKey: "info") as? WKFrameInfo else { return }
            found.append(Frame(info: info, parent: parent))
            let index = found.count - 1
            for child in node.value(forKey: "childFrames") as? [NSObject] ?? [] { walk(child, parent: index) }
        }
        if let node = root.value { walk(node, parent: nil) }
        return found
    }

    /// The frame whose window testdriver gave this id (`get_window_id` in testdriver-extra.js).
    private static func find(_ context: String, among frames: [Frame], in tab: BrowserTab) async throws -> Int {
        // `url:` and a piece of the frame's address, for probing a frame testdriver has not named.
        if context.hasPrefix("url:"), let index = frames.firstIndex(where: {
            $0.info.request.url?.absoluteString.contains(context.dropFirst(4)) == true
        }) { return index }
        for (index, frame) in frames.enumerated() {
            let isIt = try? await tab.callWithoutGesture("return window.__wptrunner_id === context",
                                                         arguments: ["context": context], in: .page, frame: frame.info)
            if isIt as? Bool == true { return index }
        }
        throw BrowserTool.Failure(message: "No frame of this window is \(context)")
    }

    /// Where a frame's viewport starts in the top one. A frame cannot see past its own edges, and
    /// its parent cannot name a cross-origin child — but it can recognise the child's message.
    private static func offset(ofFrame context: String, in tab: BrowserTab) async throws -> CGPoint {
        let frames = try await frames(of: tab)
        var index = try await find(context, among: frames, in: tab)
        var offset = CGPoint.zero
        while let parent = frames[index].parent {
            let token = UUID().uuidString
            let listening = Task { @MainActor in
                try? await tab.callWithoutGesture(Self.listen, arguments: ["token": token], in: .page,
                                                  frame: frames[parent].info) as? [Double]
            }
            try? await Task.sleep(for: .milliseconds(50))
            _ = try? await tab.callWithoutGesture("parent.postMessage({ savoiaFrame: token }, '*')",
                                                  arguments: ["token": token], in: .page, frame: frames[index].info)
            guard let step = await listening.value, step.count == 2 else {
                throw BrowserTool.Failure(message: "The frame's place in its parent could not be found")
            }
            offset.x += step[0]
            offset.y += step[1]
            index = parent
        }
        return offset
    }

    private static let listen = """
        return new Promise(resolve => {
            const hear = event => {
                if (!event.data || event.data.savoiaFrame !== token) return;
                event.stopImmediatePropagation();
                removeEventListener('message', hear, true);
                const frame = [...document.querySelectorAll('iframe, frame, object, embed')]
                    .find(element => element.contentWindow === event.source);
                if (!frame) return resolve(null);
                const box = frame.getBoundingClientRect();
                resolve([box.left + frame.clientLeft, box.top + frame.clientTop]);
            };
            addEventListener('message', hear, true);
            setTimeout(() => resolve(null), 2000);
        });
        """

    // MARK: Storage access

    /// The last two labels: what WebKit calls the domain of every host the wpt stand serves.
    private static func site(_ host: String) -> String {
        host.split(separator: ".").suffix(2).joined(separator: ".")
    }

    /// WebKit keeps this one itself, and offers a way to grant it and none to take it back: `prompt`
    /// and `denied` are answered as done when nothing was granted.
    private static func grantStorageAccess(_ args: ACPJSON, tab: BrowserTab, browser: BrowserState) async throws -> String {
        guard args["state"]?.stringValue == "granted" else { return "ok" }
        guard let host = URL(string: args["origin"]?.stringValue ?? "")?.host(),
              let top = URL(string: args["top"]?.stringValue ?? "")?.host(),
              let profile = browser.profiles.first(where: { $0.id == tab.profileID }) else {
            throw BrowserTool.Failure(message: "origin and top are required")
        }
        let store = browser.dataStore(for: profile)
        guard store.responds(to: #selector(StorageAccessGrants.grant(_:subFrameDomains:completionHandler:))) else {
            throw BrowserTool.Failure(message: "This WebKit cannot grant storage access")
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            unsafeBitCast(store, to: StorageAccessGrants.self).grant(site(top), subFrameDomains: [site(host)]) { continuation.resume() }
        }
        return "ok"
    }
}

private struct Box<Value>: @unchecked Sendable {
    let value: Value
}

@objc private protocol FrameTrees {
    @objc(_frames:)
    func frames(_ completionHandler: @escaping @MainActor (Any?) -> Void)
}

@objc private protocol StorageAccessGrants {
    @objc(_grantStorageAccessForTesting:withSubFrameDomains:completionHandler:)
    func grant(_ topFrameDomain: String, subFrameDomains: [String], completionHandler: @escaping @MainActor () -> Void)
}
