import CWebKit2
import Foundation
import SixBrowser
@testable import SixCore
import WinSDK

/// WebMCP on this front: the three things `WebMCPPage` says every front owes, over the WebKit2 C
/// API — a user script, a message handler, and a way to run a function body in the page. Everything
/// else (the registry, the calls, what a navigation means, the self-test) is `WebMCPHost`, in
/// `SixCore`, and is the Mac's code as much as this front's.
///
/// **Only a page built after this knows about it.** A page's user content is fixed in its
/// `WKPageConfiguration` when the `WKView` is made, so `userContent(for:)` is asked for in
/// `RailLiveView.makeWebView` and WebMCP is decided once, at launch (`WebMCPHost.isWanted`). Off,
/// it hands back `nil` and the page is configured exactly as it was before this file existed.
@MainActor
final class RailWebMCP {
    let host = WebMCPHost()
    let isEnabled: Bool
    /// One per page, and what a message's C callback finds its window through. Each holds the
    /// controller it was made for, at +1, until the window goes.
    private var channels: [Foundation.UUID: Channel] = [:]

    private weak var model: RailModel?

    init(model: RailModel, onChange: @escaping () -> Void) {
        self.model = model
        isEnabled = WebMCPHost.isWanted(setting: ConfigurationStore.shared?.webMCP == true)
        host.onChange = { _ in onChange() }
        // The gate (docs/webmcp.md, stage 3): which site a column is on, and how a question reaches
        // the person. Both through `RailModel`, where the queue and the bar already are.
        host.origin = { [weak model] tabID in model?.siteOrigin(of: tabID) }
        host.ask = { [weak model] ask, answer in
            guard let model else { return answer(false) }
            if let tool = ask.tool {
                model.confirmPageToolCall(tool: tool.name, arguments: ask.arguments,
                                          origin: ask.origin, tabID: ask.windowID, then: answer)
            } else {
                model.askPageTools(origin: ask.origin, tabID: ask.windowID, then: answer)
            }
        }
        if isEnabled { Log.info(.mcp, "webmcp: on — pages may declare tools for agents") }
    }

    /// The user content controller a new page is configured with — `nil` when WebMCP is off, and
    /// for a private column, where it is off whatever the setting says.
    func userContent(for tabID: Foundation.UUID) -> WKUserContentControllerRef? {
        guard isEnabled, model?.isPrivateColumn(tabID) != true else { return nil }
        if let existing = channels[tabID] { return existing.controller }
        guard let controller = WKUserContentControllerCreate() else { return nil }
        let channel = Channel(tabID: tabID, host: host, controller: controller)
        channels[tabID] = channel

        if let name = RailWebView.wkString(WebMCPScript.handlerName) {
            // The context is the channel, unretained: `channels` keeps it for as long as the page
            // can post, and `forget` takes the handler off the controller before letting it go.
            WKUserContentControllerAddScriptMessageHandler(controller, name, { message, reply, context in
                // Nothing in the page waits for an answer, but the listener is WebKit's to close.
                if let reply { WKCompletionListenerComplete(reply, nil) }
                guard let message, let context, let body = WKScriptMessageGetBody(message),
                      WKGetTypeID(body) == WKStringGetTypeID() else { return }
                let channel = Unmanaged<Channel>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    channel.host?.receive(RailWebView.string(from: OpaquePointer(body)), from: channel.tabID)
                }
            }, UnsafeRawPointer(Unmanaged.passUnretained(channel).toOpaque()))
            WKRelease(UnsafeRawPointer(name))
        }
        if let source = RailWebView.wkString(WebMCPScript.source) {
            // Document start, main frame only: the Mac's `WKUserScript` in the same words.
            if let script = WKUserScriptCreateWithSource(source, kWKInjectAtDocumentStart, true) {
                WKUserContentControllerAddUserScript(controller, script)
                WKRelease(UnsafeRawPointer(script))
            }
            WKRelease(UnsafeRawPointer(source))
        }
        return controller
    }

    /// A navigation finished — the earliest this front is told of one (`WebMCPHost.pageNavigated`).
    func pageLoaded(_ tabID: Foundation.UUID, view: RailWebView) {
        guard isEnabled else { return }
        host.pageNavigated(tabID, page: view)
    }

    func forget(_ tabID: Foundation.UUID) {
        host.forget(tabID)
        guard let channel = channels.removeValue(forKey: tabID) else { return }
        WKUserContentControllerRemoveAllUserMessageHandlers(channel.controller)
        WKRelease(UnsafeRawPointer(channel.controller))
    }
}

