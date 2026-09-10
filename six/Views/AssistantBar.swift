#if os(macOS)
import SwiftUI

/// The line at the bottom of the strip, and the one place an answer lands.
///
/// It is a line and not a chat, and the difference is deliberate: what is asked is asked about what
/// is in front of the person — the selection, the field their cursor is in, this page — so the
/// context is on screen already and a transcript would only be six older contexts in the way. One
/// answer at a time, dismissed with Escape, applied with Return where it can be applied at all.
///
/// The verbs from `AssistantAction` are offered here as well as at the selection, because the two
/// surfaces are the same catalog: the bar over the page is for the mouse, this row is for the
/// keyboard, and neither is a place a use case has to be built twice.
struct AssistantBar: View {
    /// The page is what the window is for, so the line steps aside — until ⌘K asks for it, or an
    /// answer arrives. It stays in the hierarchy either way, which is what keeps ⌘K wired up.
    var isHidden = false

    @Environment(BrowserState.self) private var browser
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(PageFocusStore.self) private var focusStore
    @State private var question = ""
    @FocusState private var focused: Bool

    private var isAgent: Bool { assistant.settings.model.agentDefinition != nil }

    private var focus: PageFocus {
        guard let tab = browser.selectedTab else { return PageFocus() }
        return focusStore[tab.id]
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

    var body: some View {
        VStack(spacing: 8) {
            if let answer = assistant.answer {
                AnswerStrip(answer: answer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if focused, !verbs.isEmpty {
                VerbRow(verbs: verbs) { run($0) }
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                ModelMenu()
                if let badge = contextBadge {
                    Label(badge.text, systemImage: badge.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                TextField(placeholder, text: $question)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
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
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: 720)
        .opacity(isTuckedAway ? 0 : 1)
        .allowsHitTesting(!isTuckedAway)
        .animation(.snappy, value: assistant.answer)
        .animation(.easeOut(duration: 0.16), value: focused)
        .animation(.easeOut(duration: 0.16), value: isTuckedAway)
        .onExitCommand { assistant.dismiss(); focused = false }
        // The bar at a selection and the ⌘K line are one thing with two ends: "Ask…" over the page
        // puts the caret down here, with the selection already the subject.
        .onChange(of: assistant.focusRequests) { focused = true }
        .focusedSceneValue(\.focusAssistant, FocusAddressBarAction { focused = true })
    }

    private var verbs: [AssistantAction] {
        AssistantAction.offered(for: focus)
    }

    private var contextBadge: (text: LocalizedStringResource, symbol: String)? {
        switch focus.kind {
        case .selection: ("Selection", "text.quote")
        case .caret: focus.label.isEmpty ? ("This field", "character.cursor.ibeam") : nil
        case .none: nil
        }
    }

    private var isTuckedAway: Bool { isHidden && !focused && assistant.answer == nil }

    private func run(_ action: AssistantAction) {
        assistant.run(action, focus: focus, about: browser.selectedTab)
    }

    /// Return sends the question. With nothing typed it takes the answer that is already there and
    /// puts it in the page — the one gesture that finishes a rewrite without reaching for the mouse.
    private func submit() {
        if question.trimmingCharacters(in: .whitespaces).isEmpty {
            if assistant.answer?.isApplicable == true { assistant.apply(in: browser.selectedTab) }
            return
        }
        assistant.ask(question, about: browser.selectedTab)
        question = ""
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
                if let error = answer.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text(LocalizedStringKey(answer.text.isEmpty ? "…" : answer.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)
            if answer.isApplied {
                Label("Put into the page — ⌘Z takes it back", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !answer.text.isEmpty, !answer.isRunning {
                HStack(spacing: 8) {
                    if answer.isApplicable {
                        Button { assistant.apply(in: browser.selectedTab) } label: {
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
    @Environment(SettingsStore.self) private var store
    @Environment(BrowserState.self) private var browser

    var body: some View {
        @Bindable var settings = assistant.settings
        @Bindable var store = store
        Menu {
            Picker("Model", selection: $settings.model) {
                ForEach(ModelChoice.languageModels) { choice in
                    Label(choice.title, systemImage: choice.symbol)
                        .tag(choice)
                        .disabled(choice.isThirdParty && !FoundationModelsCompatibility.supportsThirdPartyModels)
                }
            }
            .pickerStyle(.inline)
            Picker("Agent", selection: $settings.model) {
                ForEach(ModelChoice.agents) { choice in
                    Label(choice.title, systemImage: choice.symbol).tag(choice)
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
            Button("Settings…") { browser.openBuiltIn(.settings) }
            Button("New Conversation") { assistant.resetConversation() }
        } label: {
            Image(systemName: settings.model.symbol)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(settings.model == .openAICompatible ? settings.openAIModel : settings.model.title)
    }
}

/// Where the remote provider behind the current choice is told who to call and as whom — `Section`s,
/// so whatever `Form` they land in styles them. Only the one the ⌘K line would actually use is
/// shown: a key field for a provider nobody is talking to is a question about a thing that isn't
/// happening, and an on-device model has neither. Both are development-shaped: the keys sit in
/// `UserDefaults`, not the Keychain. One home only, `six://settings` ▸ Assistant; the ⌘K line's own
/// menu links to it.
struct AssistantProviderSettings: View {
    @Environment(AssistantStore.self) private var assistant

    var body: some View {
        @Bindable var settings = assistant.settings
        switch settings.model {
        case .claudeSonnet, .claudeOpus:
            Section("Claude") {
                SecureField("API Key", text: $settings.anthropicAPIKey, prompt: Text("sk-ant-…"))
            }
            developmentNote
        case .openAICompatible:
            Section("OpenAI-compatible") {
                TextField("Endpoint", text: $settings.openAIBaseURL, prompt: Text("https://api.openai.com/v1"))
                    .textContentType(.URL)
                TextField("Model", text: $settings.openAIModel, prompt: Text("gpt-5"))
                SecureField("API Key", text: $settings.openAIAPIKey, prompt: Text("sk-… (blank for a local server)"))
                Text("Any server speaking the OpenAI /chat/completions format: OpenAI, a gateway, or llama.cpp and Ollama on this machine — those want no key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            developmentNote
        default:
            EmptyView()
        }
    }

    private var developmentNote: some View {
        Section {
            Text("Stored locally for development. Production builds should use App Attest or a proxy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension FocusedValues {
    @Entry var focusAssistant: FocusAddressBarAction?
}
#endif
