import Foundation
import Testing
@testable import SixCore

/// What a failed call says to a person. The cases are the shapes the agents actually send: Codex's
/// adapter wraps a refusal in an internal error and puts the sentence in `data`, and an agent that
/// sends nothing but a code has to stay legible too.
struct JSONRPCErrorTests {
    private func error(_ value: String) throws -> JSONRPCError {
        try JSONDecoder().decode(JSONRPCError.self, from: Data(value.utf8))
    }

    @Test func detailsReplaceAPlaceholderHeadline() throws {
        let limit = try error("""
        {"code":-32603,"message":"Internal error",
         "data":{"details":"You've hit your usage limit. Upgrade to Pro or try again at Sep 25th, 2026 2:59 PM."}}
        """)
        #expect(limit.localizedDescription == "You've hit your usage limit. Upgrade to Pro or try again at Sep 25th, 2026 2:59 PM.")
    }

    @Test func aBareStringInDataIsTheMessage() throws {
        let refused = try error(#"{"code":-32000,"message":"error","data":"The model refused the request."}"#)
        #expect(refused.localizedDescription == "The model refused the request.")
    }

    @Test func aHeadlineThatSaysSomethingKeepsItsDetail() throws {
        let failed = try error(#"{"code":429,"message":"Rate limited","data":{"message":"Try again in 30 seconds."}}"#)
        #expect(failed.localizedDescription == "Rate limited: Try again in 30 seconds.")
    }

    @Test func aRepeatedHeadlineIsNotSaidTwice() throws {
        let failed = try error(#"{"code":-32603,"message":"stream error","data":{"error":"stream error: connection reset"}}"#)
        #expect(failed.localizedDescription == "stream error: connection reset")
    }

    @Test func withoutDetailsTheCodeIsStillThere() throws {
        #expect(JSONRPCError.connectionClosed.localizedDescription == "Connection closed (-32000)")
        let bare = try error(#"{"code":-127483,"message":""}"#)
        #expect(bare.localizedDescription == "Error -127483")
    }
}
