#if canImport(AppKit)
import AppKit
#endif
import Foundation
import FoundationModels
import Observation
import WebKit

/// Runs one thing at a time and keeps its answer until it is used or dismissed.
///
/// There is deliberately no conversation here. A browser assistant is asked about what is on the
/// screen — this paragraph, this field, this page — and the thing on the screen is the context; a
/// transcript of six earlier questions about six other pages is not what makes the seventh answer
/// good, it is what makes the interface a chat. So: one `Answer`, replaced by the next one, gone on
/// Escape. The place that genuinely needs a transcript — an ACP agent working through a task — has
/// one, in the panel behind ⌘⇧A, and that is the only chat in six.
///
/// What replaces the conversation is the focus (`PageFocus`): the assistant knows what is selected
/// and where the caret is, so a follow-up is usually a different verb on the same text rather than a
/// sentence explaining what "it" meant.
@MainActor
@Observable
final class AssistantStore {
    let settings: AssistantSettings

    init(settings: SettingsStore) {
        self.settings = AssistantSettings(store: settings)
    }

    /// One answer, or none. `nil` is the resting state, and Escape puts it back.
    private(set) var answer: Answer?

    /// What was asked, what came back, and what can be done with it.
    struct Answer: Identifiable, Equatable {
        let id = UUID()
        /// The line above the answer: the verb, or the question as it was typed.
        var title: String
        /// Nil for a free question typed into the line.
        var action: AssistantAction?
        var landing: AssistantAction.Landing = .show
        /// The window the answer is about, and the only one it may be written back into.
        var windowID: UUID?
        var text = ""
        /// What the agent is doing right now (a tool call), while there is nothing to show yet.
        var activity: String?
        var error: String?
        var isRunning = false
        /// Written back into the page already: the buttons become "Undo it yourself, ⌘Z".
        var isApplied = false

        /// Can this answer be put back where it came from?
        var isApplicable: Bool {
            landing.writesToPage && !isApplied && !isRunning && error == nil && !text.isEmpty
        }
    }

    /// Wired at launch: browser tools for the language models, the agent session for the ACP choices,
    /// the focus store for what the page has under the cursor.
    @ObservationIgnored var tools: BrowserToolCatalog?
    @ObservationIgnored var focus: PageFocusStore?
    #if os(macOS)
    @ObservationIgnored var agentSession: AgentSessionStore?
    @ObservationIgnored var research: ResearchCoordinator?
    #endif

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var sessionModel: ModelChoice?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let instructions = """
        You are a concise assistant embedded in a web browser called six. You are given what the \
        person is looking at — a page, a paragraph they selected, or the text in a field they are \
        typing into — and one thing to do with it. Do that one thing.

        Answer in the person's own language: the language of the text you are given, or of the \
        question. Keep it short; a person reads this in a strip at the bottom of a page, not in a \
        document. No preamble, no restating of the request, no offers of further help.

        When the instruction says to return text that replaces or continues what the person wrote, \
        return that text and nothing else: no quotation marks around it, no explanation of what you \
        changed, no alternatives to choose from.

        You have tools to look at and arrange the browser — use them when the question is about \
        other windows or asks you to open, move or close something; the text in front of you is \
        already in the prompt. The user's bookmarks are searchable with `search_bookmarks`; reach \
        for them when the question is about something the user saved or read before.

        """ + BrowserToolCatalog.instructions

    // MARK: Asking

    /// The ⌘K line: a question in the person's own words, about whatever is in front of them.
    func ask(_ question: String, about tab: BrowserTab?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let focus = tab.map { self.focus?[$0.id] ?? PageFocus() } ?? PageFocus()
        start(Answer(title: question, windowID: tab?.id, isRunning: true)) { [self] report in
            #if os(macOS)
            // `research: …` starts a deep-research run: a workspace, a document, and the agent at work.
            if let research, let topic = ResearchCoordinator.question(fromCommand: question) {
                return await runResearch(research, question: topic, report: report)
            }
            if let agent = settings.model.agentDefinition {
                return await askAgent(agent, question: question, about: tab, report: report)
            }
            #endif
            let prompt = await Self.prompt(instruction: question, focus: focus, tab: tab)
            await stream(prompt, report: report)
        }
    }

    /// A verb from the catalog, on what the page has under the cursor.
    func run(_ action: AssistantAction, focus: PageFocus, about tab: BrowserTab?) {
        var answer = Answer(title: String(localized: action.title),
                            action: action,
                            landing: action.landing,
                            windowID: tab?.id,
                            isRunning: true)
        // An action that would write into a page six cannot write to is an action that only reads.
        if action.landing.writesToPage && !focus.isEditable { answer.landing = .show }
        start(answer) { [self] report in
            let prompt = await Self.prompt(instruction: action.prompt, focus: focus, tab: tab)
            await stream(prompt, report: report)
        }
    }

    /// Everything that runs goes through here: one result at a time, the previous one cancelled.
    private func start(_ answer: Answer, _ body: @escaping (@escaping (Update) -> Void) async -> Void) {
        task?.cancel()
        self.answer = answer
        let id = answer.id
        task = Task { [weak self] in
            await body { update in
                guard let self, self.answer?.id == id else { return }
                switch update {
                case .text(let text): self.answer?.text = text; self.answer?.activity = nil
                case .activity(let title): self.answer?.activity = title
                case .failure(let message): self.answer?.error = message
                }
            }
            guard let self, self.answer?.id == id else { return }
            self.answer?.isRunning = false
            self.answer?.activity = nil
        }
    }

