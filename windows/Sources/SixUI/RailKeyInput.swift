import CRailInterop
import SixBrowser
import WinSDK

/// `WM_KEYDOWN` into `KeyBindings`, by way of `RailKeyLookup` — the Win32 half of what
/// `six/Input/KeyEvents.swift` does with an `NSEvent` on the Mac. Nothing here knows what a binding
/// *does*; that is `RailModel`'s.
extension RailWindow {
    /// `true` means the key was ours and the caller should swallow it. Reporting `false` matters
    /// most for `WM_SYSKEYDOWN`: every binding here is `⌥`-something, held Alt is what turns any key
    /// into a system key on Windows, and swallowing those unconditionally would have taken `⌥F4`
    /// and `⌥Space` with it.
    @discardableResult
    func handleKeyDown(virtualKey: Int32, lParam: LPARAM) -> Bool {
        guard let key = Self.railKey(virtualKey: virtualKey, scanCode: SixRailScanCode(lParam)) else { return false }

        var modifiers: RailKeyModifiers = []
        if SixRailKeyDown(Int32(VK_CONTROL)) != 0 { modifiers.insert(.control) }
        if SixRailKeyDown(Int32(VK_MENU)) != 0 { modifiers.insert(.alt) }
        if SixRailKeyDown(Int32(VK_SHIFT)) != 0 { modifiers.insert(.shift) }

        guard let action = RailKeyLookup.action(for: key, modifiers: modifiers) else { return false }
        perform(action)
        invalidate()
        return true
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

    /// Letters go by scan code, not virtual-key code — the physical key, which no layout remaps —
    /// for the reason CLAUDE.md learned on the Mac: "`⌥W` reports «ц» on the Russian layout."
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
