#if canImport(WebKit)
import Foundation
import Observation
import WebKit

/// What the person is pointing at inside a page: a selection, or a caret in a field.
///
/// This is the whole premise of the assistant's new shape. The old one had one entry point — a line
/// at the bottom asking about "this page" — and a page is the coarsest thing a browser knows. What a
/// person actually wants explained is the paragraph they just dragged over; what they want written
/// is the comment box their cursor is sitting in. Both are facts the page holds and Swift never saw,
/// so this is the part that had to be built before anything else could be.
///
/// Coordinates are CSS pixels against the viewport, which is what an overlay hung on the web view
/// can use directly. Page zoom would put them out (six does not offer page zoom today).
struct PageFocus: Equatable, Sendable {
    enum Kind: String, Sendable { case none, selection, caret }

    var kind: Kind = .none
    /// The selected text, or — for a caret — everything in the field.
    var text = ""
    /// The field's full content, when the focus is inside one. Empty for a selection in prose.
    var field = ""
    /// Where the selection sits inside `field`, in UTF-16 offsets, as the page counts them.
    var start = 0
    var end = 0
    /// Can six write here? A `<textarea>`, an `<input>`, a `contenteditable` — and nothing else.
    var isEditable = false
    var isMultiline = false
    /// The field's accessible name: a label, an `aria-label`, a placeholder. Context for the model —
    /// "Write a reply" means something different under "Comment" than under "Search".
    var label = ""
    /// Viewport coordinates, for hanging a bar on.
    var rect = CGRect.zero

    var isEmpty: Bool { kind == .none }
    /// The text an action works on: the selection where there is one, the field otherwise.
    var subject: String { kind == .caret ? field : text }
}

/// Every window's `PageFocus`, kept current by the page itself.
///
/// Pushed, not polled: a script in six's own world (`PageScripts.swift`) posts on `selectionchange`
/// and on focus moving in or out of a field, and this is what receives it. Polling would have to run
/// while nothing is happening, which is most of the time.
///
/// **Password fields are not read at all** — no content, no caret, no message. That is a rule of the
/// script rather than of this type, because the cheapest place to drop a secret is before it is sent.
@MainActor
@Observable
final class PageFocusStore {
    private var focuses: [UUID: PageFocus] = [:]
    @ObservationIgnored private var handlers: [UUID: PageFocusMessageHandler] = [:]
    @ObservationIgnored private let controllers: PageControllers

    /// The assistant switch (`SettingsStore.isAIEnabled`), enforced here rather than in the views:
    /// with it off there is no watcher in the page at all, which is the difference between a
    /// feature that is hidden and one that is not running. Scripts are read when a page starts
    /// loading, so switching it back on reaches the pages loaded after it — the ones already open
    /// stop being watched at once either way, because the handler goes with the switch.
    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            focuses.removeAll()
            controllers.forEach { windowID, controller in install(in: controller, for: windowID) }
        }
    }

    init(controllers: PageControllers) {
        self.controllers = controllers
        controllers.onController { [weak self] windowID, controller in
            self?.install(in: controller, for: windowID)
        }
    }

    subscript(windowID: UUID) -> PageFocus {
        focuses[windowID] ?? PageFocus()
    }

    func forget(_ windowID: UUID) {
        focuses[windowID] = nil
        handlers[windowID] = nil
    }

    /// A navigation takes the selection with it, and the page will not say so — the script that
    /// would have is gone with the document it lived in.
    func noteNavigation(_ windowID: UUID) {
        guard focuses[windowID] != nil else { return }
        focuses[windowID] = PageFocus()
    }

    private static let scriptName = "assistant-focus"

    private func install(in controller: WKUserContentController, for windowID: UUID) {
        controller.removeScriptMessageHandler(forName: PageFocusScript.handlerName, contentWorld: .six)
        handlers[windowID] = nil
        guard isEnabled else {
            controllers.setUserScripts([], named: Self.scriptName, for: windowID)
            return
        }
        let handler = PageFocusMessageHandler(windowID: windowID, store: self)
        handlers[windowID] = handler
        controller.add(handler, contentWorld: .six, name: PageFocusScript.handlerName)
        // Through the registry, never `controller.addUserScript` directly: the blocker's cosmetic
        // rules are user scripts too, and `removeAllUserScripts()` cannot tell whose is whose.
        controllers.setUserScripts([WKUserScript(
            source: PageFocusScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .six)], named: Self.scriptName, for: windowID)
    }

    fileprivate func receive(_ body: Any, from windowID: UUID) {
        guard isEnabled, let message = body as? [String: Any] else { return }
        var focus = PageFocus()
        focus.kind = PageFocus.Kind(rawValue: message["kind"] as? String ?? "") ?? .none
        focus.text = message["text"] as? String ?? ""
        focus.field = message["field"] as? String ?? ""
        focus.start = message["start"] as? Int ?? 0
        focus.end = message["end"] as? Int ?? 0
        focus.isEditable = message["editable"] as? Bool ?? false
        focus.isMultiline = message["multiline"] as? Bool ?? false
        focus.label = message["label"] as? String ?? ""
        if let rect = message["rect"] as? [Double], rect.count == 4 {
            focus.rect = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        }
        if focus.kind == .selection, focus.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focus = PageFocus()
        }
        guard focuses[windowID] != focus else { return }
        focuses[windowID] = focus
        // `SIX_UI_DEBUG=1` prints a line per key press and who took it; a selection is the same kind
        // of fact, and the only way to watch this one from a terminal — the bar it draws is AppKit
        // over a web view, which no screenshot on this machine can catch (CLAUDE.md).
        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] != nil {
            let where_ = focus.rect.integral
            Log.debug(.ui, "focus \(focus.kind.rawValue) editable=\(focus.isEditable) at \(Int(where_.minX)),\(Int(where_.minY)) label=\"\(focus.label)\" text=\"\(focus.subject.prefix(40))\"")
        }
    }
}

/// One per window, because a message has to say which window it came from and the page cannot be
/// trusted to say so itself.
private final class PageFocusMessageHandler: NSObject, WKScriptMessageHandler {
    let windowID: UUID
    weak var store: PageFocusStore?

    init(windowID: UUID, store: PageFocusStore) {
        self.windowID = windowID
        self.store = store
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let windowID = windowID
        Task { @MainActor [weak store] in
            store?.receive(body, from: windowID)
        }
    }
}
#endif
