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
        guard let key = Self.railKey(virtualKey: virtualKey,
                                     scanCode: Self.scanCode(virtualKey: virtualKey, lParam: lParam))
        else { return false }

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

    /// The physical key behind a message, and a fallback for the case where there is none.
    ///
    /// `WM_KEYDOWN`'s `lParam` carries the scan code, which is the whole point of matching on it —
    /// the physical key, the same on every layout. Synthetic input often carries a zero there
    /// (`SendInput` fills `wScan` only if its caller did, and `SendKeys` does not), so a key with no
    /// scan code is asked of the current layout instead. Nothing is lost: a real keypress never
    /// reaches the fallback, and a script-driven one is on whatever layout is loaded anyway.
    static func scanCode(virtualKey: Int32, lParam: LPARAM) -> Int32 {
        let fromMessage = SixRailScanCode(lParam)
        guard fromMessage == 0 else { return fromMessage }
        return Int32(MapVirtualKeyW(UINT(virtualKey), UINT(MAPVK_VK_TO_VSC)))
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

/// The keys that are menu items on the Mac rather than rows in `KeyBindings` — ⌘L, ⌘T, ⌘W, ⌘R,
/// ⌘D, ⌘[ and ⌘] — with `Ctrl` in `⌘`'s place, which is where a Windows keyboard keeps them.
///
/// They are matched by **scan code**, like the letter bindings in `railKey` above and for the same
/// reason CLAUDE.md gives: a letter read from the layout is a shortcut only Latin layouts have.
extension RailWindow {
    /// `true` means the key was ours. Checked before `KeyBindings`, which answers no `Ctrl`-only
    /// chord, so the two cannot collide.
    func handleChromeKey(virtualKey: Int32, lParam: LPARAM) -> Bool {
        if virtualKey == VK_F5 {
            focusedWebView?.reload()
            invalidate()
            return true
        }
        guard SixRailKeyDown(Int32(VK_CONTROL)) != 0, SixRailKeyDown(Int32(VK_MENU)) == 0 else { return false }
        switch Self.scanCode(virtualKey: virtualKey, lParam: lParam) {
        case 0x26: focusAddressBar()                                  // L
        case 0x14: model.openColumn()                                 // T
        case 0x11: model.closeColumn()                                // W
        case 0x13: focusedWebView?.reload()                           // R
        case 0x20: model.toggleFocusedPageBookmark()                  // D — the Mac's ⌘D
        case 0x1A: focusedWebView?.goBack()                           // [
        case 0x1B: focusedWebView?.goForward()                        // ]
        default: return false
        }
        invalidate()
        return true
    }
}
