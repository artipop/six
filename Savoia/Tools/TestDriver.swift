import AppKit
import WebKit

/// `SAVOIA_TESTDRIVER=1`: what wpt's testdriver asks of a browser, as tools for the runner (docs/test-suites.md).
@MainActor
enum TestDriver {
    nonisolated static let isOn = ProcessInfo.processInfo.environment["SAVOIA_TESTDRIVER"] != nil

    static func tools(browser: BrowserState, tab: @escaping (ACPJSON) throws -> BrowserTab) -> [BrowserTool] {
        let window = BrowserTool.Parameter(name: "window_id", description: "Window id.", required: true)
        return [
            BrowserTool(
                name: "testdriver_set_permission",
                description: "Files an answer for an origin, as the permission bar would: `granted`, `denied`, or `prompt` to forget it.",
                parameters: [window,
                             .init(name: "origin", description: "The origin, as `location.origin` writes it.", required: true),
                             .init(name: "permission", description: "The permission's name in the Permissions API.", required: true),
                             .init(name: "state", description: "`granted`, `denied` or `prompt`.", required: true)],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    let name = args["permission"]?.stringValue ?? ""
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
                             .init(name: "y", description: "From the viewport's top edge.", type: .integer, required: true)],
                surfaces: .mcp,
                run: { args in
                    let tab = try tab(args)
                    guard let view = WebViewResponder.shared.webView(for: tab.id), let host = view.window else {
                        throw BrowserTool.Failure(message: "The window's page is not on screen")
                    }
                    guard let x = args["x"]?.doubleValue, let y = args["y"]?.doubleValue else {
                        throw BrowserTool.Failure(message: "x and y are required")
                    }
                    let inView = CGPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
                    let location = view.convert(inView, to: nil)
                    for (type, send) in [(NSEvent.EventType.leftMouseDown, view.mouseDown(with:)),
                                         (.leftMouseUp, view.mouseUp(with:))] {
                        guard let event = NSEvent.mouseEvent(
                            with: type, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                        else { throw BrowserTool.Failure(message: "No event could be made") }
                        send(event)
                    }
                    return "ok"
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
}
