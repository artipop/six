import WebKit
#if os(macOS)
import AppKit
#endif

/// Everything Savoia runs inside a page runs here: a `WKContentWorld` of its own. The DOM is shared, the
/// JavaScript is not — the page cannot redefine `querySelectorAll` or the `innerText` getter to feed
/// the extractor (and the model behind it) text a person never sees, and it cannot see or touch our
/// globals. This is the reader-mode arrangement of Firefox and Safari: the browser's script reads the
/// page from a privileged context, never as a guest of the page's own scripts. The one deliberate
/// exception is `evaluate_javascript`, which is *for* the page's world.
extension WKContentWorld {
    static let savoia = WKContentWorld.world(name: "savoia")
}

extension WKWebView {
    /// A function body run in Savoia's world.
    func savoia(_ functionBody: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await callAsyncJavaScript(functionBody, arguments: arguments, in: nil, contentWorld: .savoia)
    }

    /// A function body run in the main frame; the page's own world unless another is named.
    func callJavaScript(_ functionBody: String, arguments: [String: Any] = [:],
                        contentWorld: WKContentWorld? = nil) async throws -> Any? {
        try await callAsyncJavaScript(functionBody, arguments: arguments, in: nil, contentWorld: contentWorld ?? .page)
    }
}

#if os(macOS)
extension BrowserTab {
    /// A function body run in the page with no user gesture attached. `callAsyncJavaScript` is one to
    /// WebKit: the page may then open windows, play sound and read the clipboard as if a person had
    /// clicked (docs/page-scripts.md). SPI; without it the ordinary call is all there is.
    func callWithoutGesture(_ functionBody: String, arguments: [String: Any] = [:],
                            in world: WKContentWorld? = nil, frame: WKFrameInfo? = nil) async throws -> Any? {
        let world = world ?? .savoia
        let view = page
        guard view.canCallWithoutGesture
        else { return try await view.callJavaScript(functionBody, arguments: arguments, contentWorld: world) }
        return try await view.callWithoutGesture(functionBody, arguments: arguments, in: world, frame: frame)
    }

    /// A mouse click at a point of the page's viewport, in CSS pixels, as an event handed to the web
    /// view: trusted, and a user gesture. False when the page's view is in no window.
    @discardableResult
    func click(atViewport point: CGPoint) -> Bool {
        livePage?.click(atViewport: point) ?? false
    }
}

extension WKWebView {
    var canCallWithoutGesture: Bool {
        responds(to: #selector(GesturelessCalls.call(_:arguments:in:in:withUserGesture:completionHandler:)))
    }

    func callWithoutGesture(_ functionBody: String, arguments: [String: Any] = [:],
                            in world: WKContentWorld, frame: WKFrameInfo? = nil) async throws -> Any? {
        let answer: UncheckedBox<Result<Any?, any Error>> = await withCheckedContinuation { continuation in
            unsafeBitCast(self, to: GesturelessCalls.self).call(
                functionBody, arguments: arguments, in: frame, in: world, withUserGesture: false
            ) { value, error in
                continuation.resume(returning: UncheckedBox(value: error.map { .failure($0) } ?? .success(value)))
            }
        }
        return try answer.value.get()
    }

    /// One mouse event at a point of the viewport, in CSS pixels. False when the view is in no window.
    @discardableResult
    func mouse(_ type: NSEvent.EventType, atViewport point: CGPoint) -> Bool {
        guard let window else { return false }
        // A moved event reaches the page only in the key window; a dragged one always does, and the page reads no button from it.
        let type = type == .mouseMoved ? .leftMouseDragged : type
        guard let event = NSEvent.mouseEvent(
            with: type, location: inWindow(viewport: point), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
        switch type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseUp: mouseUp(with: event)
        default: mouseDragged(with: event)
        }
        return true
    }

    @discardableResult
    func click(atViewport point: CGPoint) -> Bool {
        mouse(.leftMouseDown, atViewport: point) && mouse(.leftMouseUp, atViewport: point)
    }

    /// The destination's half of a drag the page began, called as a dragging session calls it: a
    /// session begun from an event nobody's hand made never does. False when the page refused the drop.
    func drop(atViewport point: CGPoint) async -> Bool {
        guard let window else { return false }
        let location = inWindow(viewport: point)
        let drop = PageDrop(window: window, pasteboard: NSPasteboard(name: .drag), location: location)
        _ = draggingEntered(drop)
        var operation: NSDragOperation = []
        // The page's answer to `dragover` comes back from its process a moment later.
        for _ in 0..<6 where operation.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
            operation = draggingUpdated(drop)
        }
        let taken = !operation.isEmpty && prepareForDragOperation(drop) && performDragOperation(drop)
        if !taken { draggingExited(drop) }
        try? await Task.sleep(for: .milliseconds(100))
        if responds(to: #selector(DragSource.dragged(_:endedAt:operation:))) {
            unsafeBitCast(self, to: DragSource.self).dragged(NSImage(), endedAt: window.convertPoint(toScreen: location),
                                                             operation: taken ? operation : [])
        }
        return taken
    }

    private func inWindow(viewport point: CGPoint) -> CGPoint {
        convert(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y), to: nil)
    }
}

/// What a dragging session tells its destination.
private final class PageDrop: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move, .link, .generic]
    var draggedImageLocation: NSPoint { draggingLocation }
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 0
    var draggingFormation = NSDraggingFormation.none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight = NSSpringLoadingHighlight.none

    init(window: NSWindow, pasteboard: NSPasteboard, location: NSPoint) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingLocation = location
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// AppKit's own name for it, which Swift marks unavailable.
@objc private protocol DragSource {
    @objc(draggedImage:endedAt:operation:)
    func dragged(_ image: NSImage, endedAt point: NSPoint, operation: NSDragOperation)
}

@objc private protocol GesturelessCalls {
    @objc(_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:)
    func call(_ functionBody: String, arguments: [String: Any]?, in frame: WKFrameInfo?, in world: WKContentWorld,
              withUserGesture: Bool, completionHandler: (@MainActor (Any?, (any Error)?) -> Void)?)
}
#endif
