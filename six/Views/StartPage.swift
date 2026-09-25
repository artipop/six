import SwiftUI

/// What a fresh window shows instead of somebody's home page: one field that takes both a query and
/// an address, with completions underneath. Native, so it gets real keyboard handling and the
/// profile's colour — and so the first thing a new window does isn't a network request.
struct StartPage: View {
    let tab: BrowserTab
    /// The field only grabs the keyboard in the focused window of the current workspace.
    let isActive: Bool

    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks
    @State private var text = ""
    #if !os(macOS)
    @State private var textSelection: TextSelection?
    #endif
    @State private var selection: Int?
    /// History, saved pages and the engine's completions — shared with the address field, whose
    /// comment has the order and the reasons for it.
    @State private var suggestions = AddressSuggestions()
    #if os(macOS)
    @State private var fieldFocused = false
    #else
    @FocusState private var fieldFocused: Bool
    #endif
    @Environment(ConfigurationStore.self) private var settings
    /// From settings, not a local copy: every other start page redraws when this one switches engines.
    private var engine: SearchEngine { settings.searchEngine }

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    private var context: AddressSuggestions.Context {
        AddressSuggestions.Context(history: browser.history, bookmarks: bookmarks, scope: settings.bookmarkScope,
                                   profileID: tab.profileID, isPrivate: browser.isPrivate(tab.profileID),
                                   searchEngine: engine)
    }

    private var rows: [AddressSuggestions.Row] {
        suggestions.rows(for: text, context: context)
    }

    /// Where the name and the field stand, as a share of the window's height rather than a number of
    /// points — the rest of six sizes itself that way, and a start page is a page.
    private static let restingHeight = 0.32
    /// What the name, the field and a full list want under them, in points, because that is what a
    /// font is measured in. In a window too short for both, the field gives up its share of the
    /// height rather than the list going off the bottom edge.
    private static let contentHeight: CGFloat = 480

    private func topInset(_ height: CGFloat) -> CGFloat {
        min(height * Self.restingHeight, max(24, height - Self.contentHeight))
    }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom)
                // A click anywhere that is not the field, the list or the engine lets go of the
                // caret. The field takes the keyboard the moment a window opens, and while it holds
                // it every `⌥` key is text — «ø» for ⌥O, word movement for ⌥← — so there has to be a
                // way to hand the keys back to the row that is not reaching for a different window.
                // On the gradient, which is behind everything else: the rows and the picker keep
                // their own clicks, and the empty stretches of the stack above are not hit-testable.
                .onTapGesture { fieldFocused = false }
            // The stack hangs from a fixed point near the top instead of being centred, and that is
            // the whole reason for the geometry reader. Centred, the field moved every time the list
            // under it changed height: a row arrives from the engine and the thing you are typing
            // into jumps upward under the caret. The list is the only part that may grow, and it
            // grows downward into the empty half of the page, where there is room for it.
            GeometryReader { geometry in
                VStack(spacing: 14) {
                    Text("six")
                        .font(.system(size: 46, weight: .light, design: .rounded))
                        .foregroundStyle(accent)
                    field
                    list
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, topInset(geometry.size.height))
            }
        }
        .background(.background)
        .onChange(of: isActive, initial: true) { _, active in
            fieldFocused = active
            guard active else { return }
            // The rows below the field are answered by a model that takes seconds to load, and a
            // start page taking the keyboard is the earliest honest sign that a question is coming.
            // Not in a private window, which searches nothing of yours anyway (`updatePersonal`).
            if !browser.isPrivate(tab.profileID) {
                bookmarks.warmUpEmbedder(in: settings.bookmarkScope, profileID: tab.profileID)
            }
        }
        .onChange(of: text) { _, value in
            selection = nil
            suggestions.update(for: value, context: context)
        }
        .onChange(of: engine) { _, _ in suggestions.update(for: text, context: context) }
        .onChange(of: settings.bookmarkScope) { _, _ in suggestions.update(for: text, context: context) }
    }

    private var field: some View {
        HStack(spacing: 10) {
            enginePicker
            #if os(macOS)
            SuggestionTextField(text: $text, focused: $fieldFocused, accent: accent,
                                move: { move($0) == .handled },
                                complete: selectedCompletion,
                                submit: submit,
                                escape: escape)
                .frame(height: 24)
            #else
            TextField("Search or enter address", text: $text, selection: $textSelection)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(keys: [.tab, .rightArrow], phases: .down) { press in
                    // Modified arrows still edit text, and Shift-Tab still moves focus backward.
                    guard press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty else {
                        return .ignored
                    }
                    guard let value = selectedCompletion() else { return .ignored }
                    text = value
                    textSelection = TextSelection(insertionPoint: text.endIndex)
                    return .handled
                }
                // Esc clears what was typed, and on a field with nothing in it lets go of the caret —
                // the way an address bar gives up its text and then the focus. `.ignored` would hand
                // it on to the page's own Esc, and a start page has none.
                .onKeyPress(.escape) {
                    escape()
                    return .handled
                }
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(fieldFocused ? AnyShapeStyle(accent) : AnyShapeStyle(.separator), lineWidth: fieldFocused ? 2 : 1) }
    }

    /// Which engine answers the field, in the one place where it matters — next to the field.
    private var enginePicker: some View {
        @Bindable var settings = settings
        return Menu {
            Picker("Search Engine", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                Text(engine.title)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var list: some View {
        let rows = rows
        if !rows.isEmpty {
            SuggestionList(rows: rows, selection: $selection, accent: accent, open: open)
                .transition(.opacity)
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let next = (selection ?? -1) + delta
        selection = next < 0 ? nil : min(next, rows.count - 1)
        return .handled
    }

    private func clearSuggestions() {
        suggestions.clear()
    }

    private func selectedCompletion() -> String? {
        let rows = rows
        guard let selection, rows.indices.contains(selection) else { return nil }
        self.selection = nil
        return rows[selection].completion
    }

    private func submit() {
        let rows = rows
        if let selection, rows.indices.contains(selection) { open(rows[selection]) } else { open(text) }
    }

    private func escape() {
        guard !text.isEmpty else {
            fieldFocused = false
            return
        }
        text = ""
        clearSuggestions()
    }

    private func open(_ row: AddressSuggestions.Row) {
        clearSuggestions()
        row.open(in: tab)
    }

    private func open(_ input: String) {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        clearSuggestions()
        tab.navigate(to: input)
    }
}
