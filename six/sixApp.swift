import SwiftUI

/// The binary is two things: the browser, and — with `--mcp` — a stdio MCP server that relays to the
/// running browser (see `MCPStdioBridge`). The switch happens before AppKit is touched.
@main
enum SixMain {
    static func main() {
        if MCPStdioBridge.isRequested { MCPStdioBridge.run() }
        signal(SIGPIPE, SIG_IGN) // a vanished MCP client or agent must not kill the app
        MainActor.assumeIsolated { sixApp.main() }
    }
}

struct sixApp: App {
    @State private var browser: BrowserState
    @State private var assistant: AssistantStore
    @State private var agentSession: AgentSessionStore
    @State private var mcp: MCPHost

    init() {
        let browser = BrowserState()
        let assistant = AssistantStore()
        let agentSession = AgentSessionStore()
        agentSession.browser = browser
        let tools = BrowserToolCatalog(browser: browser, assistant: assistant.settings)
        assistant.tools = tools
        assistant.agentSession = agentSession
        let mcp = MCPHost(server: MCPServer(catalog: tools))
        mcp.start()
        _browser = State(initialValue: browser)
        _assistant = State(initialValue: assistant)
        _agentSession = State(initialValue: agentSession)
        _mcp = State(initialValue: mcp)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(browser)
                .environment(assistant)
                .environment(agentSession)
                .environment(mcp)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1500, height: 950)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window in Strip") { browser.newTab() }
                    .keyboardShortcut("t")
                Button("Close Window") { browser.closeSelectedTab() }
                    .keyboardShortcut("w")
            }
            LayoutCommands(browser: browser)
            BrowserCommands()
        }
    }
}

/// niri's bindings, with ⌥ standing in for Mod.
private struct LayoutCommands: Commands {
    let browser: BrowserState

    var body: some Commands {
        CommandMenu("Layout") {
            Button("Focus Column Left") { browser.focusColumn(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Focus Column Right") { browser.focusColumn(1) }
                .keyboardShortcut(.rightArrow, modifiers: .option)
            Button("Focus First Column") { browser.focusColumnEdge(last: false) }
                .keyboardShortcut(.home, modifiers: .option)
            Button("Focus Last Column") { browser.focusColumnEdge(last: true) }
                .keyboardShortcut(.end, modifiers: .option)

            Divider()

            Button("Move Column Left") { browser.moveColumn(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
            Button("Move Column Right") { browser.moveColumn(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])

            Divider()

            Button("Focus Workspace Up") { browser.focusWorkspace(-1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Focus Workspace Down") { browser.focusWorkspace(1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Move Column to Workspace Up") { browser.moveColumnToWorkspace(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            Button("Move Column to Workspace Down") { browser.moveColumnToWorkspace(1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])

            Divider()

            Button("Switch Preset Column Width") { browser.cycleColumnWidth() }
                .keyboardShortcut("r", modifiers: .option)
            Button("Maximize Column") { browser.toggleFullWidth() }
                .keyboardShortcut("f", modifiers: .option)
            Button("Toggle Overview") { browser.toggleOverview() }
                .keyboardShortcut("o", modifiers: .option)

            Divider()

            Toggle("Center Focused Window", isOn: Binding(
                get: { browser.layout.centersFocus },
                set: { _ in browser.toggleCenterFocus() }
            ))
            .keyboardShortcut("c", modifiers: .option)
        }
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.focusAddressBar) private var focusAddressBar
    @FocusedValue(\.focusAssistant) private var focusAssistant
    @FocusedValue(\.toggleAgentPanel) private var toggleAgentPanel

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Open Location…") { focusAddressBar?.perform() }
                .keyboardShortcut("l")
                .disabled(focusAddressBar == nil)
            Button("Ask Assistant…") { focusAssistant?.perform() }
                .keyboardShortcut("k")
                .disabled(focusAssistant == nil)
            Button("Toggle Agent Panel") { toggleAgentPanel?.perform() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(toggleAgentPanel == nil)
        }
    }
}
