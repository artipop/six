import Foundation

/// `SIX_WEBMCP_SELFTEST=<address of Tests/WebMCP/webmcp.html>`: does a page's `registerTool` reach
/// six, and does a call come back.
///
/// Asked out loud, against the real engine, on a run nobody is watching — the way
/// `BookmarkSelfTest` asks about the index — because the half of this feature that can go wrong is
/// the half no unit test reaches: whether the user script lands in the page's world, whether the
/// channel is there before the page's first script, whether a call's promise and its signal travel.
/// In `SixCore` because the question is the same on every front; a front hands over the window, a
/// way to load an address in it, and a way to run a function body in its page.
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
    static func run(host: WebMCPHost, windowID: UUID, page: String,
                    load: @escaping @MainActor (String) -> Void,
                    run: @escaping @MainActor (String) async throws -> Void) async -> String {
        var report = Report()
        func names() -> [String] { host.tools(in: windowID).map(\.name) }
        func call(_ name: String, _ arguments: ACPJSON = [:], timeout: Duration = .seconds(10)) async -> Result<String, any Error> {
            do {
                return .success(try await host.call(name, arguments: arguments, in: windowID, timeout: timeout, run: run))
            } catch {
                return .failure(error)
            }
        }
        func status() async -> ACPJSON? {
            guard case .success(let text) = await call("status") else { return nil }
            return try? JSONDecoder().decode(ACPJSON.self, from: Data(text.utf8))
        }

        load(page)
        let declared = await waitUntil { Set(names()).isSuperset(of: ["add", "slow", "forget_slow", "status"]) }
        report.check(declared, "the page declared add, slow, forget_slow and status — \(names())")
        guard declared else { return report.finish() }

        let tools = host.tools(in: windowID)
        let add = tools.first { $0.name == "add" }
        report.check(add?.readOnly == true && add?.title == "Add", "add is read-only and titled Add")
        report.check(tools.first { $0.name == "slow" }?.readOnly == false, "slow is not read-only")
        report.check(add?.inputSchema["required"] == ["a", "b"], "add's schema came across whole")
        report.check(add?.origin.isEmpty == false, "the tools carry an origin — \(add?.origin ?? "none")")

        let sum = await call("add", ["a": 2, "b": 3])
        report.check((try? sum.get()) == "5", "add(2, 3) answered 5 — \(describe(sum))")

        let seen = await status()
        report.check(seen?["same"] == true, "document.modelContext and navigator.modelContext are one object")
        report.check(seen?["tools"] == 4, "getTools() in the page sees four — \(seen?["tools"]?.description ?? "no answer")")

        let slow = await call("slow", ["ms": 5000], timeout: .seconds(1))
        report.check(isError(slow, .timedOut(.seconds(1))), "slow(5 s) timed out at 1 s — \(describe(slow))")
        var aborted = false
        for _ in 0..<30 where !aborted {
            if await status()?["aborts"] == 1 { aborted = true } else { try? await Task.sleep(for: .milliseconds(100)) }
        }
        report.check(aborted, "the timeout fired the tool's signal in the page")

        let forgot = await call("forget_slow")
        let gone = await waitUntil(seconds: 3) { !names().contains("slow") }
        report.check((try? forgot.get()) != nil && gone && names().count == 3,
                     "aborting slow's registration signal unregistered it — \(names())")
        let missing = await call("slow")
        report.check(isNoSuchTool(missing), "a call to slow now fails before reaching the page — \(describe(missing))")

        load(page + (page.contains("?") ? "&" : "?") + "again")
        let back = await waitUntil { Set(names()) == ["add", "slow", "forget_slow", "status"] }
        report.check(back, "the next document came with its own four tools — \(names())")

        // A navigation in the middle of a call. `about:blank` has no polyfill to announce itself, so
        // this is also the front's backstop being tested: the call has to end on the navigation it
        // observed, not on a message from a page that never comes.
        let leave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            load("about:blank")
        }
        let interrupted = await call("slow", ["ms": 10_000], timeout: .seconds(30))
        await leave.value
        report.check(isError(interrupted, .navigatedAway), "a navigation during slow(10 s) ended the call — \(describe(interrupted))")
        let empty = await waitUntil(seconds: 5) { names().isEmpty }
        report.check(empty, "about:blank offers nothing — \(names())")

        return report.finish()
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

    private static func describe(_ result: Result<String, any Error>) -> String {
        switch result {
        case .success(let text): "answered \"\(text.prefix(80))\""
        case .failure(let error): "failed: \(error.localizedDescription)"
        }
    }
}
