#if os(macOS)
import SwiftUI

/// The ⌘E line, and the one place an answer lands.
///
/// It is a line and not a chat, and the difference is deliberate: what is asked is asked about what
/// is in front of the person — the selection, the field their cursor is in, this page — so the
/// context is on screen already and a transcript would only be six older contexts in the way. One
/// answer at a time, dismissed with Escape, applied with Return where it can be applied at all.
///
/// It stands in one of two places (`AssistantStore.LinePlace`), and nowhere until it is asked for.
/// With a caret in a field or text selected, ⌘E hangs it on that (`AnchoredAssistantLine`): the
/// question is about the thing, so it is asked next to the thing. With nothing pointed at, it rises
/// at the bottom of the rail. There used to be bars that came up by themselves — one over every
/// selection, one beside every comment box — and they were an assistant that would not wait to be
/// asked, over the page's own selection menus and toolbars. The verbs they carried are behind `/`.
struct AssistantBar: View {
    let place: AssistantStore.LinePlace
    /// The window the question is about. Nil at the bottom, where it is whichever is selected.
    var tab: BrowserTab?
    /// Hung below what it points at, the line comes first and the answer opens under it; at the
    /// bottom of the rail, or above a field near the bottom of the page, the other way round.
    var growsDown = false
    /// Beside a field or a selection the verbs come up straight away and the field waits behind
    /// them: what is wanted there is nearly always one of four things, and a row of named verbs says
    /// what they are, where an empty field asks the person to know. Any letter typed turns the row
    /// into the field with that letter already in it, so a question of your own costs no gesture.
    /// At the bottom, with nothing pointed at, there are no verbs to show and it is a field at once.
    var chipsFirst = false

    @Environment(BrowserState.self) private var browser
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession
    @State private var question = ""
    /// The full research sheet (topic, source count, the preset) — the same one the agent panel
    /// opens, so the bottom line does not grow a second, thinner way to start a run.
    @State private var showResearch = false
    /// One switch for both halves of the line, not a flag each: two `@FocusState`s in one view are
    /// one focus between them, and handing it from the row to the field means naming where it goes.
    @FocusState private var where_: Half?

    enum Half: Hashable { case field }
    /// Which chip Return would run. Arrows walk it.
    @State private var chosen = 0

    private var isAgent: Bool { assistant.settings.model.agentDefinition != nil }

    private var subject: BrowserTab? { tab ?? browser.selectedTab }

    private var focus: PageFocus {
        guard let subject else { return PageFocus() }
        return assistant.subject(in: subject.id)
    }

    /// The bottom line stays mounted while it is away, which is what lets ⌘E land in it. An answer
    /// that arrived with no line asked for — research, a self-test — shows there as well.
    private var isShown: Bool {
        switch place {
        case .page: true
        case .bottom: assistant.line == .bottom || (assistant.line == nil && assistant.answer != nil)
        }
    }

    /// What the line says it will do, which depends entirely on what is pointed at.
    private var placeholder: LocalizedStringKey {
        if isAgent {
            return "Ask \(assistant.settings.model.title.replacingOccurrences(of: " (ACP)", with: ""))…"
        }
        switch focus.kind {
        case .selection: return focus.isEditable ? "Ask about the selected text, or say how to change it…"
                                                 : "Ask about the selected text…"
        case .caret: return "Say what to write here…"
        case .none: return "Ask about this page…"
        }
    }

    /// The row is up beside a field or a selection until something is typed: the verbs are the
    /// answer nearly every time, and the field under them is for the times they are not.
    private var showsChips: Bool {
        chipsFirst && question.isEmpty && assistant.answer == nil && assistant.settings.trouble == nil
    }

