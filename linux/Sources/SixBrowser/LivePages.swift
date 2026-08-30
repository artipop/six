import Foundation

@testable internal import SixCore

/// How many columns keep a real page, and which ones.
///
/// A `WebKitWebView` is a web content process — a JavaScript heap, a render tree, timers, a
/// compositor. A strip of a hundred columns cannot hold a hundred of them, so six does what every
/// browser does and calls by the same name: it **discards** the pages it is unlikely to be asked for
/// and builds them again from the address. Discarding is not closing — the column stays in the strip
/// with its title and its address.
///
/// The policy is the Mac's, deliberately: `LivePageCache` there pins what the strip is showing and
/// evicts the rest by least-recent use, with the budget sized from the machine's memory. It could
/// not simply be moved — it imports WebKit and so cannot live in `SixCore` — so what is shared is the
/// rule rather than the code, and the numbers are the same ones:
///
/// - about one page per gigabyte of RAM, clamped to 8…32
/// - `SIX_LIVE_PAGES=n` pins it, for measuring
/// - the focused workspace's visible columns plus half a screen of margin are never evicted
///
/// (`docs/architecture.md` has what the Mac measured: 31 columns, 22 web processes and 798 MB with
/// the budget out of the way, 6 and 287 MB with it in place.)
struct LivePages {
    private(set) var live: Set<UUID> = []
    /// Most recently focused last — the eviction order when nothing is pinned.
    private var order: [UUID] = []
    let budget: Int

    init() {
        let fromMemory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let sized = min(32, max(8, Int(fromMemory)))
        budget = ProcessInfo.processInfo.environment["SIX_LIVE_PAGES"].flatMap(Int.init) ?? sized
    }

    /// Bring a column to the warm end. Called when a column is focused or built.
    mutating func touch(_ tabID: UUID) {
        order.removeAll { $0 == tabID }
        order.append(tabID)
        live.insert(tabID)
    }

    mutating func forget(_ tabID: UUID) {
        order.removeAll { $0 == tabID }
        live.remove(tabID)
    }

    /// What `settle` is about to drop, without dropping it — so a page can be photographed while it
    /// still exists.
    func wouldDrop(pinned: Set<UUID>, all: [UUID]) -> Set<UUID> {
        var copy = self
        return copy.settle(pinned: pinned, all: all)
    }

    /// Decide what stays. `pinned` is what the strip is showing — those keep their pages whatever
    /// the budget says, because a column half on screen with no page in it is a hole the user can
    /// see. Everything else is least-recently-used, deepest first.
    ///
    /// Returns what was dropped, so the caller can tell the registry.
    @discardableResult
    mutating func settle(pinned: Set<UUID>, all: [UUID]) -> Set<UUID> {
        live.formUnion(pinned)
        for id in pinned where !order.contains(id) { order.append(id) }
        order.removeAll { !all.contains($0) }
        live = live.intersection(all)

        guard live.count > budget else { return [] }
        var dropped: Set<UUID> = []
        for id in order where live.count - dropped.count > budget {
            guard !pinned.contains(id) else { continue }
            dropped.insert(id)
        }
        live.subtract(dropped)
        order.removeAll { dropped.contains($0) }
        return dropped
    }
}
