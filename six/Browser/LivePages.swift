import Foundation

// Compiled away on Apple, deliberately: the app has `LivePageCache`, which is the same rule over
// `WebPage`, and the synchronized `six/` folder would otherwise hand this to both app targets as a
// second, unused copy of it. Off Apple it is `SixCore`'s, listed in the root manifest.
#if os(Linux) || os(Windows)

/// How many columns keep a real page, and which ones — on the fronts whose engine is a C API.
///
/// A web view is a web content process — a JavaScript heap, a render tree, timers, a compositor. A
/// strip of a hundred columns cannot hold a hundred of them, so six does what every browser does and
/// calls by the same name: it **discards** the pages it is unlikely to be asked for and builds them
/// again from the address. Discarding is not closing — the column stays in the strip with its title
/// and its address.
///
/// The policy is the Mac's, deliberately: `LivePageCache` there pins what the strip is showing and
/// evicts the rest by least-recent use, with the budget sized from the machine's memory. It could
/// not simply be moved — it imports WebKit — so what is shared is the rule rather than the code, and
/// the numbers are the same ones:
///
/// - about one page per gigabyte of RAM, clamped to 8…32
/// - `SIX_LIVE_PAGES=n` pins it, for measuring
/// - the focused workspace's visible columns plus half a screen of margin are never evicted
///
/// It was Linux's until Windows needed the same thing; the two fronts hand it different notions of
/// "all" (Linux the focused workspace, because that is all its strip widget builds; Windows every
/// column of every profile, because a hidden `WKView` costs nothing to keep while it is in budget),
/// and that difference is the caller's, not this type's.
///
/// (`docs/architecture.md` has what the Mac measured: 31 columns, 22 web processes and 798 MB with
/// the budget out of the way, 6 and 287 MB with it in place.)
nonisolated struct LivePages {
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

#endif
