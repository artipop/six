import SwiftUI

/// "Clear history?" with the question that matters: keep or drop the profile's site data (cookies,
/// local storage, caches — the logins). Used by the History menu and the ⌘Y panel.
struct ClearHistoryDialog: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(BrowserState.self) private var browser

    func body(content: Content) -> some View {
        let profile = browser.selectedProfile
        content.confirmationDialog("Clear \(profile.name) history?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Clear History Only") { browser.history.clear(profileID: profile.id) }
            Button("Clear History and Site Data", role: .destructive) {
                browser.history.clear(profileID: profile.id)
                Task { await browser.clearSiteData(for: profile.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Site data is the profile's cookies, local storage and caches — clearing it signs you out everywhere. Open windows stay open.")
        }
    }
}

extension View {
    func clearHistoryDialog(isPresented: Binding<Bool>) -> some View {
        modifier(ClearHistoryDialog(isPresented: isPresented))
    }
}

extension FocusedValues {
    @Entry var clearHistory: FocusAddressBarAction?
}
