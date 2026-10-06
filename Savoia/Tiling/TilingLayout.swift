import Foundation
import Observation
import SwiftUI

// MARK: - Model

/// One tab — or two of them, shown side by side. Two is the ceiling.
nonisolated struct TilingColumn: Identifiable, Hashable, Sendable, Codable {
    /// The column's own identity, and deliberately not its tab's: a pair that loses a half is the
    /// same column, and a front shows a page's view in one place at a time.
    var id = UUID()
    /// The window on the left, and the only one unless the column is split.
    var tabID: UUID
    /// The window sharing the column, on the right.
    var second: UUID?
    /// Which half the focus is in: 0 for `tabID`, 1 for `second`. Everything keyed off the selection
    /// — the address field, ⌘W, the assistant, ⌃Tab — points at that one.
    var pane: Int = 0
    /// Read from sessions saved when the tint was a window's and not its row's; `normalize` moves it.
    var lean: TilingBlend?
    /// Kept at the front of its workspace and drawn as an icon in the tab bar; nil when not.
    var pinned: Bool?

    init(id: UUID = UUID(), tabID: UUID, second: UUID? = nil, pane: Int = 0) {
        self.id = id
        self.tabID = tabID
        self.second = second
        self.pane = pane
    }

    /// The windows in it, left to right.
    var tabIDs: [UUID] { second.map { [tabID, $0] } ?? [tabID] }
    var isSplit: Bool { second != nil }
    var isPinned: Bool { pinned == true }
    /// The focused half's window — which is the whole of what a column meant before it could split.
    var focusedTabID: UUID { pane == 1 ? (second ?? tabID) : tabID }
    func holds(_ id: UUID) -> Bool { tabID == id || second == id }
    func paneIndex(of id: UUID) -> Int? { tabID == id ? 0 : (second == id ? 1 : nil) }

    /// Puts a second tab in the column, on a side, and leaves the focus where it was.
    mutating func insert(_ id: UUID, on side: TilingPlacement) {
        guard second == nil else { return }
        switch side {
        case .right, .end:
            second = id
        case .left:
            second = tabID
            tabID = id
            pane = 1
        }
    }

    /// Takes a window out, and says whether the column still has one. `false` is the column going
    /// with it.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        switch paneIndex(of: id) {
        case 0:
            guard let second else { return false }
            tabID = second
            self.second = nil
            pane = 0
        case 1:
            second = nil
            pane = 0
        default:
            break
        }
        return true
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, tabID, second, pane, lean, pinned
    }

    /// Older session files have only `tabID`; the rest decode at their defaults.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try values.decode(UUID.self, forKey: .tabID)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        second = try values.decodeIfPresent(UUID.self, forKey: .second)
        pane = try values.decodeIfPresent(Int.self, forKey: .pane) ?? 0
        lean = try values.decodeIfPresent(TilingBlend.self, forKey: .lean)
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned)
    }
}

/// A row between two groups, or next to one it almost belongs to (`to` nil); `weight` is how far it
/// is from `from` towards the other. Its colour is the two mixed (`GroupColor`).
nonisolated struct TilingBlend: Hashable, Sendable, Codable {
    var from: UUID
    var to: UUID?
    var weight: Double

    var parents: [UUID] { [from] + (to.map { [$0] } ?? []) }

    func joins(_ other: TilingBlend) -> Bool { Set(parents) == Set(other.parents) }
}

/// A workspace: a tab group when it has a name or stands between groups, loose tabs otherwise.
nonisolated struct TilingWorkspace: Identifiable, Sendable, Codable {
    var id = UUID()
    /// Optional. A named workspace does not vanish the moment it runs out of tabs: it is asked about
    /// first (`TilingWorkspaceRemoval`), because losing a typed name silently is losing work.
    var name: String = ""
    var columns: [TilingColumn] = []
    /// Index of the focused column.
    var focus: Int = 0
    /// Folded up to its name in the tab bar; absent is open.
    var collapsed: Bool?
    /// Set on a row that stands between groups; such a row is a group whether or not it is named.
    var blend: TilingBlend?
    /// An index into `GroupColor.palette`, given when the row first becomes a group.
    var color: Int?

    var isCollapsed: Bool { collapsed == true }
    var isGroup: Bool { !name.isEmpty || blend != nil }
    /// Only a group can be folded.
    var isFolded: Bool { isCollapsed && isGroup }
    var isEmpty: Bool { columns.isEmpty }
    var focusedColumn: TilingColumn? { columns.indices.contains(focus) ? columns[focus] : nil }
}

