#if os(macOS)
import AppKit
import SwiftUI

/// A tab's click and drag, in AppKit: in the title bar's band a SwiftUI drag moves the window.
/// Only the left button is taken; the rest, and the × (`passThrough`), fall through to SwiftUI.
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

/// While the tab bar is up the window is not movable (or tabs could not be dragged), and the
/// bar's empty space moves it instead.
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
