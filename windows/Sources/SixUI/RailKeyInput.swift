import CRailInterop
import SixBrowser
import WinSDK

/// `WM_KEYDOWN` into `KeyBindings`, by way of `RailKeyLookup` — the same table `six/Input/KeyBindings.swift`
/// is, read the way `KeyEvents.swift` reads an `NSEvent` for the Mac: this file's whole job is turning
/// a Win32 message into the key, the modifiers and the context the table asks for, and it knows
/// nothing about what any binding *does* — that is `RailModel`'s.
extension RailWindow {
    func handleKeyDown(virtualKey: Int32, lParam: LPARAM) {
        guard let key = Self.railKey(virtualKey: virtualKey, scanCode: SixRailScanCode(lParam)) else { return }

        var modifiers: RailKeyModifiers = []
        if SixRailKeyDown(Int32(VK_CONTROL)) != 0 { modifiers.insert(.control) }
        if SixRailKeyDown(Int32(VK_MENU)) != 0 { modifiers.insert(.alt) }
        if SixRailKeyDown(Int32(VK_SHIFT)) != 0 { modifiers.insert(.shift) }

        guard let action = RailKeyLookup.action(for: key, modifiers: modifiers) else { return }
        perform(action)
        invalidate()
    }

    private func perform(_ action: RailKeyAction) {
        switch action {
        case .focusColumn(let delta): model.focusColumn(delta)
        case .moveColumn(let delta): model.moveColumn(delta)
        case .focusColumnEdge(let last): model.focusColumnEdge(last: last)
        case .focusWorkspace(let delta): model.focusWorkspace(delta)
        case .moveColumnToWorkspace(let delta): model.moveColumnToWorkspace(delta)
        case .toggleFullWidth: model.toggleFullWidth()
        case .toggleCenterFocus: model.toggleCenterFocus()
        }
    }

    /// The arrows and the named keys go by virtual-key code, which has no layout ambiguity worth
    /// caring about here. The six letters the table binds go by scan code instead — the physical key,
    /// unlike the virtual-key code which many layouts remap wholesale — for the reason CLAUDE.md
    /// already learned the hard way on the Mac: "`⌥W` reports «ц» on the Russian layout."
    private static func railKey(virtualKey: Int32, scanCode: Int32) -> RailKey? {
        switch virtualKey {
        case VK_TAB: return .tab
        case VK_RETURN: return .returnKey
        case VK_ESCAPE: return .escape
        case VK_LEFT: return .leftArrow
        case VK_RIGHT: return .rightArrow
        case VK_UP: return .upArrow
        case VK_DOWN: return .downArrow
        case VK_HOME: return .home
        case VK_END: return .end
        default: break
        }
        // Scan Code Set 1, the same on every keyboard layout.
        switch scanCode {
        case 0x2E: return .letter("c")
        case 0x23: return .letter("h")
        case 0x18: return .letter("o")
        case 0x19: return .letter("p")
        case 0x14: return .letter("t")
        case 0x11: return .letter("w")
        default: return nil
        }
    }
}
