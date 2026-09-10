import Foundation
import Observation

/// The order the windows were last looked at, and the ring ⌃Tab walks along it.
///
/// The rail is where windows *are*; this is where they have *been*. Both questions are worth asking
/// and they have different answers: the window you want next is usually the one you just came from,
/// and on a rail of a dozen that one can be six windows away in either direction. ⌥← and ⌥→ walk the
/// rail, ⌃Tab walks the memory — the same division as ⌥Tab and the workspace keys in any tiling
/// window manager, and the same one every browser's ⌃Tab has had since tabs existed.
///
/// The ring is fixed when the switch opens and does not reorder while it is held: a list that
/// resorted itself under the key being pressed would move the window you were aiming at. Only the
/// landing is remembered, which is what makes a lone ⌃Tab a toggle between two windows.
@MainActor
@Observable
final class WindowSwitcher {
    /// Windows in the order they were last focused, most recent first. This run only — like the list
    /// ⌘⇧T reopens from, it is a memory of what you did, not a fact about the strip, and nothing on
    /// disk should pretend to remember it after a relaunch.
    private(set) var recent: [UUID] = []
    /// The stops of this pass **as they are drawn**, left to right. Empty when nothing is being
    /// switched.
    private(set) var ring: [UUID] = []
    /// The same stops **as the key walks them**, which is the order they were last looked at.
    ///
    /// Two orders, because the two questions are different. ⌃Tab means *the window I was in before*,
    /// so stepping has to follow memory. But two halves of one column are drawn as two cards, and on
    /// the rail those two are always left then right — a row that put them in memory order swapped
    /// them from one press to the next, and asked you to read the pair again every time. So the pair
    /// is drawn where it stands and walked when it was used, and the highlight moves to whichever
    /// card that is.
    private(set) var walk: [UUID] = []
    private(set) var index = 0

    var isOpen: Bool { !ring.isEmpty }
    var selection: UUID? { ring.indices.contains(index) ? ring[index] : nil }

    /// The focus landed on a window. Ignored while the ring is open: nothing lands during a switch,
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
        // A ring of one is a ring: it is what a rail with one window on it opens, and a window
        // closing under an open ring leaves the same thing rather than a reason to close it.
        index = ring.isEmpty ? 0 : min(index, ring.count - 1)
    }

    /// Opens the ring over the windows that are on the rail: the ones already remembered, in the
    /// order they were last looked at, then the rest — restored from a snapshot, or never focused
    /// this run — in the order they stand on the rail.
    ///
    /// The window being read is always first, so the first ⌃Tab lands on the one before it.
    ///
    /// A rail with one window on it opens a ring of one, and that is deliberate: the key has to
    /// answer. Pressing it and getting nothing back is indistinguishable from a key that is not
    /// bound, or from a browser that has stopped listening — and this one is held down, so the
    /// nothing lasts as long as the hand does. One card, saying *this is what there is*, is an
    /// answer. Only an empty rail refuses, and there the screen is already saying so in the middle.
    ///
    /// `stop` says which windows are the same stop, and the caller decides what that means —
    /// `BrowserState.stopInTheRing` is where the answer lives and why. Two windows drawn as one stop
    /// are collapsed **after** the ring has been sorted by memory, so the one that survives is the
    /// one that was looked at more recently and landing on the stop puts you back in it.
    /// `group` says which stops stand in one place on the rail — the two halves of a column — and
    /// they are *drawn* in the order they stand there, in the slots memory gave them. Everything else
    /// keeps its place, so only the pair moves, and only between its own two slots.
    @discardableResult
    func open(_ ids: [UUID], current: UUID?, stop: (UUID) -> UUID, group: (UUID) -> UUID) -> Bool {
        guard !ids.isEmpty else { return false }
        let known = Set(ids)
        var order = recent.filter { known.contains($0) }
        order.append(contentsOf: ids.filter { !order.contains($0) })
        if let current, let at = order.firstIndex(of: current) {
            order.remove(at: at)
            order.insert(current, at: 0)
        }
        var seen = Set<UUID>()
        walk = order.filter { seen.insert(stop($0)).inserted }

        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var slots: [UUID: [Int]] = [:]
        for (position, id) in walk.enumerated() { slots[group(id), default: []].append(position) }
        ring = walk
        for (_, places) in slots where places.count > 1 {
            let alongTheRail = places.map { walk[$0] }.sorted { (rank[$0] ?? 0) < (rank[$1] ?? 0) }
            for (place, id) in zip(places, alongTheRail) { ring[place] = id }
        }
        index = current.flatMap { ring.firstIndex(of: $0) } ?? 0
        return true
    }

    /// One step along the **memory**, and round the end of it: a ring is a list of what you have, not
    /// a rail with ends, so there is no wall here to hit.
    ///
    /// The highlight then moves to wherever that stop is drawn, which for the halves of a split can
    /// be the card on the left — the key means "the one before this", and the pair is drawn where it
    /// stands rather than in the order it was used.
    func step(_ delta: Int) {
        guard !walk.isEmpty, let selection, let at = walk.firstIndex(of: selection) else { return }
        let next = walk[((at + delta) % walk.count + walk.count) % walk.count]
        index = ring.firstIndex(of: next) ?? index
    }

    /// The key came up. Gives back the window that was landed on, and closes the ring.
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
