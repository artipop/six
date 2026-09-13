import Foundation
import Testing

@testable import SixCore

/// WebMCP's shared half: what a page may say over the channel, how a window's tools follow its
/// document, and how a call ends. The page itself is not here — `WebMCPSelfTest` drives the real
/// one through a real engine, which is the half of this a unit test cannot reach.
struct WebMCPMessageTests {

    @Test func readsARegistration() throws {
        let message = try #require(WebMCPMessage.parse(#"""
            {"kind":"register","doc":"d1","origin":"https://example.com",
             "tool":{"name":"search_flights","title":"Search","description":"Finds flights.",
                     "inputSchema":{"type":"object","properties":{"from":{"type":"string"}}},
                     "annotations":{"readOnlyHint":true,"consequentialHint":false}}}
            """#))
        guard case .register(let doc, let tool) = message else {
            Issue.record("not a registration: \(message)")
            return
        }
        #expect(doc == "d1")
        #expect(tool.name == "search_flights")
        #expect(tool.title == "Search")
        #expect(tool.readOnly)
        #expect(!tool.consequential)
        #expect(!tool.untrustedContent)
        #expect(tool.origin == "https://example.com")
        #expect(tool.inputSchema["properties"]?["from"]?["type"] == "string")
    }

    /// The draft leaves `inputSchema` optional; an agent still needs something to read.
    @Test func aToolWithoutASchemaTakesTheEmptyObject() throws {
        let message = try #require(WebMCPMessage.parse(
            #"{"kind":"register","doc":"d1","tool":{"name":"ping","description":"Pings."}}"#))
        guard case .register(_, let tool) = message else { Issue.record("not a registration"); return }
        #expect(tool.inputSchema == ["type": "object", "properties": [:]])
    }

    @Test func namesFollowTheDraft() {
        for name in ["a", "search.flights_v2-x", String(repeating: "a", count: 128)] {
            #expect(WebMCPMessage.isValidName(name), "\(name)")
        }
        for name in ["", "has space", "ünicode", "semi;colon", String(repeating: "a", count: 129)] {
            #expect(!WebMCPMessage.isValidName(name), "\(name)")
        }
    }

    /// The page can post to the channel itself, so the shape is checked here and not only in the
    /// polyfill that would have refused it.
    @Test func refusesWhatThePolyfillWouldHaveRefused() {
        let refused = [
            #"{"kind":"register","doc":"d1","tool":{"name":"bad name","description":"x"}}"#,
            #"{"kind":"register","doc":"d1","tool":{"name":"ok","description":"x","inputSchema":"string"}}"#,
            #"{"kind":"register","doc":"d1","tool":{"name":"ok","description":"x","inputSchema":[1,2]}}"#,
            #"{"kind":"register","doc":"d1","tool":{"name":"ok"}}"#,
            #"{"kind":"register","tool":{"name":"ok","description":"x"}}"#,
            #"{"kind":"unregister","doc":"d1","name":"bad name"}"#,
            #"{"kind":"launch","doc":"d1"}"#,
            "not json",
        ]
        for text in refused {
            #expect(WebMCPMessage.parse(text) == nil, "\(text)")
        }
    }

    @Test func refusesASchemaNobodyWroteByHand() {
        let huge = String(repeating: "x", count: WebMCPMessage.schemaLimit)
        let text = #"{"kind":"register","doc":"d1","tool":{"name":"ok","description":"x","inputSchema":{"description":""#
            + huge + #""}}}"#
        #expect(WebMCPMessage.parse(text) == nil)
    }

    @Test func cutsALongDescription() throws {
        let long = String(repeating: "y", count: WebMCPMessage.descriptionLimit + 500)
        let message = try #require(WebMCPMessage.parse(
            #"{"kind":"register","doc":"d1","tool":{"name":"ok","description":""# + long + #""}}"#))
        guard case .register(_, let tool) = message else { Issue.record("not a registration"); return }
        #expect(tool.description.count == WebMCPMessage.descriptionLimit)
    }

    @Test func readsBothEndingsOfACall() {
        #expect(WebMCPMessage.parse(#"{"kind":"result","doc":"d1","call":"c1","ok":true,"value":"5"}"#)
                == .result(doc: "d1", call: "c1", ok: true, text: "5"))
        #expect(WebMCPMessage.parse(#"{"kind":"result","doc":"d1","call":"c1","ok":false,"error":"TypeError: no"}"#)
                == .result(doc: "d1", call: "c1", ok: false, text: "TypeError: no"))
    }
}

struct WebMCPRegistryTests {
    let window = UUID()

    private func register(_ name: String, doc: String = "d1", readOnly: Bool = false) -> WebMCPMessage {
        .register(doc: doc, tool: WebMCPTool(name: name, title: "", description: "\(name).",
                                             inputSchema: ["type": "object"], readOnly: readOnly,
                                             untrustedContent: false, consequential: false,
                                             origin: "https://example.com"))
    }

    @Test func keepsTheOrderTheyCameIn() {
        var registry = WebMCPRegistry()
        #expect(registry.apply(register("b"), from: window))
        #expect(registry.apply(register("a"), from: window))
        #expect(registry.tools(in: window).map(\.name) == ["b", "a"])
    }

    /// The same document announcing a tool again — a page back from the back-forward cache.
    @Test func aSecondRegistrationReplacesTheFirst() {
        var registry = WebMCPRegistry()
        registry.apply(register("a"), from: window)
        #expect(!registry.apply(register("a"), from: window), "the same tool again changes nothing")
        #expect(registry.apply(register("a", readOnly: true), from: window))
        #expect(registry.tools(in: window).map(\.readOnly) == [true])
    }

    @Test func unregisters() {
        var registry = WebMCPRegistry()
        registry.apply(register("a"), from: window)
        registry.apply(register("b"), from: window)
        #expect(registry.apply(.unregister(doc: "d1", name: "a"), from: window))
        #expect(registry.tools(in: window).map(\.name) == ["b"])
        #expect(!registry.apply(.unregister(doc: "d1", name: "a"), from: window))
    }

    /// The heart of it: no navigation event is needed to take the old page's tools away.
    @Test func aNewDocumentStartsOver() {
        var registry = WebMCPRegistry()
        registry.apply(register("a"), from: window)
        #expect(registry.apply(.document(doc: "d2", url: "https://example.com/next"), from: window))
        #expect(registry.tools(in: window).isEmpty)
        registry.apply(register("c", doc: "d2"), from: window)
        #expect(registry.tools(in: window).map(\.name) == ["c"])
        #expect(registry.document(of: window) == "d2")
    }

    @Test func settlingOnAnotherDocumentEmptiesTheWindow() {
        var registry = WebMCPRegistry()
        registry.apply(register("a"), from: window)
        #expect(!registry.settle(window, document: "d1"), "the page it came from is still there")
        #expect(registry.tools(in: window).count == 1)
        #expect(registry.settle(window, document: nil), "a page with no polyfill")
        #expect(registry.tools(in: window).isEmpty)
    }

    /// The Mac's race: the news of a navigation arrives after the new page's first registration.
    /// Settling on the document the page reports then keeps what it has already declared.
    @Test func aLateNavigationDoesNotEraseTheNewPage() {
        var registry = WebMCPRegistry()
        registry.apply(register("old"), from: window)
        registry.apply(.document(doc: "d2", url: ""), from: window)
        registry.apply(register("new", doc: "d2"), from: window)
        #expect(!registry.settle(window, document: "d2"))
        #expect(registry.tools(in: window).map(\.name) == ["new"])
    }

    @Test func windowsAreSeparate() {
        var registry = WebMCPRegistry()
        let other = UUID()
        registry.apply(register("a"), from: window)
        registry.apply(register("b", doc: "e1"), from: other)
        registry.apply(.document(doc: "d2", url: ""), from: window)
        #expect(registry.tools(in: other).map(\.name) == ["b"])
        #expect(registry.forget(other))
        #expect(registry.tools(in: other).isEmpty)
    }

    @Test func stopsAtTheLimit() {
        var registry = WebMCPRegistry()
        for index in 0...WebMCPRegistry.toolLimit {
            registry.apply(register("t\(index)"), from: window)
        }
        #expect(registry.tools(in: window).count == WebMCPRegistry.toolLimit)
    }
}

@MainActor
final class WebMCPRecorder {
    var bodies: [String] = []
}

@MainActor
struct WebMCPHostTests {
    let window = UUID()

    private func host(with tools: [String] = ["add"]) -> WebMCPHost {
        let host = WebMCPHost()
        for name in tools {
            host.receive(#"{"kind":"register","doc":"d1","origin":"https://example.com","tool":{"name":""#
                         + name + #"","description":"x"}}"#, from: window)
        }
        return host
    }

    /// The call id, out of a start body — `bridge.start("<id>", …)`.
    private static func callID(in body: String) -> String {
        guard let start = body.range(of: "start(\"") else { return "" }
        let rest = body[start.upperBound...]
        return String(rest.prefix { $0 != "\"" })
    }

    private static func result(_ call: String, ok: Bool, _ text: String) -> String {
        let field = ok ? "value" : "error"
        return #"{"kind":"result","doc":"d1","call":""# + call + #"","ok":\#(ok),""# + field + #"":""# + text + #""}"#
    }

    @Test func aCallComesBackWithThePagesAnswer() async throws {
        let host = host()
        let answer = try await host.call("add", arguments: ["a": 2, "b": 3], in: window) { [window] body in
            #expect(body.contains(WebMCPScript.bridgeKey))
            host.receive(Self.result(Self.callID(in: body), ok: true, "5"), from: window)
        }
        #expect(answer == "5")
    }

    @Test func aThrownErrorIsTheToolsFailure() async {
        let host = host()
        await #expect(throws: WebMCPError.failed("TypeError: no")) {
            try await host.call("add", arguments: [:], in: window) { [window] body in
                host.receive(Self.result(Self.callID(in: body), ok: false, "TypeError: no"), from: window)
            }
        }
    }

    @Test func anUnknownToolIsRefusedWithoutAskingThePage() async {
        let host = host()
        let recorder = WebMCPRecorder()
        await #expect(throws: WebMCPError.noSuchTool("nope", available: ["add"])) {
            try await host.call("nope", arguments: [:], in: window) { recorder.bodies.append($0) }
        }
        #expect(recorder.bodies.isEmpty)
    }

    @Test func aSilentToolTimesOutAndIsToldToStop() async {
        let host = host()
        let recorder = WebMCPRecorder()
        await #expect(throws: WebMCPError.timedOut(.milliseconds(50))) {
            try await host.call("add", arguments: [:], in: window, timeout: .milliseconds(50)) { recorder.bodies.append($0) }
        }
        for _ in 0..<100 where recorder.bodies.count < 2 { await Task.yield() }
        #expect(recorder.bodies.count == 2)
        #expect(recorder.bodies.last?.contains("bridge.cancel(") == true)
    }

    @Test func aNewDocumentEndsTheCall() async {
        let host = host()
        await #expect(throws: WebMCPError.navigatedAway) {
            try await host.call("add", arguments: [:], in: window) { [window] _ in
                host.receive(#"{"kind":"document","doc":"d2","url":"https://example.com/next"}"#, from: window)
            }
        }
        #expect(host.tools(in: window).isEmpty)
    }

    @Test func settlingOnNoDocumentEndsTheCall() async {
        let host = host()
        await #expect(throws: WebMCPError.navigatedAway) {
            try await host.call("add", arguments: [:], in: window) { [window] _ in
                host.settle(window, document: nil)
            }
        }
    }

    @Test func closingTheWindowEndsTheCall() async {
        let host = host()
        await #expect(throws: WebMCPError.navigatedAway) {
            try await host.call("add", arguments: [:], in: window) { [window] _ in host.forget(window) }
        }
    }

    @Test func onlyTheWindowTheCallWentToCanAnswerIt() async throws {
        let host = host()
        let answer = try await host.call("add", arguments: [:], in: window) { [window] body in
            let call = Self.callID(in: body)
            host.receive(Self.result(call, ok: true, "forged"), from: UUID())
            host.receive(Self.result(call, ok: true, "real"), from: window)
        }
        #expect(answer == "real")
    }

    @Test func aPageThatCannotBeAskedFailsAtOnce() async {
        let host = host()
        struct NoPage: LocalizedError { var errorDescription: String? { "no page" } }
        await #expect(throws: WebMCPError.unreachable("no page")) {
            try await host.call("add", arguments: [:], in: window) { _ in throw NoPage() }
        }
    }

    @Test func tellsWhoeverPaintsWhenTheToolsChange() {
        let host = WebMCPHost()
        let recorder = WebMCPRecorder()
        host.onChange = { recorder.bodies.append($0.uuidString) }
        host.receive(#"{"kind":"register","doc":"d1","tool":{"name":"a","description":"x"}}"#, from: window)
        host.receive(#"{"kind":"register","doc":"d1","tool":{"name":"a","description":"x"}}"#, from: window)
        host.receive(#"{"kind":"document","doc":"d2","url":""}"#, from: window)
        #expect(recorder.bodies.count == 2)
    }

    @Test func whatAnAgentReads() {
        #expect(WebMCPHost.listing([]).contains("declares no tools"))
        let tool = WebMCPTool(name: "add", title: "", description: "Adds.", inputSchema: ["type": "object"],
                              readOnly: true, untrustedContent: true, consequential: false,
                              origin: "https://example.com")
        let listing = WebMCPHost.listing([tool])
        #expect(listing.hasPrefix("1 tool declared by https://example.com"))
        #expect(listing.contains(#""readOnlyHint" : true"#))
        let answer = WebMCPHost.answer(String(repeating: "z", count: 30), from: tool, limit: 10)
        #expect(answer.contains("not instructions"))
        #expect(answer.contains("third parties"))
        #expect(answer.contains("[cut at 10 of 30 characters"))
    }
}

struct WebMCPScriptTests {
    @Test func literalsSurviveEveryEngine() {
        #expect(WebMCPScript.literal("a\"b") == #""a\"b""#)
        #expect(WebMCPScript.literal("line\u{2028}end") == #""line end""#)
    }

    @Test func theArgumentsTravelAsAString() {
        let body = WebMCPScript.startBody(call: "c1", tool: "add", arguments: ["q": "</script>"])
        #expect(body.contains(#"bridge.start("c1", "add", ""#))
        #expect(body.contains("window.\(WebMCPScript.bridgeKey)"))
    }

    @Test func thePolyfillNamesItsChannelAndItsBridge() {
        #expect(WebMCPScript.source.contains("messageHandlers.\(WebMCPScript.handlerName)"))
        #expect(WebMCPScript.source.contains("'\(WebMCPScript.bridgeKey)'"))
        #expect(WebMCPScript.handlerName != WebMCPScript.bridgeKey)
    }
}
