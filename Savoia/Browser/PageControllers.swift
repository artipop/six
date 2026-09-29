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
///
/// **User scripts are kept by name.** `WKUserContentController` can only be emptied, never asked to
/// drop one script, so two subscribers that both call `removeAllUserScripts()` take turns deleting
/// each other's work — which is exactly what the blocker's cosmetic rules and the DevTools capture
/// hooks would do. Each says what it wants under a name of its own instead, and the list is rebuilt
/// from all of them in registration order.
@MainActor
final class PageControllers {
    private var controllers: [UUID: WKUserContentController] = [:]
    private var configurators: [(UUID, WKUserContentController) -> Void] = []
    /// Per window, per name, in the order the names were first seen — which is the order the
    /// scripts run in, and the reason the blocker registers before anything that reads the page.
    private var userScripts: [UUID: [(name: String, scripts: [WKUserScript])]] = [:]

    /// Called for every window's controller — the ones open now, and every one built later.
    func onController(_ body: @escaping (UUID, WKUserContentController) -> Void) {
        configurators.append(body)
        for (windowID, controller) in controllers { body(windowID, controller) }
    }

    func controller(for windowID: UUID) -> WKUserContentController {
        if let existing = controllers[windowID] { return existing }
        let controller = WKUserContentController()
        controllers[windowID] = controller
        for entry in userScripts[windowID] ?? [] {
            for script in entry.scripts { controller.addUserScript(script) }
        }
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

    /// What one subscriber wants to run in this window's pages, replacing whatever it asked for
    /// last time and leaving everyone else's alone. An empty array removes its scripts.
    ///
    /// User scripts are read when a page starts loading, so this counts for the *next* load — which
    /// is why the blocker calls it from the navigation decider, before the request leaves.
    func setUserScripts(_ scripts: [WKUserScript], named name: String, for windowID: UUID) {
        var entries = userScripts[windowID] ?? []
        let existing = entries.firstIndex(where: { $0.name == name })
        // Asking for nothing when nothing was asked for is the common case on a page with no
        // cosmetic rules, and it must not cost every other subscriber a rebuild.
        if scripts.isEmpty, existing.map({ entries[$0].scripts.isEmpty }) ?? true { return }
        if let index = existing {
            entries[index].scripts = scripts
        } else {
            entries.append((name, scripts))
        }
        userScripts[windowID] = entries
        guard let controller = controllers[windowID] else { return }
        controller.removeAllUserScripts()
        for entry in entries {
            for script in entry.scripts { controller.addUserScript(script) }
        }
    }

    func forget(_ windowID: UUID) {
        controllers[windowID] = nil
        userScripts[windowID] = nil
    }
}