    enum Update { case text(String), activity(String), failure(String) }

    private func stream(_ prompt: String, report: @escaping (Update) -> Void) async {
        do {
            let session = try currentSession()
            for try await partial in session.streamResponse(to: prompt) {
                guard !Task.isCancelled else { return }
                report(.text(partial.content))
            }
        } catch is CancellationError {
        } catch {
            report(.failure(error.localizedDescription))
        }
    }

    #if os(macOS)
    /// The ⌘K line answered by an ACP agent: the same session as the agent panel, so the transcript,
    /// permissions and the profile's working directory are shared.
    private func askAgent(_ agent: ACPAgentDefinition, question: String, about tab: BrowserTab?,
                          report: @escaping (Update) -> Void) async {
        guard let agentSession else { return report(.failure(String(localized: "Agent session is not available"))) }
        if agentSession.agent != agent { agentSession.agent = agent }
        var context: [ACP.ContentBlock] = []
        if let tab, !tab.showsStartPage, let url = tab.currentURL {
            context.append(.resourceLink(uri: url.absoluteString, name: tab.title, mimeType: "text/html", title: tab.title))
        }
        let outcome = await agentSession.prompt(question, context: context) { update in
            switch update {
            case .text(let text): report(.text(text))
            case .activity(let title): report(.activity(title))
            }
        }
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome { report(.failure(message)) }
        AgentSessionStore.trace("assistant/agent outcome: \(outcome)")
    }

    private func runResearch(_ research: ResearchCoordinator, question: String,
                             report: @escaping (Update) -> Void) async {
        let agent = settings.model.agentDefinition ?? agentSession?.agent
        let outcome = await research.start(question, agent: agent) { update in
            switch update {
            case .text(let text): report(.text(text))
            case .activity(let title): report(.activity(title))
            }
        }
        guard !Task.isCancelled else { return }
        if case .failed(let message) = outcome { report(.failure(message)) }
    }
    #endif

    /// The ⌘K line, asked for from somewhere that has no way to move focus itself — the bar over a
    /// selection, which lives in an AppKit hosting view of its own.
    private(set) var focusRequests = 0

    func focusLine() { focusRequests += 1 }

    // MARK: Landing

    /// Put the answer back where it came from. Always a deliberate act — a key or a button — and
    /// always reversible: the page's own undo takes it back, because the text goes in through
    /// `insertText` rather than an assignment (`PageFocusScript`).
    func apply(in tab: BrowserTab?) {
        guard var answer, answer.isApplicable, let tab, tab.id == answer.windowID else { return }
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let whole = answer.landing == .replaceField
        answer.isApplied = true
        self.answer = answer
        Task {
            _ = try? await tab.runScript(PageFocusScript.insert, arguments: ["text": text, "whole": whole])
        }
    }

    func copy() {
        #if os(macOS)
        guard let text = answer?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    func cancel() {
        task?.cancel()
        #if os(macOS)
        if settings.model.agentDefinition != nil { agentSession?.cancel() }
        #endif
        answer?.isRunning = false
        answer?.activity = nil
    }

    func dismiss() {
        cancel()
        answer = nil
    }

    /// Drops the model's session so the next question starts with nothing behind it.
    func resetConversation() {
        session = nil
        sessionModel = nil
        answer = nil
    }

    // MARK: The prompt

    private func currentSession() throws -> LanguageModelSession {
        if let session, sessionModel == settings.model { return session }
        let modelTools = try (tools?.tools(for: .assistant) ?? []).map { try BrowserModelTool($0) }
        let session = try settings.makeSession(instructions: Self.instructions, tools: modelTools)
        self.session = session
        sessionModel = settings.model
        return session
    }

    /// What the model is given: where the person is, what they are pointing at, and the one thing to
    /// do with it. The page's text comes along only when nothing narrower was pointed at — a
    /// selection is a better answer to "what is this about" than six thousand characters around it,
    /// and it costs a fraction as much.
    private static func prompt(instruction: String, focus: PageFocus, tab: BrowserTab?) async -> String {
        var prompt = ""
        if let tab, let url = tab.currentURL {
            prompt += "Page: \(tab.title) <\(url.absoluteString)>\n"
        }
        switch focus.kind {
        case .selection:
            if !focus.label.isEmpty { prompt += "The selection is inside a field labelled \"\(focus.label)\".\n" }
            prompt += "Selected text:\n\"\"\"\n\(focus.text)\n\"\"\"\n"
        case .caret:
            let label = focus.label.isEmpty ? "a text field" : "a field labelled \"\(focus.label)\""
            prompt += "The cursor is in \(label) on the page.\n"
            if focus.field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt += "The field is empty.\n"
                if let text = await pageText(of: tab, limit: 4000) {
                    prompt += "The page around it, for context:\n\"\"\"\n\(text)\n\"\"\"\n"
                }
            } else {
                prompt += "What is typed there so far:\n\"\"\"\n\(focus.field)\n\"\"\"\n"
            }
        case .none:
            if let text = await pageText(of: tab, limit: 6000) {
                prompt += "Page content (truncated):\n\"\"\"\n\(text)\n\"\"\"\n"
            }
        }
        return prompt + "\nTask: \(instruction)"
    }

    private static func pageText(of tab: BrowserTab?, limit: Int) async -> String? {
        guard let tab, !tab.showsStartPage, let page = tab.livePage else { return nil }
        return await BrowserToolCatalog.pageText(of: page, limit: limit)
    }
}
