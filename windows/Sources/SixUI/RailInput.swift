import CRailInterop
import SixBrowser
import WinSDK

/// Mouse and wheel input, translated into `RailModel` calls. Keys are `RailKeyInput`'s.
extension RailWindow {
    /// Close on the "×", focus on the rest of a card, open on bare background.
    func handleClick(x: Int, y: Int) {
        // Clicking a card is also how you leave the address bar. Without this the hotkeys stop
        // answering until the rail is clicked somewhere that is *not* a column, which reads as the
        // rail hanging rather than as focus being elsewhere.
        if let hwnd { SetFocus(hwnd) }
        for column in model.columns {
            let card = Self.cardRect(for: column.frame)
            guard card.contains(x: x, y: y) else { continue }
            if Self.closeBoxRect(for: card).contains(x: x, y: y) {
                model.closeColumn(column.id)
            } else {
                model.focus(column.id)
            }
            invalidate()
            return
        }
        model.openColumn()
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

private extension RECT {
    func contains(x: Int, y: Int) -> Bool {
        let x = Int32(x), y = Int32(y)
        return x >= left && x < right && y >= top && y < bottom
    }
}
