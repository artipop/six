#if os(macOS)
import AppKit
import SwiftUI

/// ⌘F's bar: a query, a count, and the two arrows that walk the matches — Safari's shape, in the
/// place `TranslateBar` and `PermissionBar` already answer the same question with: a sibling of
/// the web view in the column's stack, not drawn over it, so the field takes the keyboard and its
/// buttons see the mouse without going through `HostedOverlay`.
struct FindBar: View {
    let tab: BrowserTab
    let state: TabFind

    @Environment(BrowserState.self) private var browser
    @FocusState private var isFocused: Bool
    @State private var query: String

    init(tab: BrowserTab, state: TabFind) {
        self.tab = tab
        self.state = state
        _query = State(initialValue: state.query)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .frame(maxWidth: 220)
                .focused($isFocused)
                .onSubmit { step(shiftHeld ? -1 : 1) }
                .onKeyPress(.escape) {
                    browser.find.hide(tab, id: tab.id)
                    return .handled
                }
                .onChange(of: query) { _, new in
                    Task { await browser.find.search(new, in: tab, id: tab.id) }
                }
                // The bar mounts only while it is active (`NiriStripView`), so its one appearance
                // is exactly the moment to hand it the keyboard — the same trick a sheet uses,
                // without threading a `@FocusState` binding down from `ContentView` through three
                // more layers of the strip for a field nothing else needs to reach.
                .onAppear { isFocused = true }

            if !query.isEmpty {
                Text(state.hasNoMatches ? String(localized: "No Results") : "\(state.current) of \(state.count)")
                    .font(.caption)
                    .foregroundStyle(state.hasNoMatches ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .fixedSize()
            }

            Spacer(minLength: 8)

            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .help("Previous Match (⇧⏎)")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .help("Next Match (⏎)")
            Button { browser.find.hide(tab, id: tab.id) } label: { Image(systemName: "xmark") }
                .help("Close (⎋)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thickMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func step(_ delta: Int) {
        guard state.count > 0 else { return }
        Task { await browser.find.step(delta, in: tab, id: tab.id) }
    }

    /// `NSEvent.modifierFlags` rather than a second `onKeyPress`: `onSubmit` already answers plain
    /// ⏎, and the one thing left to ask is which hand pressed it — `deviceIndependentFlagsMask` for
    /// the reason `KeyBindings` always compares against it (CLAUDE.md: a stray `.capsLock` or
    /// `.function` bit must not turn ⇧⏎ into a key this never matches).
    private var shiftHeld: Bool {
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
    }
}
#endif
