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
/// one, in the agent panel (currently hidden from the UI), and that is the only chat in six.
///
/// What replaces the conversation is the focus (`PageFocus`): the assistant knows what is selected
/// and where the caret is, so a follow-up is usually a different verb on the same text rather than a
/// sentence explaining what "it" meant.
@MainActor
@Observable
final class AssistantStore {
    let settings: AssistantSettings

    init(settings: ConfigurationStore) {
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
        /// What was pointed at when it was asked. Kept because the page will not keep it: putting
        /// the answer back has to put the selection back first.
        var subject: PageFocus?
        var text = ""
        /// What the agent is doing right now (a tool call), while there is nothing to show yet.
        var activity: String?
        var error: String?
        /// The error is one the person can put right in `six://configuration` ▸ Assistant.
        var offersConfiguration = false
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

    /// The ⌘E line: a question in the person's own words, about whatever is in front of them.
    func ask(_ question: String, about tab: BrowserTab?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let focus = tab.map { subject(in: $0.id) } ?? PageFocus()
        start(Answer(title: question, windowID: tab?.id, subject: focus, isRunning: true)) { [self] report in
            #if os(macOS)
            // `research: …` starts a deep-research run: a workspace, a document, and the agent at work.
            if let research, let topic = ResearchCoordinator.question(fromCommand: question) {
                return await runResearch(research, question: topic, report: report)
            }
            if let agent = lineAgent {
                return await askAgent(agent, question: question, about: tab, report: report)
            }
            #endif
            let prompt = await Self.prompt(instruction: question, focus: focus, tab: tab)
            await stream(prompt, report: report)
        }
    }

    /// A verb from the catalog, on what the page has under the cursor.
    ///
    /// It goes wherever the ⌘E line goes, the agent included. That is the second answer to this
    /// question and the right one: the first was to hide the verbs whenever the line was set to an
    /// ACP agent, which is how a bar with nothing in it but `…` came to hover over a selected
    /// paragraph. The second was to fall back to the on-device model — and on a Mac whose Apple
    /// Intelligence assets are still coming down that is a floor that is not there
    /// (`modelNotReady`), so every verb failed instead. What is left is the rule with no surprise in
    /// it: one model answers everything the assistant is asked, and it is the one that was chosen.
    func run(_ action: AssistantAction, focus: PageFocus, about tab: BrowserTab?) {
        var answer = Answer(title: String(localized: action.title),
                            action: action,
                            landing: action.landing,
                            windowID: tab?.id,
                            subject: focus,
                            isRunning: true)
        // An action that would write into a page six cannot write to is an action that only reads.
        if action.landing.writesToPage && !focus.isEditable { answer.landing = .show }
        start(answer) { [self] report in
            let prompt = await Self.prompt(instruction: action.prompt, focus: focus, tab: tab)
            #if os(macOS)
            // The whole prompt, not a resource link: a verb is about the text in front of the
            // person, and the agent must not have to go and read the page to find it.
            if let agent = lineAgent {
                return await askAgent(agent, question: prompt, about: tab, report: report)
            }
            #endif
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
                case .failure(let message, let fixable):
                    self.answer?.error = message
                    self.answer?.offersConfiguration = fixable
                }
            }
            guard let self, self.answer?.id == id else { return }
            self.answer?.isRunning = false
            self.answer?.activity = nil
        }
    }

    enum Update {
        case text(String)
        case activity(String)
        /// `fixable` when the way out is `six://configuration` ▸ Assistant — a key, an address, a
        /// model name — and the answer offers the way there rather than only naming the trouble.
        case failure(String, fixable: Bool = false)
    }

    private func stream(_ prompt: String, report: @escaping (Update) -> Void) async {
        do {
            let session = try currentSession()
            for try await partial in session.streamResponse(to: prompt) {
                guard !Task.isCancelled else { return }
                report(.text(partial.content))
            }
        } catch is CancellationError {
        } catch {
            report(.failure(error.localizedDescription,
                            fixable: (error as? AssistantError)?.isConfiguration == true))
        }
    }

    #if os(macOS)
    /// The ⌘E line answered by an ACP agent: the same session as the agent panel, so the transcript,
    /// permissions and the profile's working directory are shared.
    private func askAgent(_ agent: ACPAgentDefinition, question: String, about tab: BrowserTab?,
                          report: @escaping (Update) -> Void) async {
        guard let agentSession else { return report(.failure(String(localized: "Agent session is not available"))) }
        if let chat = continuedChat {
            agentSession.open(chat.id)
        } else {
            if agentSession.agent != agent { agentSession.agent = agent }
            if startsAgentChat {
                startsAgentChat = false
                agentSession.startFreshChat()
            }
        }
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

    /// Who answers the line: the agent of the chat it goes on with, else the chosen model's.
    private var lineAgent: ACPAgentDefinition? {
        continuedChat.flatMap { agentSession?.definition(for: $0.agentID) } ?? settings.model.agentDefinition
    }

    /// The chat the line goes on with, picked from its `/` list — for this summons only, the way a
    /// line called up from nothing is a new chat. The summary: the transcript stays in the store.
    private(set) var continuedChat: AgentChat?

    /// Goes on with a conversation from the history. The answer strip shows where it stopped — the
    /// last question and what came back — so the next question has something to follow.
    func continueChat(_ id: UUID) {
        guard answer?.isRunning != true, let chat = agentSession?.chat(id) else { return }
        continuedChat = chat.summary
        startsAgentChat = false
        var lastQuestion: String?
        var lastAnswer: String?
        for item in chat.transcript.reversed() {
            switch item.kind {
            case .agent(let text) where lastAnswer == nil && lastQuestion == nil: lastAnswer = text
            case .user(let text) where lastQuestion == nil: lastQuestion = text
            default: break
            }
            if lastQuestion != nil { break }
        }
        task?.cancel()
        answer = Answer(title: lastQuestion ?? chat.summary.title ?? "", text: lastAnswer ?? "")
    }

    /// Back to a chat of its own: the next question starts one.
    func stopContinuingChat() {
        continuedChat = nil
        startsAgentChat = true
        if answer?.isRunning != true { answer = nil }
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

    // MARK: The line

    /// Where the ⌘E line stands. At a field or a selection when the page has one — the question is
    /// about that, so it is asked there — and at the bottom of the row otherwise.
    enum LinePlace: Equatable {
        case bottom
        /// Hung on this window's `PageFocus.rect`.
        case page(UUID)
    }

    /// Nil while the line is away. The store holds it rather than a view, because the two places are
    /// two views — the bottom one in `ContentView`, the other inside the column — and ⌘E is a menu
    /// item that has to decide between them without either having focus: a `@FocusedValue` exists
    /// only while something in the scene has focus, so after Esc the item was greyed out, and a
    /// disabled item eats its key.
    private(set) var line: LinePlace?
    /// The next agent question starts a chat of its own (`summonLine`). True at launch.
    @ObservationIgnored private var startsAgentChat = true
    /// Bumped on every summons, so a line that is already standing takes the caret again.
    private(set) var summons = 0
    /// Put away by a key (Esc, ⌘E) rather than by the caret leaving for somewhere else. Only then
    /// does a line hung on a field hand the keyboard back to the page it came from.
    @ObservationIgnored private(set) var closedByKey = false
    /// What was pointed at when the line was asked for, and in which window. The page does not keep
    /// it for us: a selection in text is gone the moment the web view hands the keyboard to the line
    /// — measured, at the bottom as much as beside the text — so the question would arrive with no
    /// subject and the line would lose the rectangle it hangs on.
    private var summonedFocus: (window: UUID, focus: PageFocus)?

    /// The thing the line is about. While the line is up that is what was pointed at when it was
    /// asked for, and not what the page says now — asking collapses a field's selection to a caret
    /// and drops one in prose, so the live answer would turn "four words in this comment" into "this
    /// comment", verbs and all. Only the rectangle is taken live, and only while the page still says
    /// the same kind of thing, so a line hung on a field follows it as the page scrolls.
    func subject(in windowID: UUID) -> PageFocus {
        let live = focus?[windowID] ?? PageFocus()
        guard let summonedFocus, summonedFocus.window == windowID, line != nil else { return live }
        var kept = summonedFocus.focus
        if live.kind == kept.kind, live.rect != .zero { kept.rect = live.rect }
        return kept
    }

    /// ⌘E: up if it is away, away if it is up — wherever it is up. Deciding the place again on the
    /// second press is how it once rose at the bottom instead of going away: the page had redrawn
    /// what it reports by then, and the place came out different. An answer on screen counts as up.
    func toggleLine(in tab: BrowserTab?) {
        if line != nil || answer != nil { closeLine() } else { summonLine(at: place(for: tab)) }
    }

    func summonLine(in tab: BrowserTab?) { summonLine(at: place(for: tab)) }

    private func summonLine(at place: LinePlace) {
        closedByKey = false
        // Called up from nothing, the line is a new conversation with the agent; asked again while
        // it stands, it is a follow-up in the same one. Otherwise every question about every page
        // ran on in one chat that was never done.
        if line == nil, answer == nil {
            startsAgentChat = true
            #if os(macOS)
            continuedChat = nil
            #endif
        }
        if line == nil { summonedFocus = snapshot(for: place) }
        line = place
        summons += 1
    }

    /// Esc, the second ⌘E: the line and its answer both.
    func closeLine() {
        closedByKey = true
        dismiss()
        line = nil
        summonedFocus = nil
    }

    /// The caret left the line. It stays while it has an answer to show — the answer's buttons are
    /// what the pointer went to — and goes with it otherwise.
    func lineLostFocus(at place: LinePlace) {
        guard line == place, answer == nil else { return }
        closedByKey = false
        line = nil
        summonedFocus = nil
    }

    private func snapshot(for place: LinePlace) -> (window: UUID, focus: PageFocus)? {
        guard case .page(let window) = place, let focus = focus?[window] else { return nil }
        return (window, focus)
    }

    private func place(for tab: BrowserTab?) -> LinePlace {
        guard let tab, tab.livePage != nil, !tab.isDocument, let focus = focus?[tab.id],
              !focus.isEmpty, focus.rect != .zero else { return .bottom }
        return .page(tab.id)
    }

    // MARK: Landing

    /// Put the answer back where it came from. Always a deliberate act — a key or a button — and
    /// always reversible: the page's own undo takes it back, because the text goes in through
    /// `insertText` rather than an assignment (`PageFocusScript`).
    func apply(in tab: BrowserTab?) {
        guard var answer, answer.isApplicable, let tab, tab.id == answer.windowID else { return }
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let whole = answer.landing == .replaceField
        let subject = answer.subject ?? PageFocus()
        answer.isApplied = true
        self.answer = answer
        Task {
            _ = try? await tab.runScript(PageFocusScript.insert,
                                         arguments: ["text": text, "whole": whole,
                                                     "subject": subject.text,
                                                     "start": subject.start, "end": subject.end])
        }
    }

    func copy() {
        #if os(macOS)
        guard let answer else { return }
        let text = answer.text.isEmpty ? (answer.error ?? "") : answer.text
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    func cancel() {
        task?.cancel()
        #if os(macOS)
        if lineAgent != nil { agentSession?.cancel() }
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
        // The agent's side of it: the next question is a chat of its own, not the one the line was
        // going on with.
        startsAgentChat = true
        #if os(macOS)
        continuedChat = nil
        #endif
    }

    // MARK: The prompt

    private func currentSession() throws -> LanguageModelSession {
        // The page's own tools are the window's, not the app's, so a session outlives them: the
        // window navigates and what it offers is something else (docs/webmcp.md, stage 4). The
        // signature is empty while WebMCP is off — which is the default — and then this is the
        // session cache exactly as it was.
        let pageSignature = tools?.pageToolsSignature ?? ""
        if let session, sessionModel == settings.model, sessionPageTools == pageSignature { return session }
        let modelTools = try (tools?.tools(for: .assistant) ?? []).map { try BrowserModelTool($0) }
        let pageTools = tools?.pageModelTools() ?? []
        let session = try settings.makeSession(instructions: Self.instructions, tools: modelTools + pageTools)
        self.session = session
        sessionModel = settings.model
        sessionPageTools = pageSignature
        return session
    }

    /// What `pageToolsSignature` said when the session was built.
    private var sessionPageTools = ""

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