/// Which side of the focused column a new tab opens on.
nonisolated enum TilingPlacement: Equatable, Sendable {
    case left
    case right
    /// Past the last column of the workspace, whatever its focus is.
    case end
}

/// A named workspace that has just lost its last tab, and the question that goes with it: an unnamed
/// one disappears silently, a named one is asked about. `TilingLayout` only asks.
nonisolated struct TilingWorkspaceRemoval: Identifiable, Sendable, Equatable {
    /// The workspace's own id, so an answer cannot land on a row that has moved.
    var id: UUID
    var name: String
    var profileID: UUID
}

/// The vertical stack of workspaces belonging to one profile.
nonisolated struct TilingStrip: Sendable, Codable {
    var workspaces: [TilingWorkspace] = [TilingWorkspace()]
    /// Index of the focused workspace.
    var focus: Int = 0
}

// MARK: - Layout

/// The workspaces of every profile, and the focus and move operations on them; `BrowserState` owns
/// the tabs the columns point at, and the tab bar draws them.
@MainActor
@Observable
final class TilingLayout {
    static let switchAnimation: Animation = .smooth(duration: 0.34, extraBounce: 0.05)
    /// `SAVOIA_UI_DEBUG=1`: what the layout was asked to do, and what it thought it was doing. A gesture
    /// that does nothing is either not arriving or not meaning what it looks like, and this says which.
    static let tracesUI = ProcessInfo.processInfo.environment["SAVOIA_UI_DEBUG"] == "1"

    static func trace(_ message: @autoclosure () -> String) {
        guard tracesUI else { return }
        Log.debug(.ui, message())
    }

    /// Named workspaces that have run out of windows and are waiting for an answer, oldest first.
    /// A queue rather than one at a time because closing several windows at once — a profile going
    /// away, a row being cleared — can empty more than one row, and a question that overwrote
    /// another would delete a workspace nobody was asked about.
    private(set) var pendingRemovals: [TilingWorkspaceRemoval] = []
    /// The one being asked about now.
    var workspaceToRemove: TilingWorkspaceRemoval? { pendingRemovals.first }
    /// A workspace `normalize` leaves standing once even though it is empty.
    @ObservationIgnored private var keepsEmptyOnce: UUID?
    /// The profile on screen.
    var activeProfileID: UUID = UUID()

    private var strips: [UUID: TilingStrip] = [:]

    // MARK: Access

    var strip: TilingStrip { strips[activeProfileID] ?? TilingStrip() }
    var workspaces: [TilingWorkspace] { strip.workspaces }
    var focusedWorkspaceIndex: Int { min(max(0, strip.focus), max(0, strip.workspaces.count - 1)) }
    var focusedWorkspace: TilingWorkspace? {
        let s = strip
        return s.workspaces.indices.contains(s.focus) ? s.workspaces[s.focus] : nil
    }
    var focusedTabID: UUID? { focusedWorkspace?.focusedColumn?.focusedTabID }
    var hasColumns: Bool { strip.workspaces.contains { !$0.isEmpty } }

    private func mutate(_ body: (inout TilingStrip) -> Void) {
        mutate(profile: activeProfileID, body)
    }

    /// Changes made in here are not animated, whatever the caller is animating: a tab moving
    /// between workspaces would otherwise be shown twice, and a page's view can be in one place.
    private func unanimated(_ body: () -> Void) {
        withTransaction(Transaction(animation: nil), body)
    }

    /// The same, for a change that only sometimes needs it — a window closing out of a split, which
    /// is a width change, against one closing out of a column of its own, which is not.
    private func unanimated(if condition: Bool, _ body: () -> Void) {
        if condition { unanimated(body) } else { body() }
    }

    private func mutate(profile: UUID, _ body: (inout TilingStrip) -> Void) {
        var s = strips[profile] ?? TilingStrip()
        body(&s)
        normalize(&s)
        strips[profile] = s
        prunePendingRemovals()
    }

    /// Any profile's strip, not just the one on screen — the MCP server lists them all.
    func strip(for profileID: UUID) -> TilingStrip {
        strips[profileID] ?? TilingStrip()
    }

