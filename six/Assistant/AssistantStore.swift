import Foundation
import FoundationModels
import Observation
import WebKit

/// Drives the one-line assistant: takes a question, adds page context, streams the answer.
@MainActor
@Observable
final class AssistantStore {
    let settings: AssistantSettings

    init(settings: SettingsStore) {
        self.settings = AssistantSettings(store: settings)
    }

    private(set) var answer = ""
    /// What the agent is doing right now (a tool call), shown under the answer while it works.
    private(set) var activity: String?
    private(set) var isResponding = false
    private(set) var errorMessage: String?
    var isAnswerVisible = false

    /// Wired at launch: browser tools for the language models, the agent session for the ACP choices.
    @ObservationIgnored var tools: BrowserToolCatalog?
    @ObservationIgnored var agentSession: AgentSessionStore?

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var sessionModel: ModelChoice?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let instructions = """
        You are a concise browsing assistant embedded in a web browser called six. \
        Answer the user's question directly, in the user's language. \
        When page content is provided, prefer it over prior knowledge. Keep answers short unless asked otherwise. \
        You have tools to look at and arrange the browser — use them when the question is about other windows \
        or asks you to open, move or close something; the current page's text is already in the prompt. \
        The user's bookmarks are searchable with `search_bookmarks`; reach for them when the question is about \
        something the user saved or read before.

        """ + BrowserToolCatalog.instructions

    func ask(_ question: String, about tab: BrowserTab?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        task?.cancel()
        answer = ""
        activity = nil
        errorMessage = nil
        isAnswerVisible = true
        isResponding = true

        if let agent = settings.model.agentDefinition {
            task = Task { await askAgent(agent, question: question, about: tab) }
            return
        }

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

    /// The ⌘K line answered by an ACP agent: the same session as the agent panel, so the transcript,
    /// permissions and the profile's working directory are shared.
    private func askAgent(_ agent: ACPAgentDefinition, question: String, about tab: BrowserTab?) async {
        defer { isResponding = false; activity = nil }
        guard let agentSession else { errorMessage = "Agent session is not available"; return }
        if agentSession.agent != agent { agentSession.agent = agent }
        var context: [ACP.ContentBlock] = []
        if let tab, !tab.showsStartPage, let url = tab.page.url {
            context.append(.resourceLink(uri: url.absoluteString, name: tab.title, mimeType: "text/html", title: tab.title))
        }
        let outcome = await agentSession.prompt(question, context: context) { [weak self] update in
            switch update {
            case .text(let text): self?.answer = text; self?.activity = nil
            case .activity(let title): self?.activity = title
            }
        }
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome { errorMessage = message }
        AgentSessionStore.trace("assistant/agent outcome: \(outcome) answer: \(answer.prefix(200))")
    }

    func cancel() {
        task?.cancel()
        if settings.model.agentDefinition != nil { agentSession?.cancel() }
        isResponding = false
        activity = nil
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
        let modelTools = try (tools?.tools(for: .assistant) ?? []).map { try BrowserModelTool($0) }
        let session = try settings.makeSession(instructions: Self.instructions, tools: modelTools)
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
        await BrowserToolCatalog.pageText(of: page, limit: limit)
    }
}
