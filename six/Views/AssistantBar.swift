#if os(macOS)
import SwiftUI

/// Dia-style single input line pinned to the bottom of the page, with the answer floating above it.
struct AssistantBar: View {
    /// The page is what the window is for, so the line steps aside — until ⌘K asks for it, or an
    /// answer arrives. It stays in the hierarchy either way, which is what keeps ⌘K wired up.
    var isHidden = false

    @Environment(BrowserState.self) private var browser
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession
    @State private var question = ""
    @FocusState private var focused: Bool

    private var isAgent: Bool { assistant.settings.model.agentDefinition != nil }

    var body: some View {
        VStack(spacing: 8) {
            if assistant.isAnswerVisible {
                AnswerCard()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                ModelMenu()
                TextField(isAgent ? "Ask \(assistant.settings.model.title.replacingOccurrences(of: " (ACP)", with: ""))…" : "Ask about this page…", text: $question)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                if assistant.isResponding {
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
        .animation(.snappy, value: assistant.isAnswerVisible)
        .animation(.easeOut(duration: 0.16), value: isTuckedAway)
        .focusedSceneValue(\.focusAssistant, FocusAddressBarAction { focused = true })
    }

    private var isTuckedAway: Bool { isHidden && !focused && !assistant.isAnswerVisible }

    private func submit() {
        assistant.ask(question, about: browser.selectedTab)
        question = ""
    }
}

private struct AnswerCard: View {
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(assistant.settings.model.title, systemImage: assistant.settings.model.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let activity = assistant.activity {
                    Text("· \(activity)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                if assistant.isResponding { ProgressView().controlSize(.mini) }
                Button { assistant.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                if let error = assistant.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text(LocalizedStringKey(assistant.answer.isEmpty ? "…" : assistant.answer))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 260)
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
