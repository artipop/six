import Foundation

/// `SIX_WEBMCP_SELFTEST=<address of Tests/WebMCP/webmcp.html>`: does a page's `registerTool` reach
/// six, does a call come back, and does the gate in front of it ask what it should.
///
/// Asked out loud, against the real engine, on a run nobody is watching — the way
/// `BookmarkSelfTest` asks about the index — because the half of this feature that can go wrong is
/// the half no unit test reaches: whether the user script lands in the page's world, whether the
/// channel is there before the page's first script, whether a call's promise and its signal travel,
/// and whether the questions come up in the right order. In `SixCore` because the question is the
/// same on every front; a front hands over the window, its page, a way to send it somewhere, and
/// the bar it draws questions in.
///
/// The page's four tools are chosen for what they prove: `add` is the plain round trip and the one
/// that is read-only, `slow` answers only when its signal does not fire first, `forget_slow` aborts
/// the signal `slow` was registered with, and `status` is what the page itself saw — answered in
/// MCP's `CallToolResult` shape, which the first origin trial's pages return.
nonisolated enum WebMCPSelfTest {
    /// The test page's address, when a run is asked for. Setting it also switches WebMCP on for the
    /// run, whatever the setting says.
    static var page: String? {
        let value = ProcessInfo.processInfo.environment["SIX_WEBMCP_SELFTEST"] ?? ""
        return value.isEmpty ? nil : value
    }

    static var isAsked: Bool { page != nil }

    @MainActor
    static func run(host: WebMCPHost, target: Target, page address: String) async -> String {
        var report = Report()
        let windowID = target.windowID
        let page = target.page
        func names() -> [String] { host.tools(in: windowID).map(\.name) }
        func runInPage(_ body: String) async throws { _ = try await page.evaluateInPage(body) }

        /// A call, and the question it puts up answered the way this step means to answer it. The
        /// answer goes in as soon as a question appears, which is what a person does; a call that
        /// asks nothing comes back without one and says so.
        func call(_ name: String, _ arguments: ACPJSON = [:], answering answer: Bool? = nil,
                  timeout: Duration = .seconds(10)) async -> (result: Result<String, any Error>, asked: String?) {
            let outcome = Outcome()
            let pending = Task { @MainActor in
                do {
                    let text = try await host.call(name, arguments: arguments, in: windowID,
                                                   timeout: timeout, run: runInPage)
                    outcome.finish(.success(text))
                } catch {
                    outcome.finish(.failure(error))
                }
            }
            var asked: String?
            while !outcome.isDone, asked == nil {
                if let question = target.question() {
                    asked = question
                    target.answer(answer ?? false)
                } else {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            await pending.value
            return (outcome.result ?? .failure(WebMCPError.cancelled), asked)
        }

        target.load(address)
        let declared = await waitUntil { Set(names()).isSuperset(of: ["add", "slow", "forget_slow", "status"]) }
        // After the page is up, because the site is not known until the window is on it.
        target.forgetSite()
        report.check(declared, "the page declared add, slow, forget_slow and status — \(names())")
        guard declared else { return report.finish() }

        let tools = host.tools(in: windowID)
        let add = tools.first { $0.name == "add" }
        report.check(add?.readOnly == true && add?.title == "Add", "add is read-only and titled Add")
        report.check(tools.first { $0.name == "slow" }?.readOnly == false, "slow is not read-only")
        report.check(add?.inputSchema["required"] == ["a", "b"], "add's schema came across whole")
        report.check(add?.origin.isEmpty == false, "the tools carry an origin — \(add?.origin ?? "none")")

        // The gate, in the order docs/webmcp.md's stage 3 puts it: the site once, then every call
        // the page did not mark read-only.
        let first = await call("add", ["a": 2, "b": 3], answering: true)
        report.check(first.asked != nil, "the first call asked about the site — \(first.asked ?? "nothing was asked")")
        report.check((try? first.result.get()) == "5", "…and then add(2, 3) answered 5 — \(describe(first.result))")

        let second = await call("add", ["a": 2, "b": 3], answering: true)
        report.check(second.asked == nil, "a read-only call to an allowed site asks nothing more")
        report.check((try? second.result.get()) == "5", "…and answers — \(describe(second.result))")

        let seen = await call("status", answering: true)
        let status = (try? seen.result.get()).flatMap { try? JSONDecoder().decode(ACPJSON.self, from: Data($0.utf8)) }
        report.check(status?["same"] == true, "document.modelContext and navigator.modelContext are one object")
        report.check(status?["tools"] == 4, "getTools() in the page sees four — \(status?["tools"]?.description ?? "no answer")")

        // A tool that is not read-only is confirmed per call, and a no is a no.
        let refused = await call("forget_slow", answering: false)
        report.check(refused.asked?.contains("forget_slow") == true,
                     "a call that is not read-only asked about the call — \(refused.asked ?? "nothing was asked")")
        report.check(isRefused(refused.result), "…and answering no refused it — \(describe(refused.result))")
        report.check(names().contains("slow"), "…and the page was never asked to run it")

        let slow = await call("slow", ["ms": 5000], answering: true, timeout: .seconds(1))
        report.check(isError(slow.result, .timedOut(.seconds(1))), "slow(5 s) timed out at 1 s — \(describe(slow.result))")
        var aborted = false
        for _ in 0..<30 where !aborted {
            let again = await call("status", answering: true)
            if (try? again.result.get()).flatMap({ try? JSONDecoder().decode(ACPJSON.self, from: Data($0.utf8)) })?["aborts"] == 1 {
                aborted = true
            } else {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        report.check(aborted, "the timeout fired the tool's signal in the page")

        let forgot = await call("forget_slow", answering: true)
        let gone = await waitUntil(seconds: 3) { !names().contains("slow") }
        report.check((try? forgot.result.get()) != nil && gone && names().count == 3,
                     "aborting slow's registration signal unregistered it — \(names())")
        let missing = await call("slow", answering: true)
        report.check(isNoSuchTool(missing.result), "a call to slow now fails before reaching the page — \(describe(missing.result))")

        target.load(address + (address.contains("?") ? "&" : "?") + "again")
        let back = await waitUntil { Set(names()) == ["add", "slow", "forget_slow", "status"] }
        report.check(back, "the next document came with its own four tools — \(names())")
        let remembered = await call("add", ["a": 1, "b": 1], answering: true)
        report.check(remembered.asked == nil, "the site's answer outlived the navigation")

        // A navigation in the middle of a call. `about:blank` has no polyfill to announce itself, so
        // this is also the front's backstop being tested: the call has to end on the navigation it
        // observed, not on a message from a page that never comes.
        let leave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            target.load("about:blank")
        }
        let interrupted = await call("slow", ["ms": 10_000], answering: true, timeout: .seconds(30))
        await leave.value
        report.check(isError(interrupted.result, .navigatedAway),
                     "a navigation during slow(10 s) ended the call — \(describe(interrupted.result))")
        let empty = await waitUntil(seconds: 5) { names().isEmpty }
        report.check(empty, "about:blank offers nothing — \(names())")

        return report.finish()
    }

    /// The window a self-test runs in: its id, its page, how to send it somewhere, and the bar the
    /// front draws questions in — because a gate nobody can answer is a gate nothing gets past.
    struct Target {
        let windowID: UUID
        let page: any WebMCPPage
        let load: @MainActor (String) -> Void
        /// What the window is asking right now, as the bar says it; `nil` when it is asking nothing.
        let question: @MainActor () -> String?
        /// The bar's two buttons.
        let answer: @MainActor (Bool) -> Void
        /// Takes back this site's remembered answer about page tools, so a run measures the
        /// question being asked and not what the run before it answered. A self-test that leaves
        /// state behind passes once and then measures nothing.
        let forgetSite: @MainActor () -> Void
    }

    /// A call's ending, written down by the task that made it so the poller can see it is over.
    @MainActor
    private final class Outcome {
        private(set) var result: Result<String, any Error>?
        var isDone: Bool { result != nil }
        func finish(_ result: Result<String, any Error>) { self.result = result }
    }

    private struct Report {
        var lines: [String] = []
        var failures = 0

        mutating func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "ok    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }

        func finish() -> String {
            (lines + [failures == 0 ? "PASS" : "FAIL — \(failures) of \(lines.count)"]).joined(separator: "\n")
        }
    }

    @MainActor
    private static func waitUntil(seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private static func isError(_ result: Result<String, any Error>, _ expected: WebMCPError) -> Bool {
        if case .failure(let error as WebMCPError) = result { return error == expected }
        return false
    }

    private static func isNoSuchTool(_ result: Result<String, any Error>) -> Bool {
        if case .failure(let error as WebMCPError) = result, case .noSuchTool = error { return true }
        return false
    }

    private static func isRefused(_ result: Result<String, any Error>) -> Bool {
        if case .failure(let error as WebMCPError) = result, case .refused = error { return true }
        return false
    }

    private static func describe(_ result: Result<String, any Error>) -> String {
        switch result {
        case .success(let text): "answered \"\(text.prefix(80))\""
        case .failure(let error): "failed: \(error.localizedDescription)"
        }
    }
}
