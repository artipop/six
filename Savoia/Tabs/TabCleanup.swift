import Foundation

/// Which tabs were left behind: not looked at for a period, and about nothing looked at since.
nonisolated enum TabCleanup {
    struct Tab: Sendable, Equatable {
        var id: UUID
        var vector: [Float]
        var host: String
        var seenAt: Date
        /// A group one of whose tabs was looked at is a topic still being read.
        var group: UUID? = nil
    }

    /// A page looked at within the period, from the history.
    struct Interest: Sendable, Equatable {
        var vector: [Float]
        var host: String
    }

    struct Thresholds: Sendable, Equatable {
        /// How near the closest recent page has to come to the tab's own nearest tabs for the topic to count as read.
        var kin: Float = -0.01
        var peers = 3
        /// Fewer recent pages than this, and the person was away rather than elsewhere.
        var activity = 5

        static let standard = Thresholds()
    }

    /// The tabs to offer for closing, the longest unseen first.
    static func abandoned(_ tabs: [Tab], history: [Interest], since: Date,
                          weights: TabTopics.Weights = .standard, thresholds: Thresholds = .standard) -> [UUID] {
        let recent = tabs.filter { $0.seenAt >= since }
        let interests = history + recent.map { Interest(vector: $0.vector, host: $0.host) }
        guard interests.count >= thresholds.activity else { return [] }
        let readGroups = Set(recent.compactMap(\.group))

        return tabs.filter { tab in
            guard tab.seenAt < since else { return false }
            if let group = tab.group, readGroups.contains(group) { return false }
            let nearest = interests.map { interest in
                TabTopics.cosine(tab.vector, interest.vector)
                    + (!tab.host.isEmpty && interest.host == tab.host ? weights.domain : 0)
            }.max() ?? -.infinity
            // Against its own neighbours, not a median: e5's cosines are too compressed for a fixed bar.
            let peers = tabs.filter { $0.id != tab.id }.map { TabTopics.cosine(tab.vector, $0.vector) }
                .sorted(by: >).prefix(thresholds.peers)
            let kin = peers.isEmpty ? 0 : peers.reduce(0, +) / Float(peers.count)
            return nearest - kin < thresholds.kin
        }
        .sorted { $0.seenAt < $1.seenAt }
        .map(\.id)
    }
}
