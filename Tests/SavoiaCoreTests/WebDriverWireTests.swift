import Foundation
import Testing
@testable import SavoiaCore

/// The half of the WebDriver server that is bytes and JSON: a request off the wire, who may send
/// one, and input actions as WebKit's automation protocol takes them.
struct WebDriverWireTests {
    private func request(_ text: String) throws -> (request: WebDriverRequest, length: Int)? {
        try WebDriverRequest.parse(Data(text.utf8))
    }

    @Test func aRequestWaitsForItsWholeBody() throws {
        let head = "POST /session/1/url?x=1 HTTP/1.1\r\nHost: 127.0.0.1:4444\r\nContent-Length: 9\r\n\r\n"
        #expect(try request(head + "{\"a\"") == nil)
        let whole = try #require(try request(head + "{\"a\": 1}\nGET"))
        #expect(whole.request.method == "POST")
        #expect(whole.request.path == "/session/1/url")
        #expect(whole.request.body == Data("{\"a\": 1}\n".utf8))
        #expect(whole.length == head.utf8.count + 9)
    }

    @Test func aRequestWithNoLengthHasNoBody() throws {
        let parsed = try #require(try request("GET /status HTTP/1.1\r\nHost: localhost:1\r\n\r\n"))
        #expect(parsed.request.body.isEmpty)
        #expect(parsed.request.keepsAlive)
    }

    @Test func whatIsNotHTTPIsRefused() {
        #expect(throws: WebDriverRequest.Malformed.self) { try request("hello\r\n\r\n") }
        #expect(throws: WebDriverRequest.Malformed.self) { try request("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") }
    }

    @Test func onlyAClientOnThisMacIsAnswered() throws {
        func local(_ headers: String) throws -> Bool {
            try #require(try request("GET /status HTTP/1.1\r\n\(headers)\r\n\r\n")).request.isFromLocalClient
        }
        #expect(try local("Host: 127.0.0.1:4444"))
        #expect(try local("Host: localhost"))
        #expect(try local("Host: [::1]:4444"))
        // A page elsewhere, by a name that resolves here, and a page posting across origins.
        #expect(try !local("Host: evil.example:4444"))
        #expect(try !local("Host: 127.0.0.1:4444\r\nOrigin: https://evil.example"))
        #expect(try !local("Accept: */*"))
    }

    @Test func aProtocolErrorIsNamedAsWebDriverNamesIt() {
        let stale = WebDriverError(protocolError: ["message": "StaleNode;The node is gone"])
        #expect(stale.code == "stale element reference")
        #expect(stale.message == "The node is gone")
        #expect(stale.status == 404)
        #expect(WebDriverError(protocolError: ["message": "Something else"]).code == "unknown error")
    }

    @Test func sendKeysHoldsAModifierUntilTheNullKey() {
        let typed = WebDriverInput.typing("\u{E008}ab\u{E000}c\u{E006}")
        #expect(typed.map { $0["type"] as? String } == ["KeyPress", "InsertByKey", "InsertByKey", "KeyRelease", "InsertByKey", "InsertByKey"])
        #expect(typed[0]["key"] as? String == "Shift")
        #expect(typed[1]["text"] as? String == "a")
        #expect(typed[5]["key"] as? String == "Return")
    }

    @Test func aClickIsMoveDownUpWithTheButtonOnBoth() throws {
        var sources: [String: WebDriverInput.Source] = [:]
        let pointer: [String: Any] = ["type": "pointer", "id": "mouse", "parameters": ["pointerType": "mouse"], "actions": [
            ["type": "pointerMove", "x": 10, "y": 20, "origin": [WebDriverInput.element: "node-1"]],
            ["type": "pointerDown", "button": 0],
            ["type": "pause", "duration": 50],
            ["type": "pointerUp", "button": 0],
        ]]
        let keys: [String: Any] = ["type": "key", "id": "keys", "actions": [["type": "keyDown", "value": "\u{E03D}"], ["type": "keyDown", "value": "a"]]]
        let sequence = try WebDriverInput.sequence([pointer, keys], sources: &sources)
        #expect(sequence.inputSources.map { $0["sourceType"] as? String } == ["Mouse", "Keyboard"])
        #expect(sequence.steps.count == 4)
        let states = sequence.steps.map { ($0["states"] as? [[String: Any]] ?? []) }
        #expect(states[0][0]["origin"] as? String == "Element")
        #expect(states[0][0]["nodeHandle"] as? String == "node-1")
        #expect(states[0][0]["mouseInteraction"] as? String == "Move")
        #expect(states[1][0]["mouseInteraction"] as? String == "Down")
        // A pause between down and up still says the button is held, and is no interaction of its own.
        #expect(states[2][0]["pressedButton"] as? String == "Left")
        #expect(states[2][0]["mouseInteraction"] == nil)
        #expect(states[3][0]["mouseInteraction"] as? String == "Up")
        #expect(states[3][0]["pressedButton"] as? String == "Left")
        #expect(sources["mouse"]?.button == nil)
        #expect(states[0][1]["pressedVirtualKeys"] as? [String] == ["Meta"])
        #expect(states[1][1]["pressedCharKeys"] as? [String] == ["a"])
    }

    @Test func anActionThatIsNoActionIsAnInvalidArgument() {
        var sources: [String: WebDriverInput.Source] = [:]
        #expect(throws: WebDriverError.self) {
            try WebDriverInput.sequence([["type": "pointer", "id": "m", "actions": [["type": "pointerMove"]]]], sources: &sources)
        }
    }
}