/// The third of the three: `WKPageCallAsyncJavaScript` runs in the page's world, which is where the
/// polyfill is — measured by the self-test, since the C API does not take a world to say so.
extension RailWebView: WebMCPPage {
    func evaluateInPage(_ body: String) async throws -> String {
        try await callAsync(body, input: "")
    }
}

/// What the C callback's context points at.
private final class Channel {
    let tabID: Foundation.UUID
    weak var host: WebMCPHost?
    let controller: WKUserContentControllerRef

    init(tabID: Foundation.UUID, host: WebMCPHost, controller: WKUserContentControllerRef) {
        self.tabID = tabID
        self.host = host
        self.controller = controller
    }
}

extension RailWindow {
    // MARK: The badge

    /// How many tools the page on screen declares — the badge at the end of the address field, the
    /// Mac's `PageToolsButton`. Zero draws nothing and takes no room from the field.
    var focusedPageToolCount: Int {
        guard webMCP.isEnabled, let focused = model.columns.first(where: \.isFocused) else { return 0 }
        return webMCP.host.tools(in: focused.id).count
    }

    /// What the `EDIT` gives up at the end of the pill while there is a badge to draw.
    var pageToolsBadgeWidth: Int32 { focusedPageToolCount > 0 ? px(44) : 0 }

    /// A wrench and a number in a capsule, inside the pill's right end. No list behind it yet: the
    /// Mac's is a popover, and this front's first list panel is on another branch.
    func drawPageToolsBadge(_ hdc: HDC, in pill: RECT) {
        let count = focusedPageToolCount
        guard count > 0, pill.right > pill.left else { return }
        let height = px(18)
        let width = px(36)
        let right = pill.right - px(8)
        let top = pill.top + (pill.bottom - pill.top - height) / 2
        let badge = RECT(left: right - width, top: top, right: right, bottom: top + height)
        // Lit while a call is in flight: a page's tool running for an agent is something happening
        // in the person's session, and it says so while it happens (docs/webmcp.md, stage 3).
        let focused = model.columns.first(where: \.isFocused)?.id
        let running = focused.map { webMCP.host.activity[$0] != nil } ?? false
        let accent = Self.color(hex: model.activeProfile.colorHex)
        roundedRect(hdc, badge, radius: height / 2, fill: running ? accent : Self.chipColor,
                    border: running ? accent : Self.addressBorderColor, borderWidth: 1)
        let middle = badge.left + width / 2
        // E90F is the icon font's "Repair", its wrench — the nearest thing it has to the Mac's
        // `wrench.and.screwdriver`. Outside the range the glyph sheet above was drawn from, so it
        // was checked on its own, in a `PrintWindow` capture of the test page.
        drawText(hdc, "\u{E90F}", in: RECT(left: badge.left + px(3), top: badge.top, right: middle + px(1), bottom: badge.bottom),
                 font: fonts.glyph, color: Self.labelColor, format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
        drawText(hdc, "\(count)", in: RECT(left: middle - px(1), top: badge.top, right: badge.right - px(3), bottom: badge.bottom),
                 font: fonts.small, color: Self.textColor, format: DT_CENTER | DT_VCENTER | DT_SINGLELINE)
    }

    // MARK: The self-test

    /// `SIX_WEBMCP_SELFTEST=<page>`, in the focused column once it has a live page — which is the
    /// first repaint after `show`, so the host waits for one.
    func runWebMCPSelfTestIfAsked() {
        webMCP.host.runSelfTestIfAsked { [weak self] in
            guard let self, let focused = model.columns.first(where: \.isFocused),
                  let view = webViews[focused.id] else { return nil }
            return WebMCPSelfTest.Target(
                windowID: focused.id,
                page: view,
                load: { [weak view] address in view?.load(address) },
                question: { [weak self] in self?.model.permissionPrompt(for: focused.id) },
                answer: { [weak self] allowed in
                    self?.model.answerPermission(allowed, for: focused.id)
                    self?.invalidate()
                },
                forgetSite: { [weak self] in self?.model.forgetPageToolsAnswer(for: focused.id) })
        }
    }
}
