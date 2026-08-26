import Foundation
import Observation

/// Starts and follows deep-research runs. The agent runs the loop; this makes the place for it — a
/// named workspace with a document window — hands over the preset, and keeps the run's record in
/// `BrowserState.research` up to date while the agent works.
@MainActor
@Observable
final class ResearchCoordinator {
    @ObservationIgnored private let browser: BrowserState
    @ObservationIgnored private let agentSession: AgentSessionStore
    @ObservationIgnored private let settings: SettingsStore

    init(browser: BrowserState, agentSession: AgentSessionStore, settings: SettingsStore) {
        self.browser = browser
        self.agentSession = agentSession
        self.settings = settings
    }

    /// The preset, as the user left it (or the built-in one).
    var template: String {
        get { settings.researchTemplate.isEmpty ? ResearchPreset.defaultTemplate : settings.researchTemplate }
        set { settings.researchTemplate = newValue == ResearchPreset.defaultTemplate ? "" : newValue }
    }

    var sourceCount: Int {
        get { settings.researchSources }
        set { settings.researchSources = max(1, min(20, newValue)) }
    }

    /// `research: …` or `/research …` on the ⌘K line starts (or continues) a run.
    static func question(fromCommand text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/research ", "research: ", "Research: ", "исследуй: ", "Исследуй: "] where trimmed.hasPrefix(prefix) {
            let question = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return question.isEmpty ? nil : question
        }
        return nil
    }

    /// A new run in the current profile: workspace named after the question, a document in it, and
    /// the agent told to go. If the focused workspace already belongs to a run, the question is a
    /// follow-up into that run's document instead.
    @discardableResult
    func start(_ question: String, agent: ACPAgentDefinition? = nil, onUpdate: ((AgentSessionStore.LiveUpdate) -> Void)? = nil) async -> AgentSessionStore.PromptOutcome {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return .failed("Empty question") }
        if let existing = browser.focusedRun, browser.tab(existing.documentTabID) != nil {
            return await followUp(existing, question: question, agent: agent, onUpdate: onUpdate)
        }
        let profile = browser.selectedProfile
        let name = uniqueWorkspaceName(ResearchRun.workspaceName(for: question), in: profile.id)
        guard let index = browser.layout.workspaceIndex(named: name, in: profile.id, createIfMissing: true) else {
            return .failed("Couldn't create a workspace")
        }
        let documentTab = browser.newDocument(text: ResearchPreset.initialText(question: question), in: profile.id, workspace: index, activate: true)
        documentTab.document?.showsPreview = true
        let workspaceID = browser.layout.strip(for: profile.id).workspaces[index].id
        var run = ResearchRun(question: question, profileID: profile.id, workspaceID: workspaceID, documentTabID: documentTab.id)
        run.isRunning = true
        run.status = "starting…"
        browser.update(run)
        let prompt = ResearchPreset.prompt(template: template, question: question, workspace: name, document: documentTab.id,
                                           profile: profile.name, sources: sourceCount)
        return await drive(run, prompt: prompt, agent: agent, onUpdate: onUpdate)
    }

    private func followUp(_ existing: ResearchRun, question: String, agent: ACPAgentDefinition?, onUpdate: ((AgentSessionStore.LiveUpdate) -> Void)?) async -> AgentSessionStore.PromptOutcome {
        var run = existing
        run.followUps.append(question)
        run.isRunning = true
        run.status = "follow-up…"
        browser.update(run)
        let strip = browser.layout.strip(for: run.profileID)
        let workspace = strip.workspaces.first { $0.id == run.workspaceID }?.name ?? ResearchRun.workspaceName(for: run.question)
        let profile = browser.profiles.first { $0.id == run.profileID }?.name ?? ""
        let prompt = ResearchPreset.prompt(template: ResearchPreset.followUpTemplate, question: question, workspace: workspace,
                                           document: run.documentTabID, profile: profile, sources: sourceCount)
        return await drive(run, prompt: prompt, agent: agent, onUpdate: onUpdate)
    }

    private func drive(_ run: ResearchRun, prompt: String, agent: ACPAgentDefinition?, onUpdate: ((AgentSessionStore.LiveUpdate) -> Void)?) async -> AgentSessionStore.PromptOutcome {
        if let agent, agentSession.agent != agent { agentSession.agent = agent }
        let id = run.id
        let outcome = await agentSession.prompt(prompt) { [weak self] update in
            guard let self, var current = self.browser.research.first(where: { $0.id == id }) else { return }
            if case .activity(let title) = update { current.status = title; self.browser.update(current) }
            onUpdate?(update)
        }
        if var current = browser.research.first(where: { $0.id == id }) {
            current.isRunning = false
            switch outcome {
            case .finished(let stop): current.status = stop == .endTurn ? "done \(Date().formatted(date: .omitted, time: .shortened))" : "stopped: \(stop.rawValue)"
            case .failed(let message): current.status = "failed: \(message.prefix(80))"
            }
            browser.update(current)
            // A document that still says "Researching…" after a failed run should say what happened.
            if case .failed = outcome, let document = browser.tab(current.documentTabID)?.document, document.text.contains("_Researching…_") {
                document.text = document.text.replacingOccurrences(of: "_Researching…_", with: "_The run failed: \(current.status)_")
            }
        }
        return outcome
    }

    private func uniqueWorkspaceName(_ base: String, in profileID: UUID) -> String {
        let existing = Set(browser.layout.strip(for: profileID).workspaces.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        for n in 2...99 where !existing.contains("\(base) \(n)".lowercased()) { return "\(base) \(n)" }
        return "\(base) \(UUID().uuidString.prefix(4))"
    }
}
