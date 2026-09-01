import Foundation

// What six restores on the next launch, as plain `Codable` values. This file, `SnapshotStore` and
// `StatePersistence` use nothing but Foundation and Observation, so the format and the machinery can
// move to another platform as they are; only the mapping to and from the live objects (`BrowserState`,
// `NiriLayout`, `AgentSessionStore`) is macOS-specific.

nonisolated struct AppStateSnapshot: VersionedSnapshot {
    static let currentVersion = 1

    var version = AppStateSnapshot.currentVersion
    var browser: BrowserSnapshot
    var agent: AgentSnapshot
    /// The window's frame and fullscreen state; absent in files from before it was kept.
    var window: WindowSnapshot?
}

/// Profiles, the windows in them and where each sits in its profile's strip.
nonisolated struct BrowserSnapshot: Codable, Sendable {
    /// Written, and on the Mac never read back: `ProfileStore` is where the profiles live, and an
    /// empty table means a new browser rather than one to fill from here. It stays in the format
    /// because the fronts without a table of their own keep theirs here — Android reads exactly this
    /// key, and `state-fixture.json` is built on it.
    var profiles: [Profile]
    var selectedProfileID: UUID
    var tabs: [TabSnapshot]
    var strips: [StripSnapshot]
    /// Deep-research runs, absent in files from before them.
    var research: [ResearchRun]? = nil
}

nonisolated struct TabSnapshot: Codable, Sendable {
    var id: UUID
    var profileID: UUID
    /// Nil is the start page.
    var url: URL?
    var title: String
    /// A document window: the id of its Markdown file under `Documents/`; the text lives there.
    var document: DocumentSnapshot? = nil
    /// An MCP app window: where its server is and what drew it. Absent for every other kind.
    var app: AppWindowSnapshot? = nil
}

/// What the snapshot keeps of an MCP app window.
///
/// Not the session, and not the answer: an app is a live connection and a tool call that already
/// happened. What comes back is the *question* — which server, which tool, with what — and six
/// re-asks it only when re-asking is safe or when the person says so (see docs/mcp-apps.md).
/// Plain values, no MCP types, so this file stays what its header promises.
nonisolated struct AppWindowSnapshot: Codable, Sendable {
    var serverID: String
    var serverName: String
    /// A remote server's endpoint; nil for one six launches.
    var url: URL?
    var command: String = ""
    var commandArguments: [String] = []
    var tool: String
    var toolTitle: String
    /// What the tool was called with, as JSON text.
    var toolArguments: String
    var resourceURI: String
}

/// What the snapshot keeps of a document — everything but the text.
nonisolated struct DocumentSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var modifiedAt: Date
    var fileURL: URL?
    var showsPreview: Bool
}

/// One profile's workspace stack; `NiriStrip` itself is the stored shape.
nonisolated struct StripSnapshot: Codable, Sendable {
    var profileID: UUID
    var strip: NiriStrip
}

/// The selected agent and every conversation, keyed by agent and folder.
nonisolated struct AgentSnapshot: Codable, Sendable {
    var agentID: String
    var chats: [AgentChat]
}

/// A conversation with one agent in one folder: the transcript, and the ACP session id so the agent
/// can pick it up again with `session/load`.
nonisolated struct AgentChat: Codable, Sendable {
    var agentID: String
    var directoryPath: String
    var sessionID: String?
    var transcript: [AgentTranscriptItem] = []

    var key: String { AgentChat.key(agentID: agentID, directoryPath: directoryPath) }

    static func key(agentID: String, directoryPath: String) -> String { "\(agentID)|\(directoryPath)" }
}
