import Foundation

/// One deep-research run: a question, the workspace it works in, the document it writes and the
/// windows it opened. Kept in the snapshot so a relaunch still knows which document a follow-up
/// question belongs to and which workspace is the record of the run.
nonisolated struct ResearchRun: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var question: String
    var profileID: UUID
    /// `NiriWorkspace.id` — stable across renames and moves, unlike the index.
    var workspaceID: UUID
    /// The document window's tab id.
    var documentTabID: UUID
    var sourceWindowIDs: [UUID] = []
    var startedAt: Date = Date()
    var isRunning = false
    /// Follow-up questions asked into the same document, oldest first.
    var followUps: [String] = []
    /// The agent's last word: what it was doing, or how it ended.
    var status: String = ""

    /// A workspace name from the question: one line, short enough for a plate.
    static func workspaceName(for question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "?!."))
        guard trimmed.count > 48 else { return trimmed.isEmpty ? "Research" : trimmed }
        let cut = trimmed.prefix(48)
        let atSpace = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return String(atSpace) + "…"
    }
}

/// The prompt a run hands the agent. The bounds — how many sources, how deep — are words in the
/// preset, where the user can read and change them, not numbers in code.
nonisolated enum ResearchPreset {
    static let defaultSources = 5

    static let defaultTemplate = """
        Research the question below and write the answer into the document window in this workspace, \
        citing the pages you used.

        How to work:
        1. `web_search` first (more than one query if the question has parts). Pick up to {sources} pages \
        actually worth comparing — different sites, or the same site on the different options — and open \
        each with `open_window` in workspace "{workspace}" with `activate: false`, so the user's screen does \
        not jump while you work. Prefer the exact page for what was asked (a route, a product, a date) over \
        a site's front page. Do not follow links more than one step from a search result.
        2. Before reading, write the outline into the document with `write_document` (`mode: replace`): \
        a `# ` title, a one-paragraph summary placeholder, and a `## ` heading per part of the answer. \
        The user reads the document as it grows.
        3. Read each source with `get_page_content`. For every page you use, call `cite` (window_id, and the \
        passage that matters) and use the `[n]` it returns inline. If a passage answers a point directly, \
        `highlight_page` it and cite the anchor it hands back, so the citation points at the sentences.
        4. Fill the sections in one at a time with `write_document` (`mode: section`, `section: <heading>`); \
        finish with the summary. Write in the user's language. Be concrete: numbers, dates, prices, names. \
        Say what the sources disagree on. Do not rewrite a section the user has edited.
        5. Leave every window open — the workspace is the record. Reply with two or three lines: what the \
        document now says, and what is still uncertain.

        Document: `{document}` in workspace "{workspace}" of profile "{profile}".

        Question: {question}
        """

    static let followUpTemplate = """
        Follow-up on the research in workspace "{workspace}" (document `{document}`): {question}

        Read the document with `read_document` first. Extend or revise it — open new sources into the same \
        workspace with `activate: false` if needed, cite them, and write the new material into the section \
        it belongs to (`write_document`, `mode: section`) or into a new `## ` section. Keep what is there.
        """

    static func prompt(template: String, question: String, workspace: String, document: UUID, profile: String, sources: Int) -> String {
        template
            .replacingOccurrences(of: "{question}", with: question)
            .replacingOccurrences(of: "{workspace}", with: workspace)
            .replacingOccurrences(of: "{document}", with: document.uuidString)
            .replacingOccurrences(of: "{profile}", with: profile)
            .replacingOccurrences(of: "{sources}", with: String(sources))
    }

    /// The document's opening text: the question as the title, and a note that the run is under way.
    static func initialText(question: String) -> String {
        "# \(question.trimmingCharacters(in: .whitespacesAndNewlines))\n\n_Researching…_\n"
    }
}

// MARK: - Settings

/// The setting lives in the settings table; the knowledge of what its string means lives here,
/// beside the type it means it as. `SettingsStore` itself keeps only keys and strings.
extension SettingsStore {
    /// How many sources a research run opens.
    var researchSources: Int {
        get { Int(self[.researchSources] ?? "") ?? ResearchPreset.defaultSources }
        set { self[.researchSources] = String(newValue) }
    }
}
