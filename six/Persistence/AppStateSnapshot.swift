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
    /// Downloads that had not finished. Absent in files from before they were kept.
    var downloads: [DownloadSnapshot]? = nil
}

/// A download that did not finish, so the next launch can offer to fetch it again.
///
/// Only the unfinished ones, and only their identity: a finished download is a file in the
/// Downloads folder and nothing about it is lost. What is *not* here is the request as it was sent
/// — it carries the profile's session cookies, and cookies do not belong in a JSON file next to the
/// session. The address and the profile are enough to build it again with whatever cookies the
/// profile has when somebody asks, which is the better request anyway.
///
/// Neither is the resume data: it points at a partial file in a temporary directory the system is
/// entitled to empty, so a relaunched *Resume* would be a button that fails. A restored row starts
/// over, and says so.
nonisolated struct DownloadSnapshot: Codable, Sendable, Equatable {
    var url: URL
    var filename: String
    /// Whose cookies to use when it is asked for again. Nil for a download that had no window.
    var profileID: UUID?
    var referrer: URL?
    /// What the server said the whole file was, so the row can still say how big it is. -1 when it
    /// never said.
    var expected: Int64 = -1
    var startedAt: Date
}

nonisolated struct TabSnapshot: Codable, Sendable {
    var id: UUID
    var profileID: UUID
    /// Nil is the start page.
    var url: URL?
    var title: String
    /// Where the window has been, oldest first, and where it can go forward to — the same trail a
    /// discarded window keeps in memory (`BrowserTab.Trail`), written down so that ⌘[ still works
    /// after a relaunch. Addresses rather than WebKit's own back-forward list, because `WebPage`
    /// hands out no `interactionState` to restore one from. Absent in files from before it was kept.
    var back: [URL]? = nil
    var forward: [URL]? = nil
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
