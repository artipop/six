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
    /// The verb Tab, a click, or a bare Return with nothing more to add has already picked — it
    /// stands in the field as a chip, and what is typed after it is its argument, not more of the
    /// filter that found it.
    @State private var lockedVerb: AssistantAction?
    /// One switch for both halves of the line, not a flag each: two `@FocusState`s in one view are
    /// one focus between them, and handing it from the row to the field means naming where it goes.
    @FocusState private var where_: Half?

    enum Half: Hashable { case field }
    /// Which chip Return would run. Arrows walk it.
    @State private var chosen = 0
    /// Which chat of the `/` list Return would pick; nil while the caret is only in the field.
    @State private var chosenChat: Int?
    /// Where the line stands in the window, for the scroll monitor (`reportFrame`).
    @State private var frame: CGRect = .zero

    private func reportFrame() {
        guard place == .bottom else { return }
        NiriScrollMonitor.overlays["assistant.line"] = isShown ? frame : nil
    }

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
        // The scroll monitor cannot tell the line from the strip by its views, so it is told where
        // the line stands — here at the bottom of the rail; beside a field `AnchoredAssistantLine`
        // says it, from outside its own hosting view where `.global` is still the window's.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0; reportFrame() }
        .onChange(of: isShown) { reportFrame() }
        .onChange(of: question) { chosenChat = nil }
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
    ///
    /// Two more things live here that are not about that row at all, because it is the one key
    /// handler the field already has: Tab locking the `/` row's match into a chip, and ⌘⌫ taking an
    /// empty one back off. Plain ⌫ is `RowWalking`'s reason and this one's too — in a focused field it
    /// is a character being deleted and nothing else, claimed by normal text editing before a
    /// `KeyPress` here ever sees it, so the chip waits for the same ⌘⌫ a mail app clears a line with.
    private func chipKey(_ press: KeyPress) -> KeyPress.Result {
        if ProcessInfo.processInfo.environment["SIX_UI_DEBUG"] != nil {
            Log.debug(.ui, "chip row saw «\(press.characters)» key \(press.key) mods \(press.modifiers)")
        }
        if isCommand, lockedVerb == nil, press.key == .tab, !press.modifiers.contains(.command),
           let match = verbs.first {
            lock(match)
            return .handled
        }
        if lockedVerb != nil, question.isEmpty, press.key == .delete, press.modifiers.contains(.command) {
            lockedVerb = nil
            return .handled
        }
        if lockedVerb == nil, assistant.continuedChat != nil, question.isEmpty, press.key == .delete,
           press.modifiers.contains(.command) {
            assistant.stopContinuingChat()
            return .handled
        }
        if let result = chatKey(press) { return result }
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
        if where_ == .field, isCommand, !showsChips, !verbs.isEmpty || !chatMatches.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if growsDown {
                    if !verbs.isEmpty { VerbRow(verbs: verbs) { run($0) } }
                    ChatMatches(chats: chatMatches, chosen: chosenChat) { pick($0) }
                } else {
                    ChatMatches(chats: chatMatches, chosen: chosenChat) { pick($0) }
                    if !verbs.isEmpty { VerbRow(verbs: verbs) { run($0) } }
                }
            }
            .transition(.opacity)
        }
    }

    /// After a `/` the line finds conversations as well as verbs: the words after it against the
    /// titles of the chats had in this folder, the five newest with nothing typed. Picked, the line
    /// goes on with that chat instead of starting one (`AssistantStore.continueChat`).
    private var chatMatches: [AgentChat] {
        guard isCommand, lockedVerb == nil else { return [] }
        return agentSession.chats(matching: String(question.dropFirst()))
    }

    /// ↑ and ↓ walk the chats a `/` found. The list stands on the side of the field the line grows
    /// away from, so the arrow that points at it goes in and the other one walks back out to the
    /// field — nil again, where Return means the verbs as before. ← and → stay the caret's.
    private func chatKey(_ press: KeyPress) -> KeyPress.Result? {
        let chats = chatMatches
        guard !chats.isEmpty, !press.modifiers.contains(.command) else { return nil }
        let last = chats.count - 1
        let intoList: KeyEquivalent = growsDown ? .downArrow : .upArrow
        let outOfList: KeyEquivalent = growsDown ? .upArrow : .downArrow
        switch press.key {
        case intoList:
            // Growing up, the list is above the field and its last row is the one beside it.
            if let index = chosenChat { chosenChat = growsDown ? min(last, index + 1) : max(0, index - 1) }
            else { chosenChat = growsDown ? 0 : last }
        case outOfList:
            guard let index = chosenChat else { return nil }
            let next = growsDown ? index - 1 : index + 1
            chosenChat = (0...last).contains(next) ? next : nil
        case .return:
            guard let index = chosenChat, chats.indices.contains(index) else { return nil }
            pick(chats[index])
        default:
            return nil
        }
        return .handled
    }

    private func pick(_ chat: AgentChat) {
        assistant.continueChat(chat.id)
        question = ""
        chosenChat = nil
    }

    private var field: some View {
        HStack(spacing: 8) {
            ModelMenu()
            if let lockedVerb {
                VerbChip(action: lockedVerb) { self.lockedVerb = nil; question = "" }
            } else if let chat = assistant.continuedChat {
                ChatChip(chat: chat) {
                    assistant.stopContinuingChat()
                } open: {
                    browser.openBuiltIn(.chat, section: chat.id.uuidString)
                }
            }
            if let badge = contextBadge, lockedVerb == nil {
                Label(badge.text, systemImage: badge.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            TextField(lockedVerb == nil ? placeholder : argumentPlaceholder, text: $question)
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

    /// What the field asks for once a verb is standing beside it as a chip.
    private var argumentPlaceholder: LocalizedStringKey {
        lockedVerb?.id == "research" ? "What should it research?" : "Say more, or press Return…"
    }

    /// Tab, or a click on the row: the verb becomes a chip and the field empties for its argument —
    /// nothing runs yet, so a word typed after it is never thrown away chasing the filter that found it.
    private func lock(_ action: AssistantAction) {
        lockedVerb = action
        question = ""
    }

    private func run(_ action: AssistantAction) {
        // Needs a topic no canned prompt can supply: become a chip and wait for one, same as Tab.
        if action.id == "research" {
            lock(action)
        } else {
            assistant.run(action, focus: focus, about: subject)
        }
        if isCommand { question = "" }
    }

    /// Return with a verb already a chip: research turns what follows it into the topic the run it
    /// already knows how to start needs; every other verb folds it into its own instruction, rather
    /// than send a word Tab picked up along the way to nowhere.
    private func runLocked(_ verb: AssistantAction) {
        let argument = question.trimmingCharacters(in: .whitespacesAndNewlines)
        lockedVerb = nil
        question = ""
        if verb.id == "research" {
            guard !argument.isEmpty else { return }
            assistant.ask("research: " + argument, about: subject)
            return
        }
        guard !argument.isEmpty else {
            assistant.run(verb, focus: focus, about: subject)
            return
        }
        let extended = AssistantAction(id: verb.id, title: verb.title, symbol: verb.symbol,
                                       requirement: verb.requirement, landing: verb.landing,
                                       prompt: verb.prompt + "\n\n" + argument)
        assistant.run(extended, focus: focus, about: subject)
    }

    /// Return sends the question. With nothing typed it takes the answer that is already there and
    /// puts it in the page — the one gesture that finishes a rewrite without reaching for the mouse.
    private func submit() {
        if let lockedVerb {
            runLocked(lockedVerb)
            return
        }
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
            if let first = verbs.first { run(first) } else if let chat = chatMatches.first { pick(chat) }
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
            // Inside the offset, so the frame is where the line is drawn and not where it was laid out.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                NiriScrollMonitor.overlays["assistant.line.\(tab.id)"] = $0
            }
            .offset(x: x, y: min(max(0, y), max(0, size.height - height)))
        }
        .onDisappear { NiriScrollMonitor.overlays["assistant.line.\(tab.id)"] = nil }
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

/// The verb Tab or a click has already picked, standing where its name was typed — the field beside
/// it holds only the argument now, not the filter that found it.
private struct VerbChip: View {
    let action: AssistantAction
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            Label { Text(action.title) } icon: { Image(systemName: action.symbol) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .help("Remove (⌘⌫)")
    }
}

/// Conversations the `/` found, one a line: a line reads as a title where a capsule reads as a verb.
private struct ChatMatches: View {
    let chats: [AgentChat]
    /// The row the arrows are on.
    let chosen: Int?
    let pick: (AgentChat) -> Void

    var body: some View {
        if !chats.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                    Button { pick(chat) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                            Text(chat.title ?? String(localized: "Untitled")).lineLimit(1)
                            Spacer(minLength: 12)
                            if let date = chat.updatedAt ?? chat.createdAt {
                                Text(date, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(index == chosen ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

/// The chat the line is going on with, standing where a verb chip would: removed with a click or
/// ⌘⌫, and opened as a window of its own with the arrow.
private struct ChatChip: View {
    let chat: AgentChat
    let remove: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: remove) {
                Label { Text(chat.title ?? String(localized: "Untitled")).lineLimit(1) } icon: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
            .help("Remove (⌘⌫)")
            Button(action: open) { Image(systemName: "arrow.up.right") }
                .help("Open as a Window")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .frame(maxWidth: 220, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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

/// The icon that opens it. A `Menu` used to stand here, and a native one dismisses on any selection —
/// AppKit's own `NSMenu`, which treats picking an agent the same as picking "Configuration…": an
/// action that ends the menu. Choosing a model for that agent is the very next thing a person wants
/// to do with the row they just picked, so this is a `.popover` instead — the pattern `ProfileMenuButton`
/// already uses for the same reason — and only "Configuration…" and "New Conversation" close it, because
/// those really are done with it.
private struct ModelMenu: View {
    @Environment(AssistantStore.self) private var assistant
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            AssistantSymbol(systemImage: assistant.settings.model.symbol)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(assistant.settings.model == .openAICompatible ? assistant.settings.openAIModel : assistant.settings.model.title)
        .popover(isPresented: $showing, arrowEdge: .bottom) { ModelPopover() }
    }
}

private struct ModelPopover: View {
    @Environment(AssistantStore.self) private var assistant
    @Environment(ConfigurationStore.self) private var store
    @Environment(BrowserState.self) private var browser
    @Environment(AgentSessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    private var settings: AssistantSettings { assistant.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Every agent `six://configuration` ▸ Assistant ▸ Agents knows about — built in or added
            // there — and no others: one missing from this row is a reason to open that page, not a
            // second place to add one from.
            row(ModelChoice.claudeCodeAgent.title, symbol: "terminal", selected: settings.providerTag == ModelChoice.claudeCodeAgent.rawValue) {
                settings.providerTag = ModelChoice.claudeCodeAgent.rawValue
            }
            row(ModelChoice.codexAgent.title, symbol: "terminal", selected: settings.providerTag == ModelChoice.codexAgent.rawValue) {
                settings.providerTag = ModelChoice.codexAgent.rawValue
            }
            ForEach(store.customAgents) { agent in
                row(agent.name, symbol: "terminal", selected: settings.providerTag == "custom:" + agent.id) {
                    settings.providerTag = "custom:" + agent.id
                }
            }
            // The model the chosen agent answers with — its own default until this changes it, for
            // this chat.
            if let agent = settings.model.agentDefinition {
                Divider().padding(.vertical, 4)
                modelRows(for: agent)
            }
            Divider().padding(.vertical, 4)
            ForEach(BookmarkScope.allCases) { scope in
                row(scope.title, selected: store.bookmarkScope == scope) { store.bookmarkScope = scope }
            }
            Divider().padding(.vertical, 4)
            // The keys and endpoints live on `six://settings` ▸ Assistant, which is one place and
            // not two. This used to open a sheet carrying the same three fields.
            footer("Configuration…") { browser.openBuiltIn(.configuration, section: "assistant"); dismiss() }
            footer("New Conversation") { assistant.resetConversation(); dismiss() }
        }
        .padding(8)
        .frame(width: 260)
        // Keyed on the agent, like Settings' own picker, so switching agents asks again — and it has
        // to live here rather than inside a row, because a row exists only while it is drawn and the
        // popover, unlike a `Menu`'s content, stays open long enough for that to matter.
        .task(id: settings.model.agentDefinition?.id) {
            guard let agent = settings.model.agentDefinition,
                  session.modelDiscovery.catalogs[agent.id] == nil else { return }
            await session.modelDiscovery.refresh(agent, toolchain: session.toolchain, directory: session.workingDirectory)
        }
    }

    @ViewBuilder private func modelRows(for agent: ACPAgentDefinition) -> some View {
        let choices = session.modelDiscovery.catalogs[agent.id]?.choices ?? []
        if choices.isEmpty {
            Text(session.modelDiscovery.loading.contains(agent.id) ? "Loading Models…" : "Model List Unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 24, alignment: .leading)
        } else {
            ForEach(choices) { model in
                row(model.name, selected: session.selectedModel(for: agent) == model.id) {
                    session.selectModel(model.id, for: agent)
                }
            }
        }
    }

    private func row(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).frame(width: 14) }
                Text(title).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightStyle(cornerRadius: 7, idle: 0.45))
    }

    private func row(_ title: LocalizedStringResource, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        row(String(localized: title), symbol: symbol, selected: selected, action: action)
    }

    private func footer(_ title: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        row(title, selected: false, action: action)
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
