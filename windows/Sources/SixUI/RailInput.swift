import CRailInterop
import SixBrowser
import WinSDK

/// Mouse and wheel input, translated into `RailModel` calls. Keys are `RailKeyInput`'s.
extension RailWindow {
    /// What a point in the top bar does, or `nil` for a point that is not on a control. Read by the
    /// click handler and by `WM_SETCURSOR`, which is the whole reason it is a value rather than a
    /// branch inside the click: the cursor has to know what a click *would* do.
    enum ChromeAction {
        case profileMenu
        case back, forward, reload
        case address
        case workspaceUp, workspaceDown
        case workspace(Int)
        case fullWidth
    }

    func chromeAction(x: Int, y: Int) -> ChromeAction? {
        let layout = chromeLayout()
        guard layout.bar.contains(x: x, y: y) else { return nil }
        if layout.profileChip.contains(x: x, y: y) { return .profileMenu }
        if layout.back.contains(x: x, y: y) { return .back }
        if layout.forward.contains(x: x, y: y) { return .forward }
        if layout.reload.contains(x: x, y: y) { return .reload }
        if layout.addressPill.contains(x: x, y: y) { return .address }
        if layout.workspaceUp.contains(x: x, y: y) { return .workspaceUp }
        if layout.workspaceDown.contains(x: x, y: y) { return .workspaceDown }
        if layout.workspacePips.contains(x: x, y: y) {
            // The whole strip, not only the capsule: a 6-pixel-tall target is a target nobody hits,
            // so a pip owns the full height of the bar and the gap to its right.
            for index in 0..<model.workspaceCount where x < Int(pipRect(index, in: layout.workspacePips).right)
                + Int(px(Metric.pipGap)) {
                return .workspace(index)
            }
            return .workspace(max(0, model.workspaceCount - 1))
        }
        if layout.fullWidth.contains(x: x, y: y) { return .fullWidth }
        return nil
    }

    /// Close on the "×", focus on the rest of a card, open on bare background — and the top bar
    /// first, because it is drawn over the rail and has to be hit-tested in the same order.
    func handleClick(x: Int, y: Int) {
        if let action = chromeAction(x: x, y: y) {
            perform(action)
            return
        }
        // Clicking a card is also how you leave the address bar. Without this the hotkeys stop
        // answering until the rail is clicked somewhere that is *not* a column, which reads as the
        // rail hanging rather than as focus being elsewhere.
        if let hwnd { SetFocus(hwnd) }
        for column in model.columns {
            let card = cardRect(for: column.frame)
            guard card.contains(x: x, y: y) else { continue }
            if closeBoxRect(for: card).contains(x: x, y: y) {
                model.closeColumn(column.id)
            } else {
                model.focus(column.id)
            }
            invalidate()
            return
        }
        // The bar is above the rail and a click below the rail's cards is still the rail's, so
        // "empty background" means exactly that: not on the bar, not on a card.
        guard y >= Int(topChromeHeight) else { return }
        model.openColumn()
        invalidate()
    }

    private func perform(_ action: ChromeAction) {
        switch action {
        case .profileMenu:
            showProfileMenu(below: chromeLayout().profileChip)
        case .back:
            focusedWebView?.goBack()
        case .forward:
            focusedWebView?.goForward()
        case .reload:
            focusedWebView?.reload()
        case .address:
            focusAddressBar()
        case .workspaceUp:
            model.focusWorkspace(-1)
        case .workspaceDown:
            model.focusWorkspace(1)
        case .workspace(let index):
            model.focusWorkspace(at: index)
        case .fullWidth:
            model.toggleFullWidth()
        }
        invalidate()
    }

    /// `Alt` is the rail's modifier the way `⌥` is the Mac's `NiriScrollMonitor.modifier`, leaving a
    /// plain wheel to the page. The vertical/horizontal and `Shift` splits match `KeyBindings`' own.
    ///
    /// `WHEEL_DELTA` (120) is one physical notch, and a precise wheel or trackpad reports less than
    /// that per message — hence the accumulator, so the rail does not step twice as fast.
    func handleWheel(delta: Int32, horizontal: Bool) {
        guard SixRailKeyDown(Int32(VK_MENU)) != 0 else { return }
        let movesColumn = SixRailKeyDown(Int32(VK_SHIFT)) != 0

        let notchSize = Int32(WHEEL_DELTA)
        if horizontal {
            wheelRemainderX += delta
            while abs(wheelRemainderX) >= notchSize {
                let notch = wheelRemainderX > 0 ? Int32(1) : Int32(-1)
                wheelRemainderX -= notch * notchSize
                let direction = Int(notch) // tilted right steps right, tilted left steps left
                if movesColumn { model.moveColumn(direction) } else { model.focusColumn(direction) }
            }
        } else {
            wheelRemainderY += delta
            while abs(wheelRemainderY) >= notchSize {
                let notch = wheelRemainderY > 0 ? Int32(1) : Int32(-1)
                wheelRemainderY -= notch * notchSize
                let direction = -Int(notch) // rolled forward (up) steps to the workspace above
                if movesColumn { model.moveColumnToWorkspace(direction) } else { model.focusWorkspace(direction) }
            }
        }
        invalidate()
    }
}

extension RECT {
    func contains(x: Int, y: Int) -> Bool {
        let x = Int32(x), y = Int32(y)
        return x >= left && x < right && y >= top && y < bottom
    }
}
