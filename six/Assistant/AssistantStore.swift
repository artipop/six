import Foundation
import FoundationModels
import Observation
import WebKit

/// Drives the one-line assistant: takes a question, adds page context, streams the answer.
@MainActor
@Observable
final class AssistantStore {
    let settings = AssistantSettings()

    private(set) var answer = ""
    private(set) var isResponding = false
    private(set) var errorMessage: String?
    var isAnswerVisible = false

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var sessionModel: ModelChoice?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let instructions = """
        You are a concise browsing assistant embedded in a web browser. \
        Answer the user's question directly, in the user's language. \
        When page content is provided, prefer it over prior knowledge. Keep answers short unless asked otherwise.
        """

    func ask(_ question: String, about tab: BrowserTab?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        task?.cancel()
        answer = ""
        errorMessage = nil
        isAnswerVisible = true
        isResponding = true

        task = Task {
            defer { isResponding = false }
            do {
                let session = try currentSession()
                let prompt = await Self.buildPrompt(question: question, tab: tab)
                let stream = session.streamResponse(to: prompt)
                for try await partial in stream {
                    guard !Task.isCancelled else { return }
                    answer = partial.content
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        isResponding = false
    }

    func dismiss() {
        cancel()
        isAnswerVisible = false
    }

    /// Drops the conversation so the next question starts fresh.
    func resetConversation() {
        session = nil
        sessionModel = nil
        answer = ""
        errorMessage = nil
    }

    private func currentSession() throws -> LanguageModelSession {
        if let session, sessionModel == settings.model { return session }
        let session = try settings.makeSession(instructions: Self.instructions)
        self.session = session
        sessionModel = settings.model
        return session
    }

    private static func buildPrompt(question: String, tab: BrowserTab?) async -> String {
        guard let tab, let url = tab.page.url else { return question }
        var prompt = "Current page: \(tab.page.title) <\(url.absoluteString)>\n"
        if let text = await pageText(of: tab.page) {
            prompt += "Page content (truncated):\n\"\"\"\n\(text)\n\"\"\"\n\n"
        }
        return prompt + "Question: \(question)"
    }

    private static func pageText(of page: WebPage, limit: Int = 6000) async -> String? {
        let script = "return document.body ? document.body.innerText : ''"
        guard let raw = try? await page.callJavaScript(script) as? String else { return nil }
        let collapsed = raw.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return collapsed.isEmpty ? nil : String(collapsed.prefix(limit))
    }
}