    var body: some View {
        VStack(spacing: 8) {
            if growsDown {
                chipRow
                field
                verbRow
                answerStrip
            } else {
                answerStrip
                verbRow
                field
                chipRow
            }
        }
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .animation(.snappy, value: assistant.answer)
        .animation(.easeOut(duration: 0.16), value: where_)
        .animation(.easeOut(duration: 0.16), value: isShown)
        .onExitCommand { assistant.closeLine() }
        .onAppear { if assistant.line == place { takeCaret() } }
        .onChange(of: assistant.summons) { if assistant.line == place { takeCaret() } }
        .onChange(of: hasCaret) { if !hasCaret { assistant.lineLostFocus(at: place) } }
        .onChange(of: assistant.answer == nil) {
            if assistant.answer == nil, !hasCaret { assistant.lineLostFocus(at: place) }
        }
        .onChange(of: verbs.count) { chosen = min(chosen, max(0, verbs.count - 1)) }
        .sheet(isPresented: $showResearch) { ResearchSheet() }
    }

    /// The verbs, or — when the chosen model could not answer if it were asked — what is missing
    /// and the way to it. Said before anything is pressed: a person who has switched the assistant
    /// on and set nothing up otherwise learns it by pressing a verb and reading a failure.
    @ViewBuilder private var chipRow: some View {
        if let trouble = assistant.settings.trouble, isShown {
            TroubleRow(trouble: trouble)
                .transition(.opacity)
        } else if showsChips, !verbs.isEmpty {
            ChipRow(verbs: verbs, chosen: chosen) { run($0) }
                .transition(.opacity)
        }
    }

