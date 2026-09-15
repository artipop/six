import Foundation
import Testing

@testable import SixCore

/// What the extractor's answer becomes on the Swift side.
///
/// The script itself needs a page and is not run here; what is pinned is the part every front now
/// shares — that an answer is trimmed, that a page with no text is refused rather than saved as an
/// empty passage, and that anything which is not the script's object is refused too. The Linux and
/// Windows bridges hand back `JSONSerialization`'s idea of that object and the Mac's `WebPage` its
/// own, so this is the shape they both have to arrive in.
@MainActor
struct ReadablePageTests {
    private func answer(text: String) -> [String: Any] {
        ["title": "Pilaf", "byline": "", "siteName": "en.wikipedia.org", "excerpt": "Rice, cooked in stock.",
         "image": "", "language": "en", "markdown": "  # Pilaf\n\n\(text)  ", "text": "  \(text)\n"]
    }

    @Test func anAnswerIsTrimmed() throws {
        let page = try ReadablePage.decode(answer(text: "Pilaf is a rice dish."))
        #expect(page.text == "Pilaf is a rice dish.")
        #expect(page.markdown == "# Pilaf\n\nPilaf is a rice dish.")
        #expect(page.imageURL == nil)
    }

    @Test func aPageWithNoTextIsRefused() {
        #expect(throws: ReadablePage.ExtractionError.self) { try ReadablePage.decode(answer(text: " \n ")) }
    }

    @Test func somethingThatIsNotTheScriptsAnswerIsRefused() {
        #expect(throws: (any Error).self) { try ReadablePage.decode(nil) }
        #expect(throws: (any Error).self) { try ReadablePage.decode("a string") }
        #expect(throws: (any Error).self) { try ReadablePage.decode(["title": "no text key"]) }
    }

    /// Through the seam, the way a front calls it: a runner that answers the way `LivePage` and
    /// `RailWebView` do, and the script is what it was asked to run.
    @Test func extractionRunsTheScriptThroughTheRunner() async throws {
        let runner = Runner(answer(text: "Pilaf is a rice dish."))
        let page = try await ReadablePage.extract(from: runner)
        #expect(page.title == "Pilaf")
        #expect(runner.ran == ReadablePage.script)
    }

    @MainActor
    private final class Runner: PageScriptRunner {
        let value: [String: Any]
        var ran: String?
        init(_ value: [String: Any]) { self.value = value }
        func runScript(_ body: String, arguments: [String: Any]) async throws -> Any? {
            ran = body
            return value
        }
    }
}
