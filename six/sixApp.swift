import SwiftUI

@main
struct sixApp: App {
    @State private var browser = BrowserState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(browser)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { browser.newTab() }
                    .keyboardShortcut("t")
                Button("Close Tab") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
            }
            BrowserCommands()
        }
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.focusAddressBar) private var focusAddressBar

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Location…") { focusAddressBar?.perform() }
                .keyboardShortcut("l")
                .disabled(focusAddressBar == nil)
        }
    }
}
