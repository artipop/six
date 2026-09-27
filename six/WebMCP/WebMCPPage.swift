import Foundation

/// What a front's page has to offer WebMCP — and, in the extension below, the half of every front's
/// bridge that is the same on all of them.
///
/// A front owes three things, and only the third is a call:
///
/// 1. `WebMCPScript.source` as a user script at document start, main frame only, **in the page's
///    own world**;
/// 2. a script message handler named `WebMCPScript.handlerName` in that world, whose messages —
///    JSON text — go to `WebMCPHost.receive(_:from:)` with the window they came from;
/// 3. a way to run a function body in the page's world: this protocol.
///
/// The first two are fixed when a page is configured, and every WebKit six runs on spells them
/// differently — `WKUserContentController` on Apple, `WebKitUserContentManager` on Linux,
/// `WKUserContentControllerRef` on Windows — so they stay with the front. Everything a front then
/// does with them is the same everywhere, and is here: deciding whether WebMCP is on, asking a page
/// which document it shows after a navigation, starting a call, and finding a window for the
/// self-test. A front's bridge is what is left: three calls into its own engine.
@MainActor
protocol WebMCPPage: AnyObject {
    /// Runs a function body in the page's own world and returns its value as a string — empty
    /// when it returned nothing that is one.
    func evaluateInPage(_ body: String) async throws -> String
}

extension WebMCPHost {
    /// Whether this run has WebMCP: the setting (`ConfigurationStore.webMCP`), `SIX_WEBMCP=1`, or a
    /// self-test, which switches it on whatever the setting says.
    nonisolated static func isWanted(setting: Bool) -> Bool {
        setting || ProcessInfo.processInfo.environment["SIX_WEBMCP"] == "1" || WebMCPSelfTest.isAsked
    }

    /// A window's page has navigated — committed on the Mac, finished on the fronts that are told
    /// nothing earlier. Nothing is cleared outright: the polyfill in the new page announces itself
    /// and has usually done so already. The page is asked which document it is showing, and the
    /// registry drops whatever belonged to another one (`WebMCPRegistry.settle`) — the backstop for
    /// the documents the polyfill never runs in. `nil` is a window with no page at all.
    func pageNavigated(_ windowID: UUID, page: (any WebMCPPage)?) {
        guard let page else {
            settle(windowID, document: nil)
            return
        }
        Task { [weak self] in
            let document = (try? await page.evaluateInPage(WebMCPScript.documentQuery)) ?? ""
            self?.settle(windowID, document: document.isEmpty ? nil : document)
        }
    }

    /// `call(_:arguments:in:timeout:run:)` over a `WebMCPPage`, asked for afresh at every step, so a
    /// page that has gone by then is a navigation rather than a call into nothing.
    func call(_ name: String, arguments: ACPJSON, in windowID: UUID,
              on page: @escaping @MainActor () -> (any WebMCPPage)?,
              timeout: Duration = defaultTimeout) async throws -> String {
        try await call(name, arguments: arguments, in: windowID, timeout: timeout) { body in
            guard let page = page() else { throw WebMCPError.navigatedAway }
            _ = try await page.evaluateInPage(body)
        }
    }

    /// `SIX_WEBMCP_SELFTEST=<page>`: `WebMCPSelfTest` in whatever window `target` names, once it
    /// names one — a front's first window can take a moment to have a page. Reported through `Log`
    /// rather than `print`, because a front whose stdout is a file never flushes a `print`.
    func runSelfTestIfAsked(_ target: @escaping @MainActor () -> WebMCPSelfTest.Target?) {
        guard let address = WebMCPSelfTest.page else { return }
        Task { [weak self] in
            var found: WebMCPSelfTest.Target?
            for _ in 0..<150 where found == nil {
                found = target()
                if found == nil { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard let self, let found else {
                Log.error(.mcp, "webmcp self-test: no window with a page to run in")
                return
            }
            let report = await WebMCPSelfTest.run(host: self, target: found, page: address)
            Log.info(.mcp, "webmcp self-test\n" + report)
        }
    }
}
