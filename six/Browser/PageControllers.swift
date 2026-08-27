import Foundation
import WebKit

/// The `WKUserContentController` of every open window, and the one place that decides what goes into
/// it.
///
/// A window has a controller of its own rather than sharing the profile's — that is what makes the
/// blocker's per-site allowlist a reload instead of a recompile ([blocking.md](../../docs/blocking.md)).
/// Once more than one thing has a say in what a page runs (rules from the blocker, hooks from
/// devtools), the controller stops belonging to either of them, so it lives here and they subscribe.
///
/// A controller outlives its page: a window whose page was discarded and built again is handed the
/// same one, so nothing has to be attached twice.
@MainActor
final class PageControllers {
    private var controllers: [UUID: WKUserContentController] = [:]
    private var configurators: [(UUID, WKUserContentController) -> Void] = []

    /// Called for every window's controller — the ones open now, and every one built later.
    func onController(_ body: @escaping (UUID, WKUserContentController) -> Void) {
        configurators.append(body)
        for (windowID, controller) in controllers { body(windowID, controller) }
    }

    func controller(for windowID: UUID) -> WKUserContentController {
        if let existing = controllers[windowID] { return existing }
        let controller = WKUserContentController()
        controllers[windowID] = controller
        for configure in configurators { configure(windowID, controller) }
        return controller
    }

    /// The controller of a window that has one — for changing what is already attached, without
    /// bringing a controller into being for a window that never asked.
    func existing(_ windowID: UUID) -> WKUserContentController? {
        controllers[windowID]
    }

    func forEach(_ body: (UUID, WKUserContentController) -> Void) {
        for (windowID, controller) in controllers { body(windowID, controller) }
    }

    func forget(_ windowID: UUID) {
        controllers[windowID] = nil
    }
}
