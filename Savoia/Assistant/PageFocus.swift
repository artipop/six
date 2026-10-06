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
/// can use directly. Page zoom would put them out (Savoia does not offer page zoom today).
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
    /// Can Savoia write here? A `<textarea>`, an `<input>`, a `contenteditable` — and nothing else.
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

/// Every window's `PageFocus`, as of the last time it was asked for.
///
/// Asked, not pushed: `refresh` reads the page when ⌘E is pressed. A watcher in every page was a
/// script running on sites the assistant was never called on (docs/page-scripts.md).
///
/// **Password fields are not read at all** — no content, no caret. That is a rule of the script
/// rather than of this type, because the cheapest place to drop a secret is before it is sent.
@MainActor
@Observable
final class PageFocusStore {
    private var focuses: [UUID: PageFocus] = [:]

    /// The assistant switch (`ConfigurationStore.isAIEnabled`): off, no page is read.
    var isEnabled: Bool = true {
        didSet { if !isEnabled { focuses.removeAll() } }
    }

    subscript(windowID: UUID) -> PageFocus {
        focuses[windowID] ?? PageFocus()
    }

    func forget(_ windowID: UUID) {
        focuses[windowID] = nil
    }

    /// A navigation takes the selection with it.
    func noteNavigation(_ windowID: UUID) {
        guard focuses[windowID] != nil else { return }
        focuses[windowID] = PageFocus()
    }

    func refresh(_ tab: BrowserTab?) async {
        guard isEnabled, let tab, !tab.isDocument, let page = tab.livePage else { return }
        guard let body = try? await page.savoia(PageFocusScript.read) else { return }
        receive(body, from: tab.id)
    }

    private func receive(_ body: Any, from windowID: UUID) {
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
        // `SAVOIA_UI_DEBUG=1` prints a line per key press and who took it; a selection is the same kind
        // of fact, and the only way to watch this one from a terminal — the bar it draws is AppKit
        // over a web view, which no screenshot on this machine can catch (AGENTS.md).
        if ProcessInfo.processInfo.environment["SAVOIA_UI_DEBUG"] != nil {
            let where_ = focus.rect.integral
            Log.debug(.ui, "focus \(focus.kind.rawValue) editable=\(focus.isEditable) at \(Int(where_.minX)),\(Int(where_.minY)) label=\"\(focus.label)\" text=\"\(focus.subject.prefix(40))\"")
        }
    }
}
#endif
