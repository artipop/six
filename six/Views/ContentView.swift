import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(BrowserState.self) private var browser
    @FocusState private var addressBarFocused: Bool
    @State private var showAgentPanel = false

    var body: some View {
        @Bindable var browser = browser
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let tab = browser.selectedTab {
                WebView(tab.page)
                    .webViewBackForwardNavigationGestures(.enabled)
                    .id(tab.id)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 8) {
                            NavigationButtons(tab: tab)
                                .buttonStyle(.borderless)
                            AddressBar(tab: tab, isFocused: $addressBarFocused)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.bar)
                    }
                    .navigationTitle(tab.title)
                    .overlay(alignment: .bottom) {
                        AssistantBar()
                    }
            } else {
                ContentUnavailableView("No tab", systemImage: "globe")
            }
        }
        .inspector(isPresented: $showAgentPanel) {
            AgentPanel()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 700)
        }
        .tint(browser.selectedProfile.color)
        .focusedSceneValue(\.toggleAgentPanel, FocusAddressBarAction { showAgentPanel.toggle() })
        .focusedSceneValue(\.focusAddressBar, FocusAddressBarAction { addressBarFocused = true })
    }
}

private struct NavigationButtons: View {
    let tab: BrowserTab

    var body: some View {
        Button { _ = tab.page.load(tab.page.backForwardList.backList.last) } label: {
            Image(systemName: "chevron.left")
        }
        .disabled(tab.page.backForwardList.backList.isEmpty)
        .help("Back")

        Button { _ = tab.page.load(tab.page.backForwardList.forwardList.first) } label: {
            Image(systemName: "chevron.right")
        }
        .disabled(tab.page.backForwardList.forwardList.isEmpty)
        .help("Forward")

        Button {
            if tab.page.isLoading { tab.page.stopLoading() } else { _ = tab.page.reload() }
        } label: {
            Image(systemName: tab.page.isLoading ? "xmark" : "arrow.clockwise")
        }
        .help(tab.page.isLoading ? "Stop" : "Reload")
    }
}

private extension WebPage {
    func load(_ item: WebPage.BackForwardList.Item?) -> Bool {
        guard let item else { return false }
        _ = load(item)
        return true
    }
}

// MARK: - Focus plumbing for ⌘L

struct FocusAddressBarAction {
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var focusAddressBar: FocusAddressBarAction?
}
