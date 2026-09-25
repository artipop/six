@testable internal import SixCore

/// The Mac's key table, unchanged, through the same `@testable` seam `StripModel` uses for
/// `TilingLayout` — rather than a second table kept in step by hand. What crosses into `SixUI` is a
/// small public vocabulary; `KeyBindings`' own `KeyCode`/`KeyAction` stay internal on purpose.
///
/// The context is the Mac's one plain browser window, with the overview flag the window hands in:
/// this front has a single window, no text field a key could yield to and no ⌃Tab ring. Actions
/// whose subsystem does not exist here yet come back `nil` — the table still says what to do, there
/// is just nothing to do it to.
public enum StripKeyAction: Equatable {
    case focusColumn(Int)
    case moveColumn(Int)
    case focusColumnEdge(last: Bool)
    case focusWorkspace(Int)
    case moveColumnToWorkspace(Int)
    case toggleFullWidth
    case toggleCenterFocus
    case toggleOverview
    case leaveOverview
}

/// No `⌘` case: nothing in `KeyBindings.all` asks for `.command`, because on the Mac those are menu
/// items rather than table rows.
public struct StripKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = StripKeyModifiers(rawValue: 1 << 0)
    public static let alt = StripKeyModifiers(rawValue: 1 << 1)
    public static let shift = StripKeyModifiers(rawValue: 1 << 2)
}

/// A key already resolved to what it *is* rather than what produced it. Building one is `SixUI`'s
/// job: taking `WM_KEYDOWN` apart is Win32's business, the way `KeyEvents.swift` says taking an
/// `NSEvent` apart is AppKit's.
public enum StripKey: Equatable {
    case tab, returnKey, escape, leftArrow, rightArrow, upArrow, downArrow, home, end
    case letter(Character)
}

public enum StripKeyLookup {
    /// `nil` when nothing in the table matches, or when it matches something this front does not
    /// build yet.
    public static func action(for key: StripKey, modifiers: StripKeyModifiers,
                              isOverview: Bool = false) -> StripKeyAction? {
        let code: KeyCode
        var character: Character?
        switch key {
        case .tab: code = .tab
        case .returnKey: code = .returnKey
        case .escape: code = .escape
        case .leftArrow: code = .leftArrow
        case .rightArrow: code = .rightArrow
        case .upArrow: code = .upArrow
        case .downArrow: code = .downArrow
        case .home: code = .home
        case .end: code = .end
        case .letter(let typed):
            character = typed
            switch Character(typed.lowercased()) {
            case "c": code = .c
            case "h": code = .h
            case "o": code = .o
            case "p": code = .p
            case "t": code = .t
            case "w": code = .w
            default: return nil
            }
        }

        var held: KeyModifiers = []
        if modifiers.contains(.control) { held.insert(.control) }
        if modifiers.contains(.alt) { held.insert(.option) }
        if modifiers.contains(.shift) { held.insert(.shift) }

        let context = KeyContext(window: .main, isOverview: isOverview)
        guard let binding = KeyBindings.all.first(where: {
            $0.matches(code: code.rawValue, character: character, held: held, in: context)
        }) else { return nil }

        switch binding.action {
        case .focusColumn(let delta): return .focusColumn(delta)
        case .moveColumn(let delta): return .moveColumn(delta)
        case .focusColumnEdge(let last): return .focusColumnEdge(last: last)
        case .focusWorkspace(let delta): return .focusWorkspace(delta)
        case .moveColumnToWorkspace(let delta): return .moveColumnToWorkspace(delta)
        case .toggleFullWidth: return .toggleFullWidth
        case .toggleCenterFocus: return .toggleCenterFocus
        case .toggleOverview: return .toggleOverview
        // The row is scoped to the row, not to the overview, and the Mac's handler is what says
        // "only while it is open". Here that is this line — and it matters more than it looks: a
        // bare `Esc` answered outside the overview would be taken from every page and every dialog
        // in it.
        case .leaveOverview: return isOverview ? .leaveOverview : nil
        // ⌥S splits a column into two panes and ⌃⇧C puts the address on the clipboard; the row
        // here draws one window per column and owns no clipboard code, so both are table rows with
        // nothing yet to act on. `copyAddressChord` already spells itself ⌃⇧C off Apple, so the
        // binding is waiting on this front rather than the other way round.
        case .toggleSplit, .copyAddress,
             .translateSelection, .highlightSelection, .pictureInPicture,
             .stepSwitcher, .landSwitcher, .cancelSwitcher:
            return nil
        }
    }
}
