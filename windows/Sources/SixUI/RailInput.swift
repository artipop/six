import CRailInterop
import SixBrowser
import WinSDK

/// Mouse and wheel input, translated into `RailModel` calls. Keyboard input — the real hotkey
/// table, `KeyBindings` — is a separate piece of work; see docs/windows.md.
extension RailWindow {
    /// A click: on a column's "×" it closes; on the rest of a column it focuses; on the bare
    /// background — past the last column, or before the first — it opens a new one. The same three
    /// answers a click gives on every other front, just without a page underneath to also receive it.
    func handleClick(x: Int, y: Int) {
        for column in model.columns {
            let card = RECT(
                left: Int32(column.frame.minX), top: Int32(column.frame.minY),
                right: Int32(column.frame.maxX), bottom: Int32(column.frame.maxY)
            )
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

    /// `Alt` is the rail's modifier here the way `⌥` is the Mac's `NiriScrollMonitor.modifier` — kept
    /// out of the way of whatever the browser eventually binds to a plain wheel over a page. Vertical
    /// steps a workspace, horizontal steps a column — the same split `KeyBindings` draws between
    /// `⌥↑/↓` and `⌥←/→` — and `Shift` turns either into the "move the column, not just the focus"
    /// variant, matching `⌥⇧` in the same table.
    ///
    /// `WHEEL_DELTA` (120) is one physical notch; a precise wheel or a trackpad can report less than
    /// that per message, so what arrives is accumulated and only spent a whole notch at a time.
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
