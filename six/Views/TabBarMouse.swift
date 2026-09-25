#if os(macOS)
import AppKit
import SwiftUI

/// A tab's mouse, handled in AppKit: the click that brings it to the front and the drag that moves it.
///
/// SwiftUI's `.draggable` cannot do the second one here. The tab bar is drawn in the band the hidden
/// title bar still owns, and a mouse-down there is asked `mouseDownCanMoveWindow` of the view under
/// it — which, for the hosting view SwiftUI draws everything into, is yes. So a tab pulled sideways
/// moved the whole window, and `.draggable` never heard of it. A view of our own that answers no
/// gets the drag, and starts the session itself; the pasteboard carries the tab's id as plain text,
/// which is what the drop targets in the tab bar were already reading.
///
/// It takes the left button and nothing else. The right button and ⌃-click fall through to the
/// SwiftUI under it, where the tab's menu is, and so does the scroll wheel, which the bar scrolls
/// on; the trailing `passThrough` points are the tab's ×, which is a SwiftUI button.
struct TabDragSource: NSViewRepresentable {
    let tabID: UUID
    let title: String
    let passThrough: CGFloat
    let preview: () -> NSImage?
    let click: (NSEvent.ModifierFlags) -> Void
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.tabID = tabID
        view.toolTip = title
        view.passThrough = passThrough
        view.preview = preview
        view.click = click
        view.hover = hover
    }

    final class SourceView: NSView, NSDraggingSource {
        var tabID = UUID()
        var passThrough: CGFloat = 0
        var preview: () -> NSImage? = { nil }
        var click: (NSEvent.ModifierFlags) -> Void = { _ in }
        var hover: (Bool) -> Void = { _ in }

        private var pressedAt: NSPoint?
        private var dragging = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
                  !event.modifierFlags.contains(.control) else { return nil }
            let local = convert(point, from: superview)
            guard bounds.contains(local), local.x < bounds.width - passThrough else { return nil }
            return self
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }

        override func mouseDown(with event: NSEvent) {
            if TilingLayout.tracesUI { Log.debug(.ui, "tab mouse-down \(tabID), window movable \(window?.isMovable ?? false)") }
            pressedAt = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start = pressedAt else { return }
            let here = event.locationInWindow
            guard hypot(here.x - start.x, here.y - start.y) > 4 else { return }
            dragging = true
            if TilingLayout.tracesUI { Log.debug(.ui, "tab drag begins \(tabID)") }
            let item = NSPasteboardItem()
            item.setString(tabID.uuidString, forType: .string)
            let dragged = NSDraggingItem(pasteboardWriter: item)
            let image = preview() ?? NSImage(size: bounds.size)
            // Where the tab stood, so it lifts off the bar rather than jumping to the pointer.
            dragged.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
            beginDraggingSession(with: [dragged], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressedAt = nil }
            guard !dragging, pressedAt != nil else { return }
            click(event.modifierFlags)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            pressedAt = nil
        }
    }
}

/// The window, held still while the tabs are up, and moved by hand from the tab bar's empty space.
///
/// Answering no to `mouseDownCanMoveWindow` on the tab was not enough: the drag that moved the window
/// is decided above any view of ours, for the whole band the hidden title bar keeps. So the window
/// is not movable at all while the tab bar is on screen (and is again the moment the row is back),
/// and this view, behind the bar's tabs and labels, moves it itself — a drag on bare bar moves the
/// window and a double-click zooms it, which is all the title bar was doing there.
struct WindowMover: NSViewRepresentable {
    func makeNSView(context: Context) -> MoverView { MoverView() }
    func updateNSView(_ view: MoverView, context: Context) {}
    static func dismantleNSView(_ view: MoverView, coordinator: ()) { view.release() }

    final class MoverView: NSView {
        private weak var held: NSWindow?
        private var grabbed: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if held !== window { release() }
            guard let window else { return }
            window.isMovable = false
            held = window
        }

        func release() {
            held?.isMovable = true
            held = nil
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // The title bar's own double-click, as System Settings has it set.
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
                grabbed = nil
                return
            }
            grabbed = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start = grabbed else { return }
            let now = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x + now.x - start.x,
                                          y: window.frame.origin.y + now.y - start.y))
            grabbed = now
        }

        override func mouseUp(with event: NSEvent) { grabbed = nil }
    }
}
#endif
