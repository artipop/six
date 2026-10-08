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
                    try await setPermission(args["permission"]?.stringValue ?? "", to: args["state"]?.stringValue ?? "",
                                            origin: args["origin"]?.stringValue, top: args["top"]?.stringValue,
                                            tab: try tab(args), browser: browser)
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_set_geolocation",
                description: "The position pages are given in place of the Mac's own; with neither argument, none.",
                parameters: [.init(name: "coordinates", description: "JSON: `latitude`, `longitude`, `accuracy`, and optionally `altitude`, `altitudeAccuracy`, `heading`, `speed`."),
                             .init(name: "error", description: "`positionUnavailable`, for a position that cannot be found.")],
                surfaces: .mcp,
                run: { args in
                    let read = args["coordinates"]?.stringValue.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                    try setGeolocation(coordinates: read as? [String: Any], unavailable: args["error"]?.stringValue != nil)
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_answer_permission",
                description: "Presses Allow or Block on the permission bar the window is showing.",
                parameters: [window, .init(name: "allow", description: "true or false.", type: .boolean, required: true)],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let question = browser.permissions?.question(for: tab.id) else {
                        throw BrowserTool.Failure(message: "The window is asking nothing")
                    }
                    browser.permissions?.answer(args["allow"]?.boolValue ?? false, for: tab.id)
                    return "\(question.origin) \(question.permissions.map(\.rawValue).joined(separator: "+"))"
                }
            ),
            BrowserTool(
                name: "testdriver_reset",
                description: "What one test file must not leave for the next: answers about location and notifications, the stand-in position, and every notification shown.",
                surfaces: .mcp,
                run: { _ in
                    reset(browser)
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
                        let place = try await place(ofFrame: wanted, in: tab, browser: browser)
                        point.x += place.offset.x
                        point.y += place.offset.y
                        view = place.view
                    }
                    // A view behind another tab is in no window; its tab comes forward first, as WebDriver switches windows.
                    if let target = view, target.window == nil, let owner = browser.tabs.first(where: { $0.livePage === target }) {
                        browser.selectTab(owner.id)
                        for _ in 0..<20 where target.window == nil { try? await Task.sleep(for: .milliseconds(50)) }
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
                    // A view behind another tab is in no window; its tab comes forward first, as WebDriver switches windows.
                    if let target = view, target.window == nil, let owner = browser.tabs.first(where: { $0.livePage === target }) {
                        browser.selectTab(owner.id)
                        for _ in 0..<20 where target.window == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    }
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
                    let frames = try await frames(of: tab, browser: browser)
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
                name: "testdriver_window_image",
                description: "Draws the window holding the tab, with the tab bar and the address field, into a PNG at `path`.",
                parameters: [window, .init(name: "path", description: "Where the PNG goes.", required: true)],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let content = tab.livePage?.window?.contentView, let path = args["path"]?.stringValue else {
                        throw BrowserTool.Failure(message: "The window's page is not on screen, or no path")
                    }
                    let view = content.superview ?? content
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw BrowserTool.Failure(message: "No bitmap for the window")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw BrowserTool.Failure(message: "The window did not encode")
                    }
                    try png.write(to: URL(fileURLWithPath: path))
                    return "\(bitmap.pixelsWide)×\(bitmap.pixelsHigh)"
                }
            ),
            BrowserTool(
                name: "testdriver_export",
                description: "What Save As would write for the window in a format: its size and how it starts.",
                parameters: [window, .init(name: "format", description: "html, webArchive, pdf or text.", required: true)],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let format = Exporter.Format(rawValue: args["format"]?.stringValue ?? "") else {
                        throw BrowserTool.Failure(message: "No such format")
                    }
                    let data = try await Exporter.data(of: tab, as: format)
                    return "\(data.count) bytes, starting \(String(decoding: data.prefix(8), as: UTF8.self))"
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
                description: "Closes the tabs pages opened by script.",
                surfaces: .mcp,
                run: { _ in
                    browser.closeTabs(browser.tabs.filter(\.isOpenedByPage).map(\.id))
                    return "ok"
                }
            ),
            BrowserTool(
                name: "testdriver_allow_automation",
                description: "Turns Allow Remote Automation on or off, as the switch in Configuration does.",
                parameters: [.init(name: "allow", description: "true or false.", type: .boolean, required: true)],
                surfaces: .mcp,
                run: { args in
                    guard let devTools = browser.devTools else { throw BrowserTool.Failure(message: "No developer tools") }
                    devTools.allowsAutomation = args["allow"]?.boolValue ?? false
                    return devTools.allowsAutomation ? "on" : "off"
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

    // MARK: What the WebDriver server asks for too

    /// Files an answer for an origin, as the permission bar would; `storage-access` is WebKit's own.
    static func setPermission(_ name: String, to state: String, origin: String?, top: String?, tab: BrowserTab,
                              browser: BrowserState) async throws {
        if name == "storage-access" {
            return try await setStorageAccess(origin: origin, top: top, granted: state == "granted", tab: tab)
        }
        // The Permissions API's name for it.
        let known = name == "geolocation" ? .location : SitePermission(rawValue: name)
        guard let permission = known, permission != .pageTools else {
            throw BrowserTool.Failure(message: "Savoia keeps no answer for \(name)")
        }
        guard let origin, let permissions = browser.permissions else {
            throw BrowserTool.Failure(message: "origin is required")
        }
        switch state {
        case "granted": permissions.set(true, permission, forOrigin: origin, profileID: tab.profileID)
        case "denied": permissions.set(false, permission, forOrigin: origin, profileID: tab.profileID)
        case "prompt": permissions.forget(permission, forOrigin: origin, profileID: tab.profileID)
        default: throw BrowserTool.Failure(message: "state must be granted, denied or prompt")
        }
    }

    /// The position pages are given in place of the Mac's own; with neither, none.
    static func setGeolocation(coordinates: [String: Any]?, unavailable: Bool) throws {
        if unavailable {
            Geolocation.shared.override = .unavailable
        } else if let coordinates {
            func number(_ key: String) -> Double? { (coordinates[key] as? NSNumber)?.doubleValue }
            guard let latitude = number("latitude"), let longitude = number("longitude") else {
                throw BrowserTool.Failure(message: "coordinates need a latitude and a longitude")
            }
            Geolocation.shared.override = .position(.init(
                latitude: latitude, longitude: longitude, accuracy: number("accuracy") ?? 1,
                altitude: number("altitude"), altitudeAccuracy: number("altitudeAccuracy"),
                heading: number("heading"), speed: number("speed")))
        } else {
            Geolocation.shared.override = nil
        }
    }

    /// What one test file must not leave for the next.
    static func reset(_ browser: BrowserState) {
        for decision in browser.permissions?.decisions ?? []
        where decision.permission == .location || decision.permission == .notifications {
            browser.permissions?.forget(decision.permission, forOrigin: decision.origin, profileID: decision.profileID)
        }
        Geolocation.shared.override = nil
        SiteNotifications.shared.closeAll()
    }

    // MARK: Frames

    private struct Frame {
        let info: WKFrameInfo
        let parent: Int?
        let view: WKWebView
    }

    /// The tab's frames, then those of the tabs its page opened: a test's frame may be in either.
    private static func frames(of tab: BrowserTab, browser: BrowserState) async throws -> [Frame] {
        guard let own = tab.livePage, own.responds(to: #selector(FrameTrees.frames(_:))) else {
            throw BrowserTool.Failure(message: "The window's page is not on screen")
        }
        var found: [Frame] = []
        for view in [own] + browser.tabs.filter({ $0.openedFrom == tab.id }).compactMap(\.livePage) {
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
    private static func place(ofFrame context: String, in tab: BrowserTab, browser: BrowserState) async throws -> (offset: CGPoint, view: WKWebView) {
        let frames = try await frames(of: tab, browser: browser)
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
    private static func setStorageAccess(origin: String?, top: String?, granted: Bool, tab: BrowserTab) async throws {
        typealias Text = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
        typealias Store = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
        typealias Release = @convention(c) (UnsafeRawPointer?) -> Void
        typealias Set = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, Bool, UnsafeRawPointer?, UnsafeRawPointer?,
                                        UnsafeMutableRawPointer?, Done) -> Void
        guard let origin, let top else {
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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiting = Unmanaged.passRetained(Waiting(continuation: continuation)).toOpaque()
            unsafeBitCast(set, to: Set.self)(unsafeBitCast(store, to: Store.self)(page), page, granted, topFrame, subFrame, waiting) {
                Unmanaged<Waiting>.fromOpaque($0!).takeRetainedValue().continuation.resume()
            }
        }
        unsafeBitCast(release, to: Release.self)(topFrame)
        unsafeBitCast(release, to: Release.self)(subFrame)
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