    /// Every strip, for the snapshot.
    var allStrips: [UUID: TilingStrip] { strips }

    /// Replaces every strip with saved ones (normalised, so a stale file can't leave a strip without
    /// its trailing empty workspace or with a focus out of range).
    func restore(strips saved: [UUID: TilingStrip]) {
        strips = [:]
        for (profileID, strip) in saved {
            mutate(profile: profileID) { $0 = strip }
        }
    }

    /// A row has just lost its last window: if it has a name, it becomes a question.
    ///
    /// Every named row asks the same one, whoever the name came from — a person typing into the
    /// plate, a research run naming a workspace after its question, an agent's `workspace: "notes"`.
    /// Guessing which of those is a reservation is exactly what this does not do; the person who is
    /// there answers instead.
    ///
    /// Deliberately here and not in `normalize`: normalize cannot tell a row that has *become* empty
    /// from one that is empty because it was made a moment ago, and every caller of
    /// `workspaceIndex(named:createIfMissing:)` makes a named empty row and fills it on the next
    /// line. Only a row that had something and lost it is worth asking about.
    private func askBeforeRemoving(_ workspace: TilingWorkspace, in profileID: UUID) {
        guard workspace.isEmpty, !workspace.name.isEmpty else { return }
        guard !pendingRemovals.contains(where: { $0.id == workspace.id }) else { return }
        pendingRemovals.append(TilingWorkspaceRemoval(id: workspace.id, name: workspace.name, profileID: profileID))
        TilingLayout.trace("asking about \(workspace.name)")
    }

    /// Yes: the row goes. Guarded on still being empty, because the question outlives the moment it
    /// was asked in — a window can arrive in that row while it is up, and then there is nothing to
    /// remove and the answer is about a workspace that no longer needs one.
    func removeWorkspace(_ id: UUID) {
        // The question is one way in; the plate's own **Delete Workspace** is the other, for a row
        // that was already standing empty when this rule arrived and so was never asked about.
        let profileID = pendingRemovals.first { $0.id == id }?.profileID
            ?? strips.first { $0.value.workspaces.contains { $0.id == id } }?.key
        guard let profileID else { return }
        pendingRemovals.removeAll { $0.id == id }
        mutate(profile: profileID) { s in
            guard let index = s.workspaces.firstIndex(where: { $0.id == id }), s.workspaces[index].isEmpty else { return }
            s.workspaces.remove(at: index)
            s.focus = min(s.focus, max(0, s.workspaces.count - 1))
        }
    }

    /// No: nothing happens. The row stands with its name, the way a named row always has, and is not
    /// asked about again until it is filled and emptied again.
    func keepWorkspace(_ id: UUID) {
        pendingRemovals.removeAll { $0.id == id }
    }

    /// A question is only worth asking while it is still true. A row that was filled again while it
    /// was up, or that went some other way, takes its question with it.
    private func prunePendingRemovals() {
        pendingRemovals.removeAll { pending in
            guard let workspace = strips[pending.profileID]?.workspaces.first(where: { $0.id == pending.id })
            else { return true }
            return !workspace.isEmpty
        }
    }

