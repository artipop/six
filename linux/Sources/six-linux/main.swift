import Adwaita
import SixUI

/// six on Linux.
@main
struct SixApp: App {
    let app = AdwaitaApp(id: "org.deffun.six")

    var scene: Scene {
        Window(id: "main") { _ in
            BrowserContent()
        }
        .defaultSize(width: 1400, height: 900)
        .title("six")
    }
}
