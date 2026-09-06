@testable internal import SixCore

/// The Mac's key table, reached the same way `RailModel` reaches `NiriLayout`: unchanged, through
/// the module's `@testable` seam, rather than a second table kept in step with it by hand. What
/// crosses into `SixUI` is a small, public vocabulary this front already knows how to act on — not
/// `KeyBindings`' own internal `KeyCode`/`KeyAction`, which stay `internal` to `SixCore` on purpose.
///
/// `KeyContext.window` is always `.main` here, `.field` always `nil`, `.isSwitching` and
/// `.isOverview` always `false` — this front has exactly one window, no text field a key could yield
/// to, no ⌃Tab ring and no overview, so every binding in the table answers as if it were the Mac's
/// one plain browser window. `RailKeyLookup.action(for:modifiers:)` only returns a case this front
/// can actually do something with; the rest of `KeyAction` — the switcher, the overview,
/// translation, highlighting, picture-in-picture — is `nil` here because the subsystem it drives
/// does not exist on this front yet, not because the table does not say what to do.
public enum RailKeyAction: Equatable {
    case focusColumn(Int)
    case moveColumn(Int)
    case focusColumnEdge(last: Bool)
    case focusWorkspace(Int)
    case moveColumnToWorkspace(Int)
    case toggleFullWidth
    case toggleCenterFocus
}

/// The modifiers a Windows hand can be on. `⌘` has no Windows equivalent in this table — nothing in
/// `KeyBindings.all` asks for `.command`, because on the Mac it belongs to the menu bar — so there is
/// no fourth case to map a key onto.
public struct RailKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = RailKeyModifiers(rawValue: 1 << 0)
    public static let alt = RailKeyModifiers(rawValue: 1 << 1)
    public static let shift = RailKeyModifiers(rawValue: 1 << 2)
}

/// A key, already resolved to what it *is* rather than what produced it — the arrows and the named
/// keys by their Win32 virtual-key code, the six letters the table cares about by the physical key a
/// scan code names. Building one of these is `SixUI`'s job, because reading `WM_KEYDOWN` apart is
/// Win32's business the same way `KeyEvents.swift` says reading an `NSEvent` apart is AppKit's.
public enum RailKey: Equatable {
    case tab, returnKey, escape, leftArrow, rightArrow, upArrow, downArrow, home, end
    case letter(Character)
}

public enum RailKeyLookup {
    /// `nil` when nothing in the table matches, or when it matches something this front does not
    /// build yet.
    public static func action(for key: RailKey, modifiers: RailKeyModifiers) -> RailKeyAction? {
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

        let context = KeyContext(window: .main)
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
        case .toggleOverview, .translateSelection, .highlightSelection, .pictureInPicture,
             .stepSwitcher, .landSwitcher, .cancelSwitcher, .leaveOverview:
            return nil
        }
    }
}
