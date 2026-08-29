import Adwaita
import SixBrowser
import SixUI

/// six on Linux.
@main
struct SixApp: App {
    let app = AdwaitaApp(id: "org.deffun.six")

    /// The strip is filled *before* the first render, not from `onAppear`.
    ///
    /// Populating it from inside the view's own appear callback changes what the model returns while
    /// adwaita is still walking the tree it computed a moment earlier — the storage bookkeeping goes
    /// out of step with the model, and the next update dereferences something that has moved. The
    /// window came up, drew once, and died in `Button.update`, which is not where the mistake was.
    init() {
        MainActor.assumeIsolated { BrowserModel.shared.start() }
    }

    var scene: Scene {
        Window(id: "main") { _ in
            BrowserContent()
        }
        .defaultSize(width: 1400, height: 900)
        .title("six")
    }
}