    /// The keyboard over the row, taken from the field under it while the field is empty: the
    /// arrows walk the verbs and Return runs the one they are on. The first character typed makes
    /// the row go and leaves the field with the question in it, which is why nothing here consumes
    /// one — the field is focused the whole time and takes it itself.
    private func chipKey(_ press: KeyPress) -> KeyPress.Result {
        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] != nil {
            Log.debug(.ui, "chip row saw «\(press.characters)» key \(press.key) mods \(press.modifiers)")
        }
        guard showsChips, !verbs.isEmpty, !press.modifiers.contains(.command) else { return .ignored }
        switch press.key {
        case .leftArrow, .upArrow: chosen = max(0, chosen - 1)
        case .rightArrow, .downArrow: chosen = min(verbs.count - 1, chosen + 1)
        case .return: run(verbs[chosen])
        default: return .ignored
        }
        return .handled
    }

    /// The row hands the keyboard to the field, with the same retry: the field does not exist until
    /// the row has gone, and a focus that misses leaves the letters after it going to the address bar.


    @ViewBuilder private var answerStrip: some View {
        if isShown, let answer = assistant.answer {
            AnswerStrip(answer: answer, tab: subject)
                .transition(.move(edge: growsDown ? .top : .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder private var verbRow: some View {
        if where_ == .field, isCommand, !verbs.isEmpty, !showsChips {
            VerbRow(verbs: verbs) { run($0) }
                .transition(.opacity)
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            ModelMenu()
            // Only at the bottom: over a selection or a field the question is about that text, and
            // "start a research run" about a paragraph is not a verb that text has.
            if place == .bottom {
                Button { showResearch = true } label: { Image(systemName: "text.magnifyingglass") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Deep Research…")
            }
            if let badge = contextBadge {
                Label(badge.text, systemImage: badge.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            TextField(placeholder, text: $question)
                .textFieldStyle(.plain)
                .focused($where_, equals: .field)
                .onSubmit(submit)
                .onKeyPress(phases: .down, action: chipKey)
            if assistant.answer?.isRunning == true {
                Button { assistant.cancel() } label: { Image(systemName: "stop.circle.fill") }
                    .buttonStyle(.plain)
            } else if !question.isEmpty {
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(browser.selectedProfile.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        // Invisible is not enough for a line that is away: its field is still in the window's
        // key-view loop, so Tab on a start page put the caret into a line nobody could see — and a
        // focused line is a shown one.
        .disabled(!isShown)
    }

    /// The keyboard is the line's whether the row or the field holds it.
    private var hasCaret: Bool { where_ != nil }

    /// Not now, and more than once. The line has only just been enabled — or, beside a page, only
    /// just been built inside a hosting view of its own — and a focus set in the same update lands
    /// on something that cannot take it yet. Asking again a few times is what makes the second ⌘E
    /// over the same field work: once, and the keystrokes after it went to the address bar.
    private func takeCaret() {
        chosen = 0
        Task { @MainActor in
            for _ in 0..<6 where where_ != .field {
                where_ = .field
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The verbs wait for a `/`. Offered on every ⌘E they stood over the line whatever it was
    /// opened for, and a row of buttons nobody asked for is the page's space taken twice. What
    /// follows the slash narrows the row by title (or by the English id, which a Latin layout can
    /// always type), and Return runs the first one left.
    private var isCommand: Bool { question.hasPrefix("/") }

    private var verbs: [AssistantAction] {
        let offered = AssistantAction.offered(for: focus)
        guard !showsChips else { return offered }
        let typed = question.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return offered }
        return offered.filter {
            String(localized: $0.title).localizedStandardContains(typed) || $0.id.localizedStandardContains(typed)
        }
    }

    private var contextBadge: (text: LocalizedStringResource, symbol: String)? {
        switch focus.kind {
        case .selection: ("Selection", "text.quote")
        case .caret: focus.label.isEmpty ? ("This field", "character.cursor.ibeam") : nil
        case .none: nil
        }
    }

    private func run(_ action: AssistantAction) {
        assistant.run(action, focus: focus, about: subject)
        if isCommand { question = "" }

    }

    /// Return sends the question. With nothing typed it takes the answer that is already there and
    /// puts it in the page — the one gesture that finishes a rewrite without reaching for the mouse.
    private func submit() {
        // Nothing to run while the model cannot answer: Return takes the person to the page that
        // would put it right, which is the only thing the line is offering then.
        if let trouble = assistant.settings.trouble, question.isEmpty {
            if trouble.isConfiguration { browser.openBuiltIn(.configuration, section: "assistant") }
            return
        }
        if showsChips, verbs.indices.contains(chosen) {
            run(verbs[chosen])
            return
        }
        if isCommand {
            if let first = verbs.first { run(first) }
            return
        }
        if question.trimmingCharacters(in: .whitespaces).isEmpty {
            if assistant.answer?.isApplicable == true { assistant.apply(in: subject) }
            return
        }
        assistant.ask(question, about: subject)
        question = ""
    }
}

/// The line hung on a field or a selection, inside the column and over its page.
///
/// A `HostedOverlay` for the reason `ColumnView`'s close badge is one: SwiftUI drawn over a
/// `WKWebView` never sees the mouse, and this has buttons — the answer's Insert and Copy. The frame
/// is explicit (a hosting view that sizes itself feeds constraints back into the window), so the
/// content reports its own height and the frame follows it: a fixed tall frame would leave a clear
/// box over the page that swallows clicks.
struct AnchoredAssistantLine: View {
    let tab: BrowserTab

    @Environment(BrowserState.self) private var browser
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(ConfigurationStore.self) private var configuration
    @State private var height: CGFloat = 44

    private static let gap: CGFloat = 8
    /// How much room below the field the line wants before it decides to open upwards: the line and
    /// an answer at its tallest. Decided on the reach, not the current height, so the line does not
    /// jump to the other side the moment an answer arrives.
    private static let reach: CGFloat = 340
    /// Control metrics: a line is as wide as a line needs to be, on any display.
    private static let minWidth: CGFloat = 420
    private static let maxWidth: CGFloat = 640

    var body: some View {
        GeometryReader { proxy in
            let rect = assistant.subject(in: tab.id).rect
            let size = proxy.size
            let width = max(0, min(max(rect.width, Self.minWidth), Self.maxWidth, size.width - Self.gap * 2))
            let below = rect.maxY + Self.gap + Self.reach <= size.height || rect.minY - Self.gap - Self.reach < 0
            let x = min(max(rect.minX, Self.gap), max(Self.gap, size.width - width - Self.gap))
            let y = below ? rect.maxY + Self.gap : rect.minY - Self.gap - height
            HostedOverlay {
                line(growsDown: below, width: width)
            }
            .frame(width: width, height: height)
            .offset(x: x, y: min(max(0, y), max(0, size.height - height)))
        }
        // What the line is about, put back in the page as well: the field collapsed its selection
        // to a caret when the keyboard left, and a person looking at a line about "four words" has
        // to be able to see which four. The page kept the nodes; six only kept the text.
        .task {
            let subject = assistant.subject(in: tab.id)
            guard subject.kind == .selection, !subject.text.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(120))
            let said = try? await tab.runScript(PageFocusScript.reselect,
                                                arguments: ["text": subject.text,
                                                            "start": subject.start, "end": subject.end])
            if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] != nil {
                Log.debug(.ui, "the page was asked to keep the selection: \(said ?? "—")")
            }
        }
        // The caret goes back to the page when the line is put away with nothing else taking it —
        // Esc or ⌘E over a comment box means "back to writing", not "nowhere".
        .onDisappear {
            guard assistant.line == nil, assistant.closedByKey,
                  let web = WebViewResponder.shared.webView(for: tab.id) else { return }
            web.window?.makeFirstResponder(web)
        }
    }

    private func line(growsDown: Bool, width: CGFloat) -> some View {
        AssistantBar(place: .page(tab.id), tab: tab, growsDown: growsDown, chipsFirst: true)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = ceil($0) }
            .frame(maxHeight: .infinity, alignment: growsDown ? .top : .bottom)
            .environment(browser)
            .environment(assistant)
            .environment(agentSession)
            .environment(configuration)
            .tint(browser.selectedProfile.color)
    }
}

/// What the chosen model is missing, where the verbs would be, with the way to put it right. The
/// button opens `six://configuration`, which is where the keys and the endpoint live; for the
/// troubles nobody can fix from here — a model still coming down, a Mac that cannot run it — there
/// is only the sentence, because a button that leads nowhere is worse than none.
private struct TroubleRow: View {
    let trouble: AssistantSettings.Trouble

    @Environment(BrowserState.self) private var browser

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: trouble.isConfiguration ? "slider.horizontal.3" : "clock")
            Text(trouble.message)
                .lineLimit(2)
            if trouble.isConfiguration {
                Button("Set Up…") { browser.openBuiltIn(.configuration, section: "assistant") }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// The verbs at a field or a selection, named, with the one Return would run filled in the profile's
/// colour. It is the first thing ⌘E shows there, so it reads as an offer rather than as decoration —
/// the titles are words and not icons, which is what a row of two symbols and an ellipsis failed at
/// when this was a bar over the selection. Typing in the field under it puts it away.
private struct ChipRow: View {
    let verbs: [AssistantAction]
    let chosen: Int
    let run: (AssistantAction) -> Void

    @Environment(BrowserState.self) private var browser

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(verbs.enumerated()), id: \.element.id) { index, verb in
                    Button { run(verb) } label: {
                        Label { Text(verb.title) } icon: { Image(systemName: verb.symbol) }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundStyle(index == chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background {
                                if index == chosen {
                                    Capsule().fill(browser.selectedProfile.color)
                                } else {
                                    Capsule().fill(.regularMaterial)
                                }
                            }
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The verbs that apply to what is pointed at right now, for the keyboard's end of the same catalog.
private struct VerbRow: View {
    let verbs: [AssistantAction]
    let run: (AssistantAction) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(verbs) { verb in
                    Button { run(verb) } label: {
                        Label { Text(verb.title) } icon: { Image(systemName: verb.symbol) }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One answer: what was asked, what came back, and the two things that can be done with it.
private struct AnswerStrip: View {
    let answer: AssistantStore.Answer
    let tab: BrowserTab?

    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(BrowserState.self) private var browser

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let action = answer.action {
                    Image(systemName: action.symbol).font(.caption)
                }
                Text(answer.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let activity = answer.activity {
                    Text("· \(activity)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if answer.isRunning { ProgressView().controlSize(.mini) }
                Button { assistant.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                // A turn that failed halfway usually explained itself first — an agent out of quota
                // says so in one line and then hands back a code with a page of transport under it.
                // Its own words are the answer when it got that far; the code stays in the panel's
                // transcript and in the log, where the shape of the failure is the point.
                if let error = answer.error, answer.text.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(LocalizedStringKey(answer.text.isEmpty ? "…" : answer.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)
            if let error = answer.error, answer.offersConfiguration {
                Button { browser.openBuiltIn(.configuration, section: "assistant") } label: {
                    Label("Set Up…", systemImage: "slider.horizontal.3")
                }
                .font(.caption)
                .controlSize(.small)
                .help(error)
            }
            if answer.isApplied {
                Label("Inserted into the page — ⌘Z to undo", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !answer.isRunning, !answer.text.isEmpty || answer.error != nil {
                HStack(spacing: 8) {
                    if answer.isApplicable {
                        Button { assistant.apply(in: tab) } label: {
                            Label(applyTitle, systemImage: "arrow.down.doc")
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    Button { assistant.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .font(.caption)
                .controlSize(.small)
            }
            // An agent may ask before touching something; answer it right here, like in the panel.
            if assistant.settings.model.agentDefinition != nil, let prompt = agentSession.permissionPrompt {
                Divider()
                PermissionView(prompt: prompt)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var applyTitle: LocalizedStringResource {
        switch answer.landing {
        case .insert: "Insert"
        case .replaceField, .replaceSelection: "Replace"
        case .show: "Insert"
        }
    }
}

private struct ModelMenu: View {
    @Environment(AssistantStore.self) private var assistant
    @Environment(ConfigurationStore.self) private var store
    @Environment(BrowserState.self) private var browser

    var body: some View {
        @Bindable var settings = assistant.settings
        @Bindable var store = store
        Menu {
            Picker("Model", selection: $settings.model) {
                ForEach(ModelChoice.languageModels) { choice in
                    Label { Text(choice.title) } icon: { AssistantSymbol(systemImage: choice.symbol) }
                        .tag(choice)
                        .disabled(choice.isThirdParty && !FoundationModelsCompatibility.supportsThirdPartyModels)
                }
            }
            .pickerStyle(.inline)
            Picker("Agent", selection: $settings.model) {
                ForEach(ModelChoice.agents) { choice in
                    Label { Text(choice.title) } icon: { AssistantSymbol(systemImage: choice.symbol) }
                        .tag(choice)
                }
            }
            .pickerStyle(.inline)
            if !FoundationModelsCompatibility.supportsThirdPartyModels {
                Text("Remote models unavailable: SDK/OS Foundation Models mismatch")
            }
            Divider()
            Picker("Bookmarks", selection: $store.bookmarkScope) {
                ForEach(BookmarkScope.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            // The keys and endpoints live on `six://settings` ▸ Assistant, which is one place and
            // not two. This used to open a sheet carrying the same three fields.
            Button("Configuration…") { browser.openBuiltIn(.configuration, section: "assistant") }
            Button("New Conversation") { assistant.resetConversation() }
        } label: {
            AssistantSymbol(systemImage: settings.model.symbol)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(settings.model == .openAICompatible ? settings.openAIModel : settings.model.title)
    }
}

/// Where the remote provider behind the current choice is told who to call and as whom — `Section`s,
/// so whatever `Form` they land in styles them. Only the one the ⌘E line would actually use is
/// shown: a key field for a provider nobody is talking to is a question about a thing that isn't
/// happening, and an on-device model has neither. Both are development-shaped: the keys sit in
/// `UserDefaults`, not the Keychain. One home only, `six://settings` ▸ Assistant; the ⌘E line's own
/// menu links to it.
struct AssistantProviderConfiguration: View {
    @Environment(AssistantStore.self) private var assistant

    var body: some View {
        @Bindable var settings = assistant.settings
        switch settings.model {
        case .claudeSonnet, .claudeOpus:
            Section("Claude") {
                SecureField("API Key", text: $settings.anthropicAPIKey, prompt: Text("sk-ant-…"))
            }
        case .openAICompatible:
            Section("OpenAI-compatible") {
                TextField("Endpoint", text: $settings.openAIBaseURL, prompt: Text("https://api.openai.com/v1"))
                    .textContentType(.URL)
                TextField("Model", text: $settings.openAIModel, prompt: Text("gpt-5"))
                SecureField("API Key", text: $settings.openAIAPIKey, prompt: Text("sk-… (blank for a local server)"))
            }
        default:
            EmptyView()
        }
    }
}
#endif
