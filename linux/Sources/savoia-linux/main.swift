import Adwaita
import SavoiaUI

/// Savoia on Linux.
///
/// Nothing touches the model here. `BrowserModel.shared` is lazy and fills itself, so it comes into
/// being at the first render — after `g_application_run` has GTK up. Doing it from this `init`
/// instead builds a `WebKitNetworkSession`, and so a GObject, before the toolkit exists.
@main
struct SavoiaApp: App {
    let app = AdwaitaApp(id: "org.deffun.savoia")

    var scene: Scene {
        Window(id: "main") { _ in
            BrowserContent()
        }
        .defaultSize(width: 1400, height: 900)
        .title("Savoia")
    }
}