    /// Keeps exactly one trailing empty workspace and drops the empty ones in between — dynamic
    /// workspaces. A named workspace stays even when it is empty: what
    /// removes it is the answer to `TilingWorkspaceRemoval`, not this.
    private func normalize(_ s: inout TilingStrip) {
        let focusedID = s.workspaces.indices.contains(s.focus) ? s.workspaces[s.focus].id : nil
        var kept = s.workspaces.filter { !$0.isEmpty || !$0.name.isEmpty || $0.id == keepsEmptyOnce }
        if let trailing = s.workspaces.last, trailing.isEmpty, trailing.name.isEmpty, trailing.id != keepsEmptyOnce {
            var spare = trailing // reuse its identity so focus survives the prune
            spare.blend = nil
            kept.append(spare)
        } else {
            kept.append(TilingWorkspace())
        }
        for i in kept.indices where kept[i].columns.contains(where: \.isPinned) {
            let focused = kept[i].focusedColumn?.id
            kept[i].columns = kept[i].columns.filter(\.isPinned) + kept[i].columns.filter { !$0.isPinned }
            if let focused, let index = kept[i].columns.firstIndex(where: { $0.id == focused }) { kept[i].focus = index }
        }
        for i in kept.indices {
            for j in kept[i].columns.indices {
                guard let lean = kept[i].columns[j].lean else { continue }
                if kept[i].name.isEmpty, kept[i].blend == nil { kept[i].blend = lean }
                kept[i].columns[j].lean = nil
            }
        }
        // A parent that stops being a group leaves the row next to the other, or ungrouped.
        let parents = Set(kept.filter { !$0.name.isEmpty && $0.blend == nil }.map(\.id))
        for i in kept.indices {
            guard let blend = kept[i].blend else { continue }
            let to = blend.to.flatMap { parents.contains($0) ? $0 : nil }
            if parents.contains(blend.from) {
                if to == nil, blend.to != nil { kept[i].blend?.to = nil }
            } else if let to {
                kept[i].blend = TilingBlend(from: to, to: nil, weight: 1 - blend.weight)
            } else {
                kept[i].blend = nil
            }
        }
        var used = kept.compactMap { $0.isGroup ? $0.color : nil }
        for i in kept.indices {
            if kept[i].isGroup, kept[i].blend == nil, kept[i].color == nil {
                kept[i].color = GroupColor.free(among: used)
                used.append(kept[i].color!)
            }
            if !kept[i].isGroup { kept[i].color = nil }
            kept[i].focus = min(max(0, kept[i].focus), max(0, kept[i].columns.count - 1))
        }
        if let focusedID, let index = kept.firstIndex(where: { $0.id == focusedID }) {
            s.focus = index
        } else {
            s.focus = min(max(0, s.focus), kept.count - 1)
        }
        s.workspaces = kept
        keepsEmptyOnce = nil
    }

    /// The tabs on screen: the selected one, and its partner when two are shown side by side. This is
    /// what gets a real web view and what the live-page budget pins (`LivePageCache`).
    var visibleTabIDs: Set<UUID> { Set(focusedWorkspace?.focusedColumn?.tabIDs ?? []) }

    // MARK: Columns

    func insertColumn(tabID: UUID, on side: TilingPlacement = .right) {
        mutate { s in
            guard s.workspaces.indices.contains(s.focus) else { return }
            var ws = s.workspaces[s.focus]
            let index = insertionIndex(in: ws, on: side)
            ws.columns.insert(TilingColumn(tabID: tabID), at: min(index, ws.columns.count))
            ws.focus = min(index, ws.columns.count - 1)
            s.workspaces[s.focus] = ws
        }
    }

    /// Where a new window goes in a row: after the focused column, or — for the `+` at the near end —
    /// before it. An empty row has only one place either way.
    private func insertionIndex(in workspace: TilingWorkspace, on side: TilingPlacement) -> Int {
        guard !workspace.columns.isEmpty else { return 0 }
        switch side {
        case .end: return workspace.columns.count
        case .right: return workspace.focus + 1
        case .left: return workspace.focus
        }
    }

    /// Opens a tab in a given workspace of a given profile's strip — what an agent asks for through MCP.
    /// `workspace` defaults to the strip's focused one; with `focus` off the window is added right of
    /// the focused column but nothing on screen moves.
    func insertColumn(tabID: UUID, in profileID: UUID, workspace: Int? = nil, focus: Bool = true,
                      on side: TilingPlacement = .right) {
        mutate(profile: profileID) { s in
            let target = min(max(0, workspace ?? s.focus), s.workspaces.count - 1)
            guard s.workspaces.indices.contains(target) else { return }
            var ws = s.workspaces[target]
            let index = insertionIndex(in: ws, on: side)
            ws.columns.insert(TilingColumn(tabID: tabID), at: min(index, ws.columns.count))
            if focus {
                ws.focus = min(index, ws.columns.count - 1)
                s.focus = target
            }
            s.workspaces[target] = ws
        }
    }

    /// Where a window stands in a profile's strip: which row, and how far along it. Read before the
    /// column goes, so a window that comes back can come back where it was.
    func location(ofTabID tabID: UUID, in profileID: UUID) -> (workspace: Int, index: Int)? {
        for (w, workspace) in strip(for: profileID).workspaces.enumerated() {
            if let index = workspace.columns.firstIndex(where: { $0.holds(tabID) }) { return (w, index) }
        }
        return nil
    }

