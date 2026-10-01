import Foundation
import Observation

/// The order the tabs were last looked at, and the ring ⌃Tab walks along it. The tab bar is where
/// tabs *are*; this is where they have *been* — the tab you want next is usually the one you just
/// came from, however far along the bar it stands.
///
/// The ring is fixed when the switch opens and does not reorder while it is held: a list that
/// resorted itself under the key being pressed would move the window you were aiming at. Only the
/// landing is remembered, which is what makes a lone ⌃Tab a toggle between two windows.
@MainActor
@Observable
final class WindowSwitcher {
    /// Windows in the order they were last focused, most recent first. This run only — like the list
    /// ⌘⇧T reopens from, it is a memory of what you did, not a fact about the tabs, and nothing on
    /// disk should pretend to remember it after a relaunch.
    private(set) var recent: [UUID] = []
    /// The stops of this pass **as they are drawn**, left to right. Empty when nothing is being
    /// switched.
    private(set) var ring: [UUID] = []
    /// The same stops **as the key walks them**, which is the order they were last looked at.
    ///
    /// Two orders: ⌃Tab steps through memory, while cards that belong together (`group` in `open`)
    /// are drawn side by side in the order they stand.
    private(set) var walk: [UUID] = []
    private(set) var index = 0

    var isOpen: Bool { !ring.isEmpty }
    var selection: UUID? { ring.indices.contains(index) ? ring[index] : nil }

    /// The focus landed on a tab. Ignored while the ring is open: nothing lands during a switch,
    /// and a ring that reordered itself mid-press would be a ring nobody could aim.
    func note(_ id: UUID?) {
        guard let id, !isOpen else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
    }

    /// A window closed, or its profile was deleted with it.
    func forget(_ id: UUID) {
        recent.removeAll { $0 == id }
        walk.removeAll { $0 == id }
        guard let at = ring.firstIndex(of: id) else { return }
        ring.remove(at: at)
        // A ring of one is a ring: a tab closing under an open ring is not a reason to close it.
        index = ring.isEmpty ? 0 : min(index, ring.count - 1)
    }

    /// Opens the ring over `ids`: the ones already remembered, in the order they were last looked
    /// at, then the rest in the order given. The tab being read is first, so the first ⌃Tab lands on
    /// the one before it. One tab opens a ring of one — the key has to answer.
    ///
    /// `group` names which ids are drawn together, in the order given, where the first of them falls
    /// in memory.
    @discardableResult
    func open(_ ids: [UUID], current: UUID?, byRecency: Bool = true, group: (UUID) -> UUID) -> Bool {
        guard !ids.isEmpty else { return false }
        let known = Set(ids)
        var order = byRecency ? recent.filter { known.contains($0) } : []
        order.append(contentsOf: ids.filter { !order.contains($0) })
        if let current, let at = order.firstIndex(of: current) {
            if byRecency {
                order.remove(at: at)
                order.insert(current, at: 0)
            } else {
                order = Array(order[at...] + order[..<at])
            }
        }
        walk = order

        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var drawn = Set<UUID>()
        ring = walk.flatMap { id -> [UUID] in
            guard drawn.insert(group(id)).inserted else { return [] }
            return walk.filter { group($0) == group(id) }.sorted { (rank[$0] ?? 0) < (rank[$1] ?? 0) }
        }
        index = current.flatMap { ring.firstIndex(of: $0) } ?? 0
        return true
    }

    /// One card along, the way they are drawn, and round the ends: the arrows, against ⌃Tab's step
    /// through memory.
    func walkCards(_ delta: Int) {
        guard !ring.isEmpty else { return }
        index = ((index + delta) % ring.count + ring.count) % ring.count
    }

    /// One step along the memory, and round the end of it. The highlight moves to wherever that
    /// stop is drawn.
    func step(_ delta: Int) {
        guard !walk.isEmpty, let selection, let at = walk.firstIndex(of: selection) else { return }
        let next = walk[((at + delta) % walk.count + walk.count) % walk.count]
        index = ring.firstIndex(of: next) ?? index
    }

    /// The key came up. Gives back the tab that was landed on, and closes the ring.
    func commit() -> UUID? {
        defer {
            ring = []
            walk = []
            index = 0
        }
        return selection
    }

    func cancel() {
        ring = []
        walk = []
        index = 0
    }
}
