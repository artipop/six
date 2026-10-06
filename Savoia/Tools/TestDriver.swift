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
                        return try await setStorageAccess(args, tab: tab)
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
                             .init(name: "action", description: "`down`, `up` or `move` for half a click; both halves when absent."),
                             context],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue else {
                        throw BrowserTool.Failure(message: "x and y are required")
                    }
                    var point = CGPoint(x: x, y: y)
                    var view = tab.livePage
                    if let wanted = args["context"]?.stringValue {
                        let place = try await place(ofFrame: wanted, in: tab)
                        point.x += place.offset.x
                        point.y += place.offset.y
                        view = place.view
                    }
                    let sent = switch args["action"]?.stringValue {
                    case "down": view?.mouse(.leftMouseDown, atViewport: point)
                    case "up": view?.mouse(.leftMouseUp, atViewport: point)
                    case "move": view?.mouse(.mouseMoved, atViewport: point)
                    default: view?.click(atViewport: point)
                    }
                    guard sent == true else { throw BrowserTool.Failure(message: "The window's page is not on screen") }
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_key",
                description: "A key of the keyboard, as `KeyboardEvent.key` names it, going down, up, or both.",
                parameters: [window,
                             .init(name: "key", description: "`Enter`, `Tab`, `ArrowDown`, `Meta`…, or one character.", required: true),
                             .init(name: "action", description: "`down` or `up`; a press when absent."),
                             .init(name: "modifiers", description: "The modifiers held meanwhile, as `Meta+Shift`.")],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let key = PageKey(args["key"]?.stringValue ?? "") else {
                        throw BrowserTool.Failure(message: "No key of the keyboard is \(args["key"]?.stringValue ?? "")")
                    }
                    let view = tab.livePage
                    let held = NSEvent.ModifierFlags(pageKeys: args["modifiers"]?.stringValue ?? "")
                    let sent = switch args["action"]?.stringValue {
                    case "down": view?.key(key, down: true, holding: held)
                    case "up": view?.key(key, down: false, holding: held)
                    default: view?.press(key, holding: held)
                    }
                    guard sent == true else { throw BrowserTool.Failure(message: "The window's page is not on screen") }
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
                    let frame = frames[try await find(args["context"]?.stringValue ?? "", among: frames)]
                    let value = try await frame.view.callWithoutGesture(args["script"]?.stringValue ?? "", in: .page,
                                                                        frame: frame.info)
                    return value as? String ?? ""
                }
            ),
            BrowserTool(
                name: "testdriver_view_state",
                description: "Where the window's web view is: on file, in which window, and the page's fullscreen state.",
                parameters: [window],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    let view = tab.livePage
                    let host = view?.window.map { String(describing: type(of: $0)) } ?? "no window"
                    let state = tab.livePage.map { "\($0.fullscreenState)" } ?? "no page"
                    return "view \(view == nil ? "not on file" : "on file"), in \(host), superview \(view?.superview == nil ? "none" : "yes"), fullscreen \(state)"
                }
            ),
            BrowserTool(
                name: "testdriver_discard_pages",
                description: "Gives back the page of every window that is not on screen, as the page budget would.",
                surfaces: .mcp,
                run: { _ in
                    browser.pages.discardBackgroundPages()
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_close_windows",
                description: "Closes the windows pages opened by script.",
                surfaces: .mcp,
                run: { _ in
                    ScriptedPopups.closeAll()
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_answer_sheets",
                description: "Presses the first button, or the second, of every sheet on the windows pages opened by script.",
                parameters: [.init(name: "accept", description: "False presses the second button.", type: .boolean)],
                surfaces: .mcp,
                run: { args in
                    "\(ScriptedPopups.answerSheets(accepting: args["accept"]?.boolValue ?? true)) answered"
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
        let view: WKWebView
    }

    /// The tab's frames, then those of the windows pages opened: a test's frame may be in either.
    private static func frames(of tab: BrowserTab) async throws -> [Frame] {
        guard let own = tab.livePage, own.responds(to: #selector(FrameTrees.frames(_:))) else {
            throw BrowserTool.Failure(message: "The window's page is not on screen")
        }
        var found: [Frame] = []
        for view in [own] + ScriptedPopups.views {
            let root: Box<NSObject?> = await withCheckedContinuation { continuation in
                unsafeBitCast(view, to: FrameTrees.self).frames { continuation.resume(returning: Box(value: $0 as? NSObject)) }
            }
            func walk(_ node: NSObject, parent: Int?) {
                guard let info = node.value(forKey: "info") as? WKFrameInfo else { return }
                found.append(Frame(info: info, parent: parent, view: view))
                let index = found.count - 1
                for child in node.value(forKey: "childFrames") as? [NSObject] ?? [] { walk(child, parent: index) }
            }
            if let node = root.value { walk(node, parent: nil) }
        }
        return found
    }

    /// The frame whose window testdriver gave this id (`get_window_id` in testdriver-extra.js).
    private static func find(_ context: String, among frames: [Frame]) async throws -> Int {
        // `url:` and a piece of the frame's address, for probing a frame testdriver has not named.
        if context.hasPrefix("url:"), let index = frames.firstIndex(where: {
            $0.info.request.url?.absoluteString.contains(context.dropFirst(4)) == true
        }) { return index }
        for (index, frame) in frames.enumerated() {
            let isIt = try? await frame.view.callWithoutGesture("return window.__wptrunner_id === context",
                                                                arguments: ["context": context], in: .page, frame: frame.info)
            if isIt as? Bool == true { return index }
        }
        throw BrowserTool.Failure(message: "No frame of this window is \(context)")
    }

    /// Where a frame's viewport starts in the top one. A frame cannot see past its own edges, and
    /// its parent cannot name a cross-origin child — but it can recognise the child's message.
    private static func place(ofFrame context: String, in tab: BrowserTab) async throws -> (offset: CGPoint, view: WKWebView) {
        let frames = try await frames(of: tab)
        var index = try await find(context, among: frames)
        let view = frames[index].view
        var offset = CGPoint.zero
        while let parent = frames[index].parent {
            let token = UUID().uuidString
            let listening = Task { @MainActor in
                try? await view.callWithoutGesture(Self.listen, arguments: ["token": token], in: .page,
                                                   frame: frames[parent].info) as? [Double]
            }
            try? await Task.sleep(for: .milliseconds(50))
            _ = try? await view.callWithoutGesture("parent.postMessage({ savoiaFrame: token }, '*')",
                                                   arguments: ["token": token], in: .page, frame: frames[index].info)
            guard let step = await listening.value, step.count == 2 else {
                throw BrowserTool.Failure(message: "The frame's place in its parent could not be found")
            }
            offset.x += step[0]
            offset.y += step[1]
            index = parent
        }
        return (offset, view)
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

    private typealias Done = @convention(c) (UnsafeMutableRawPointer?) -> Void

    /// WebKit keeps this one itself. The call is the one its own automation makes for WebDriver's
    /// Set Permission, and it is in the C API only.
    private static func setStorageAccess(_ args: ACPJSON, tab: BrowserTab) async throws -> String {
        typealias Text = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
        typealias Store = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
        typealias Release = @convention(c) (UnsafeRawPointer?) -> Void
        typealias Set = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Bool, UnsafeRawPointer?, UnsafeRawPointer?,
                                        UnsafeMutableRawPointer?, Done) -> Void
        guard let origin = args["origin"]?.stringValue, let top = args["top"]?.stringValue else {
            throw BrowserTool.Failure(message: "origin and top are required")
        }
        let webKit = UnsafeMutableRawPointer(bitPattern: -2)
        guard let view = tab.livePage, view.responds(to: #selector(PageRefs.pageRef)),
              let page = unsafeBitCast(view, to: PageRefs.self).pageRef(),
              let text = dlsym(webKit, "WKStringCreateWithUTF8CString"), let store = dlsym(webKit, "WKPageGetWebsiteDataStore"),
              let release = dlsym(webKit, "WKRelease"),
              let set = dlsym(webKit, "WKWebsiteDataStoreSetStorageAccessPermissionForTesting") else {
            throw BrowserTool.Failure(message: "This WebKit cannot set storage access")
        }
        let topFrame = unsafeBitCast(text, to: Text.self)(top)
        let subFrame = unsafeBitCast(text, to: Text.self)(origin)
        let granted = args["state"]?.stringValue == "granted"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiting = Unmanaged.passRetained(Waiting(continuation: continuation)).toOpaque()
            unsafeBitCast(set, to: Set.self)(unsafeBitCast(store, to: Store.self)(page), page, granted, topFrame, subFrame, waiting) {
                Unmanaged<Waiting>.fromOpaque($0!).takeRetainedValue().continuation.resume()
            }
        }
        unsafeBitCast(release, to: Release.self)(topFrame)
        unsafeBitCast(release, to: Release.self)(subFrame)
        return "ok"
    }
}

private final class Waiting {
    let continuation: CheckedContinuation<Void, Never>
    init(continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
}

private struct Box<Value>: @unchecked Sendable {
    let value: Value
}

@objc private protocol FrameTrees {
    @objc(_frames:)
    func frames(_ completionHandler: @escaping @MainActor (Any?) -> Void)
}

@objc private protocol PageRefs {
    @objc(_pageRefForTransitionToWKWebView)
    func pageRef() -> UnsafeRawPointer?
}