    /// Puts a column back where one was taken from — reopening a closed window. The row it left is not
    /// the row it returns to: windows have opened and closed since, so the place is a preference and
    /// not a promise, and both numbers land wherever the row can still take them.
    func restoreColumn(tabID: UUID, in profileID: UUID, workspace: Int, at index: Int) {
        mutate(profile: profileID) { s in
            guard !s.workspaces.isEmpty else { return }
            let target = min(max(0, workspace), s.workspaces.count - 1)
            var ws = s.workspaces[target]
            let at = min(max(0, index), ws.columns.count)
            ws.columns.insert(TilingColumn(tabID: tabID), at: at)
            ws.focus = at
            s.focus = target
            s.workspaces[target] = ws
        }
    }

    /// Index of the workspace with this name in a profile's strip, creating it (as the trailing
    /// empty workspace, which gets the name and so survives being empty) when there is none.
    func workspaceIndex(named name: String, in profileID: UUID, createIfMissing: Bool) -> Int? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let existing = strip(for: profileID).workspaces
        if let index = existing.firstIndex(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return index
        }
        guard createIfMissing else { return nil }
        var created: Int?
        mutate(profile: profileID) { s in
            if s.workspaces.last?.isEmpty == true, s.workspaces.last?.name.isEmpty == true {
                s.workspaces[s.workspaces.count - 1].name = wanted
            } else {
                s.workspaces.append(TilingWorkspace(name: wanted))
            }
            created = s.workspaces.count - 1
        }
        return created
    }

    /// Moves a column (wherever it is in the profile's strip) to a workspace by index, without changing focus.
    ///
    /// Un-animated for the reason `unanimated` gives: this is the same window changing rows, and an
    /// agent's `move_window` must not be able to trap WebKit either.
    func moveColumn(tabID: UUID, in profileID: UUID, toWorkspace target: Int) {
        unanimated {
            mutate(profile: profileID) { s in
                guard let from = s.workspaces.firstIndex(where: { $0.columns.contains { $0.holds(tabID) } }),
                      let at = s.workspaces[from].columns.firstIndex(where: { $0.holds(tabID) }) else { return }
                let target = max(0, target)
                guard target != from else { return }
                // The window and not the column it may be sharing — the one place that is still true,
                // and it is true because an agent names a window: `move_window` is asked for *this
                // page*, the way ⌘W closes this page, where ⌥⇧↓ moves what is in front of you and
                // that is a column (`carryColumn`). Half a split moved this way leaves the other half
                // where it stood, filling the column on its own.
                var column = s.workspaces[from].columns[at]
                if column.remove(tabID) {
                    s.workspaces[from].columns[at] = column
                    column = TilingColumn(tabID: tabID)
                } else {
                    s.workspaces[from].columns.remove(at: at)
                }
                s.workspaces[from].focus = min(s.workspaces[from].focus, max(0, s.workspaces[from].columns.count - 1))
                askBeforeRemoving(s.workspaces[from], in: profileID)
                while target >= s.workspaces.count { s.workspaces.append(TilingWorkspace()) }
                var destination = s.workspaces[target]
                let index = destination.columns.isEmpty ? 0 : destination.focus + 1
                destination.columns.insert(column, at: min(index, destination.columns.count))
                s.workspaces[target] = destination
            }
        }
    }

    func removeColumn(tabID: UUID) {
        // Half of a split closing leaves the other half to fill the column, which is a live page
        // changing width — `toggleSplit` has the account of why that must not be animated. A window
        // closing out of a column of its own changes nobody's width, and keeps its animation.
        let widensAWindow = strip.workspaces.contains { $0.columns.contains { $0.holds(tabID) && $0.isSplit } }
        unanimated(if: widensAWindow) {
            mutate { s in
                for i in s.workspaces.indices {
                    guard let index = s.workspaces[i].columns.firstIndex(where: { $0.holds(tabID) }) else { continue }
                    // Half a split closing leaves the other half where it stood, with the whole column to
                    // itself — closing one of two windows is not closing the pair.
                    if s.workspaces[i].columns[index].remove(tabID) {
                        s.workspaces[i].focus = index
                    } else {
                        s.workspaces[i].columns.remove(at: index)
                        s.workspaces[i].focus = max(0, min(index, s.workspaces[i].columns.count - 1))
                    }
                    askBeforeRemoving(s.workspaces[i], in: activeProfileID)
                    return
                }
            }
        }
    }

    /// Takes a column out of a strip that is not necessarily the one on screen, and — unlike closing
    /// a window — without asking about the row it empties.
    ///
    /// Both differences come from the one caller: a window moved to another profile
    /// (`BrowserState.moveTab(_:toProfile:)`). The column has to leave a strip nobody is looking at,
    /// or the row it left goes on drawing a window that now stands somewhere else. And the question
    /// a named row asks when it loses its last window would arrive over the profile the window went
    /// *to*, about a row on the one it left, saying the window had been closed — which it was not.
    /// The row keeps its name and stands empty, which is what answering "Keep It" would have done,
    /// and its own menu still offers to delete it.
    func removeColumn(tabID: UUID, from profileID: UUID) {
        mutate(profile: profileID) { s in
            for i in s.workspaces.indices {
                guard let index = s.workspaces[i].columns.firstIndex(where: { $0.holds(tabID) }) else { continue }
                if s.workspaces[i].columns[index].remove(tabID) {
                    s.workspaces[i].focus = index
                } else {
                    s.workspaces[i].columns.remove(at: index)
                    s.workspaces[i].focus = max(0, min(index, s.workspaces[i].columns.count - 1))
                }
                return
            }
        }
    }

    func focus(tabID: UUID) {
        mutate { s in
            for i in s.workspaces.indices {
                guard let index = s.workspaces[i].columns.firstIndex(where: { $0.holds(tabID) }) else { continue }
                s.focus = i
                s.workspaces[i].focus = index
                s.workspaces[i].columns[index].pane = s.workspaces[i].columns[index].paneIndex(of: tabID) ?? 0
                return
            }
        }
    }

    // MARK: Splitting a column

    /// Puts two tabs side by side in one column, wherever the second one is standing now — Show Side
    /// by Side, and `split_window` over MCP. The first keeps its place; the second arrives on its
    /// right. Refused where there is no room, and where either tab is not in this profile.
    @discardableResult
    func split(tabID: UUID, with other: UUID, in profileID: UUID) -> Bool {
        guard tabID != other else { return false }
        var done = false
        // Un-animated: a live page animated through every width in between is laid out at each one.
        unanimated {
            mutate(profile: profileID) { s in
                guard let home = Self.place(of: tabID, in: s) else { return }
                if s.workspaces[home.workspace].columns[home.index].holds(other) { done = true; return }
                guard !s.workspaces[home.workspace].columns[home.index].isSplit else { return }
                guard let from = Self.place(of: other, in: s) else { return }
                let homeID = s.workspaces[home.workspace].columns[home.index].id
                var source = s.workspaces[from.workspace].columns[from.index]
                if source.remove(other) {
                    s.workspaces[from.workspace].columns[from.index] = source
                } else {
                    s.workspaces[from.workspace].columns.remove(at: from.index)
                    s.workspaces[from.workspace].focus =
                        min(s.workspaces[from.workspace].focus, max(0, s.workspaces[from.workspace].columns.count - 1))
                    askBeforeRemoving(s.workspaces[from.workspace], in: profileID)
                }
                // By id, because taking the window out has moved every index after it.
                guard let index = s.workspaces[home.workspace].columns.firstIndex(where: { $0.id == homeID }) else { return }
                s.workspaces[home.workspace].columns[index].insert(other, on: .right)
                s.workspaces[home.workspace].focus = index
                s.focus = home.workspace
                done = true
            }
        }
        return done
    }

    /// Takes a pair apart: the right half becomes a column of its own just after it, and the focus
    /// stays on `tabID`. Nothing is closed.
    func separate(tabID: UUID) {
        unanimated {
            mutate { s in
                guard let at = Self.place(of: tabID, in: s) else { return }
                var ws = s.workspaces[at.workspace]
                var column = ws.columns[at.index]
                guard let right = column.second else { return }
                column.remove(right)
                ws.columns[at.index] = column
                ws.columns.insert(TilingColumn(tabID: right), at: at.index + 1)
                ws.focus = tabID == right ? at.index + 1 : at.index
                s.workspaces[at.workspace] = ws
                s.focus = at.workspace
            }
        }
    }

    private static func place(of tabID: UUID, in strip: TilingStrip) -> (workspace: Int, index: Int)? {
        for (w, workspace) in strip.workspaces.enumerated() {
            if let index = workspace.columns.firstIndex(where: { $0.holds(tabID) }) { return (w, index) }
        }
        return nil
    }

    /// The tabs sharing a column with this one, left to right — just itself when it is alone. The
    /// ⌃Tab ring draws a pair as one card.
    func columnMates(of tabID: UUID) -> [UUID] {
        for workspace in workspaces {
            if let column = workspace.columns.first(where: { $0.holds(tabID) }) { return column.tabIDs }
        }
        return [tabID]
    }

    /// The column a window is in, by the column's own id — what tells two windows that share one
    /// apart from two that merely stand next to each other.
    func columnID(of tabID: UUID) -> UUID? {
        for workspace in workspaces {
            if let column = workspace.columns.first(where: { $0.holds(tabID) }) { return column.id }
        }
        return nil
    }

    /// Where a tab is in the profile on screen.
    func location(of tabID: UUID) -> (workspace: Int, index: Int)? {
        for (w, workspace) in workspaces.enumerated() {
            if let index = workspace.columns.firstIndex(where: { $0.holds(tabID) }) { return (w, index) }
        }
        return nil
    }

    // MARK: Workspaces

    /// The name; for an unnamed row between groups, theirs; else the position.
    func title(at index: Int) -> String {
        if workspaces.indices.contains(index), workspaces[index].name.isEmpty, let blend = workspaces[index].blend {
            let names = blend.parents.compactMap { id in workspaces.first { $0.id == id }?.name }
            return names.count == 2 ? names.joined(separator: " · ") : "≈ " + (names.first ?? "")
        }
        guard workspaces.indices.contains(index), !workspaces[index].name.isEmpty else {
            return String(localized: "Group \(index + 1)")
        }
        return workspaces[index].name
    }

    func rename(workspaceAt index: Int, to name: String) {
        mutate { s in
            guard s.workspaces.indices.contains(index) else { return }
            s.workspaces[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Tab groups

    /// Folds a workspace up to its name in the tab bar, or opens it again. By id, like every verb
    /// the tab bar calls: the row is drawn from a list that `normalize` can reorder between the
    /// click and the call.
    func setCollapsed(_ collapsed: Bool, workspace id: UUID) {
        mutate { s in
            guard let index = s.workspaces.firstIndex(where: { $0.id == id }) else { return }
            s.workspaces[index].collapsed = collapsed ? true : nil
        }
    }

    /// One window to a place in a row: a tab dragged along the tab bar, or into another group.
    /// The window, not the column — a tab is one page, so half of a split dragged away leaves the
    /// other half filling the column on its own, as `moveColumn(tabID:in:toWorkspace:)` does. `index`
    /// is a column position in the destination row *before* the window left, which is what the row
    /// of tabs was showing when it was dropped. The focus follows the window.
    func placeTab(_ tabID: UUID, in profileID: UUID, workspace id: UUID, at index: Int) {
        unanimated {
            mutate(profile: profileID) { s in
                guard let target = s.workspaces.firstIndex(where: { $0.id == id }),
                      let from = s.workspaces.firstIndex(where: { $0.columns.contains { $0.holds(tabID) } }),
                      let at = s.workspaces[from].columns.firstIndex(where: { $0.holds(tabID) }) else { return }
                var index = min(max(0, index), s.workspaces[target].columns.count)
                var column = s.workspaces[from].columns[at]
                if column.remove(tabID) {
                    s.workspaces[from].columns[at] = column
                    column = TilingColumn(tabID: tabID)
                } else {
                    s.workspaces[from].columns.remove(at: at)
                    if from == target, at < index { index -= 1 }
                }
                if from != target {
                    s.workspaces[from].focus = min(s.workspaces[from].focus, max(0, s.workspaces[from].columns.count - 1))
                    askBeforeRemoving(s.workspaces[from], in: profileID)
                }
                s.workspaces[target].columns.insert(column, at: index)
                s.workspaces[target].focus = index
                s.workspaces[target].collapsed = nil
                s.focus = target
            }
        }
    }

    /// Pins the window's column to the front of its workspace, or lets it go back behind the pinned ones.
    func setPinned(_ pinned: Bool, tabID: UUID, in profileID: UUID) {
        unanimated {
            mutate(profile: profileID) { s in
                for w in s.workspaces.indices {
                    guard let at = s.workspaces[w].columns.firstIndex(where: { $0.holds(tabID) }) else { continue }
                    let focused = s.workspaces[w].focusedColumn?.id
                    var column = s.workspaces[w].columns.remove(at: at)
                    column.pinned = pinned ? true : nil
                    let edge = s.workspaces[w].columns.lastIndex(where: \.isPinned).map { $0 + 1 } ?? 0
                    s.workspaces[w].columns.insert(column, at: edge)
                    if let focused, let index = s.workspaces[w].columns.firstIndex(where: { $0.id == focused }) {
                        s.workspaces[w].focus = index
                    }
                    return
                }
            }
        }
    }

    /// A window into a workspace of its own, just after the one it is in — "Add Tab to New Group".
    /// Returns the new workspace's id, so the tab bar can ask for its name straight away.
    @discardableResult
    func placeTabInNewWorkspace(_ tabID: UUID, in profileID: UUID) -> UUID? {
        var created: UUID?
        mutate(profile: profileID) { s in
            guard let from = s.workspaces.firstIndex(where: { $0.columns.contains { $0.holds(tabID) } }) else { return }
            let workspace = TilingWorkspace()
            s.workspaces.insert(workspace, at: from + 1)
            created = workspace.id
            // Survives the `normalize` at the end of this mutation, which would otherwise take an
            // empty unnamed row for the spare one and drop it before the window is in it.
            keepsEmptyOnce = workspace.id
        }
        guard let created else { return nil }
        placeTab(tabID, in: profileID, workspace: created, at: 0)
        return created
    }

    /// A window into the row between two groups, or next to the one it almost belongs to, made or
    /// found; two groups are moved together first if they were not. Returns that row's id.
    @discardableResult
    func placeTab(_ tabID: UUID, in profileID: UUID, blend: TilingBlend) -> UUID? {
        var row: UUID?
        mutate(profile: profileID) { s in
            if let found = s.workspaces.first(where: { $0.blend?.joins(blend) == true }) {
                row = found.id
                return
            }
            guard var a = s.workspaces.firstIndex(where: { $0.id == blend.from }) else { return }
            var made = TilingWorkspace()
            made.blend = blend
            row = made.id
            keepsEmptyOnce = made.id
            guard let to = blend.to else {
                s.workspaces.insert(made, at: a + 1)
                return
            }
            guard var b = s.workspaces.firstIndex(where: { $0.id == to }) else { return }
            // Keep whichever group is higher up where it is and bring the other one to it.
            if b < a { swap(&a, &b) }
            let lower = s.workspaces.remove(at: b)
            s.workspaces.insert(made, at: a + 1)
            s.workspaces.insert(lower, at: a + 2)
        }
        guard let row else { return nil }
        let columns = strip(for: profileID).workspaces.first { $0.id == row }?.columns ?? []
        if !columns.contains(where: { $0.holds(tabID) }) {
            placeTab(tabID, in: profileID, workspace: row, at: columns.count)
        }
        return row
    }

    /// Nil makes the row an ordinary one: a group of its own if it is named, else ungrouped tabs.
    func setBlend(_ blend: TilingBlend?, workspace id: UUID) {
        mutate { s in
            guard let index = s.workspaces.firstIndex(where: { $0.id == id }) else { return }
            s.workspaces[index].blend = blend
        }
    }

    /// A group's colour: its own, or its parents' mixed; nil for ungrouped tabs.
    func groupColor(of id: UUID) -> GroupColor? {
        guard let row = workspaces.first(where: { $0.id == id }), row.isGroup else { return nil }
        func own(_ row: TilingWorkspace) -> GroupColor {
            GroupColor.palette[(row.color ?? Int(row.id.uuid.0)) % GroupColor.palette.count]
        }
        guard let blend = row.blend else { return own(row) }
        guard let from = workspaces.first(where: { $0.id == blend.from }) else { return own(row) }
        guard let to = blend.to.flatMap({ id in workspaces.first { $0.id == id } }) else {
            return own(from).faded(by: blend.weight)
        }
        return own(from).mixed(with: own(to), by: blend.weight)
    }

    func removeProfile(_ id: UUID) {
        strips[id] = nil
        // Its windows were closed one by one on the way here, so its named rows have been queueing
        // up questions about a profile that is being deleted whole. Nobody wants to be asked eight
        // times whether to keep a workspace inside something they just threw away.
        pendingRemovals.removeAll { $0.profileID == id }
    }
}
