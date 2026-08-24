import SwiftUI

@main
struct sixApp: App {
    @State private var browser = BrowserState()
    @State private var assistant = AssistantStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(browser)
                .environment(assistant)
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
    @FocusedValue(\.focusAssistant) private var focusAssistant

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Location…") { focusAddressBar?.perform() }
                .keyboardShortcut("l")
                .disabled(focusAddressBar == nil)
            Button("Ask Assistant…") { focusAssistant?.perform() }
                .keyboardShortcut("k")
                .disabled(focusAssistant == nil)
        }
    }
}
