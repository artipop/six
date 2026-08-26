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
    var profiles: [Profile]
    var selectedProfileID: UUID
    var tabs: [TabSnapshot]
    var strips: [StripSnapshot]
}

nonisolated struct TabSnapshot: Codable, Sendable {
    var id: UUID
    var profileID: UUID
    /// Nil is the start page.
    var url: URL?
    var title: String
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
