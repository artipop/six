import Foundation
import SixGtk
import SixUI

@testable import SixCore

/// six on Linux. A skeleton: one window, the niri strip, columns that are real pages, an address bar
/// and history in the same SQLite file the Mac writes.
///
/// `SIX_URL` opens somewhere other than the start page — space-separated for more than one, which is
/// how the strip gets more than one column without a keyboard in a headless container.
@MainActor
func run() -> Int32 {
    let application = Application(id: "org.deffun.six")

    // Held past `onActivate` — GTK calls back into a scene that has to still exist.
    var window: BrowserWindow?

    application.onActivate {
        let layout = NiriLayout()
        // `SIX_WIDTH` picks a column preset (0 = half, 3 = full), which is the setting the Mac cycles
        // with ⌥R. Here it is the only way to see more than one column without a keyboard.
        if let width = ProcessInfo.processInfo.environment["SIX_WIDTH"].flatMap(Int.init) {
            layout.preferredWidthIndex = width
        }

        // The database is the same file, in the same format, that the Mac build writes; only the
        // folder differs, and only inside `AppSupport.root`.
        var history: HistoryStore?
        do {
            let database = try AppDatabase.open()
            history = HistoryStore(database: database)
            FileHandle.standardError.write(Data("[six] database at \(AppDatabase.url.path)\n".utf8))
        } catch {
            // A browser without history is still a browser; one that refuses to start is not.
            FileHandle.standardError.write(Data("[six] database unavailable: \(error)\n".utf8))
        }

        let profiles = AppSupport.folder("Profiles/Default")
        try? FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let session = NetworkSession(directory: profiles)

        let browser = BrowserWindow(application: application, layout: layout, session: session, history: history)
        window = browser
        browser.present()

        let requested = (ProcessInfo.processInfo.environment["SIX_URL"] ?? "")
            .split(separator: " ")
            .compactMap { URL(string: String($0)) }
        for url in requested.isEmpty ? [BrowserWindow.startPage] : requested { browser.open(url) }
    }

    return application.run()
}

exit(MainActor.assumeIsolated { run() })
