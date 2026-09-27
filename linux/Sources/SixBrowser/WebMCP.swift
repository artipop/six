import CWebKitGTK
import Foundation
import SixWebKitCore

@testable internal import SixCore

/// WebMCP on Linux: the three things `SixCore`'s `WebMCPPage` says a front owes. The script and the
/// channel are `PageChannels` in `SixWebKitCore`, which cannot name WebMCP (see there); this file
/// tells it what to install and where the messages go, and gives the host a page to run in.
/// Everything else — the registry, the calls, what a navigation means, the self-test — is
/// `WebMCPHost`, and is the code the Mac and Windows already run.
///
/// **Written on Windows, not yet built or run.** docs/webmcp.md lists what the first container run
/// has to answer; `SIX_WEBMCP_SELFTEST` is how it answers it. There is no MCP server on this front,
/// so what an agent could do with the tools is not here yet — the self-test and `pageToolCount` are
/// the whole of what uses the registry.
extension BrowserModel {
    /// Called from `init`, before the first page is built: a page takes its user scripts when it is
    /// made, and nothing added later reaches it.
    func startWebMCP() {
        guard WebMCPHost.isWanted(setting: settings?.webMCP == true) else { return }
        let host = webMCP
        PageChannels.channels = [
            PageChannels.Channel(
                source: WebMCPScript.source,
                handlerName: WebMCPScript.handlerName,
                receive: { [weak host] tabID, text in host?.receive(text, from: tabID) }
            )
        ]
        PageChannels.isAllowed = { [weak self] _ in self?.isPrivate == false }
        // The gate (docs/webmcp.md, stage 3): the site once, then every call the page did not mark
        // read-only — through the queue and the bar the camera already uses.
        host.origin = { [weak self] tabID in self?.siteOrigin(of: tabID) }
        host.ask = { [weak self] ask, answer in
            guard let self, let permissions, !isPrivate else { return answer(false) }
            let profile = layout.activeProfileID
            if let tool = ask.tool {
                permissions.confirmPageToolCall(tool: tool.name, arguments: ask.arguments,
                                                origin: ask.origin, in: ask.windowID,
                                                profileID: profile, then: answer)
            } else {
                permissions.decidePageTools(origin: ask.origin, in: ask.windowID,
                                            profileID: profile, then: answer)
            }
        }
        Log.info(.mcp, "webmcp: on — pages may declare tools for agents")
        host.runSelfTestIfAsked { [weak self] in
            guard let self, let tabID = focusedTabID, let page = LivePage.focused(tabID) else { return nil }
            return WebMCPSelfTest.Target(
                windowID: tabID,
                page: page,
                load: { address in webkit_web_view_load_uri(page.view, address) },
                question: { [weak self] in self?.permissions?.question(for: tabID)?.prompt },
                answer: { [weak self] allowed in
                    self?.permissions?.answer(allowed, for: tabID)
                    self?.onPermissionQuestion?()
                },
                forgetSite: { [weak self] in
                    guard let self, let origin = siteOrigin(of: tabID) else { return }
                    permissions?.forget(.pageTools, forOrigin: origin, profileID: layout.activeProfileID)
                })
        }
    }

    /// A page finished loading — the only navigation this front hears of
    /// (`WebMCPHost.pageNavigated`). Nothing to ask when WebMCP is off: no page has the polyfill.
    func webMCPPageLoaded(_ tabID: UUID) {
        guard !PageChannels.channels.isEmpty else { return }
        webMCP.pageNavigated(tabID, page: LivePage.focused(tabID))
    }

    /// The site a column is on, as an answer is filed under.
    func siteOrigin(of tabID: UUID) -> String? {
        SitePermissions.origin(of: PageRegistry.url(of: tabID) ?? url(of: tabID))
    }

    /// How many tools the page in a column declares — what the Mac and Windows draw as a badge by
    /// the address, for when this front's bar draws one.
    public func pageToolCount(for tabID: UUID) -> Int {
        webMCP.tools(in: tabID).count
    }
}

/// The third of the three: `callAsync` runs in the page's own world (`world: nil`), which is where
/// the polyfill is.
extension LivePage: WebMCPPage {
    func evaluateInPage(_ body: String) async throws -> String {
        try await callAsync(body, input: "")
    }
}
