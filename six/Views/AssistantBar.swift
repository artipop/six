import SwiftUI

/// Dia-style single input line pinned to the bottom of the page, with the answer floating above it.
struct AssistantBar: View {
    @Environment(BrowserState.self) private var browser
    @Environment(AssistantStore.self) private var assistant
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if assistant.isAnswerVisible {
                AnswerCard()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                ModelMenu()
                TextField("Ask about this page…", text: $question)
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
        .animation(.snappy, value: assistant.isAnswerVisible)
        .focusedSceneValue(\.focusAssistant, FocusAddressBarAction { focused = true })
    }

    private func submit() {
        assistant.ask(question, about: browser.selectedTab)
        question = ""
    }
}

private struct AnswerCard: View {
    @Environment(AssistantStore.self) private var assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(assistant.settings.model.title, systemImage: assistant.settings.model.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}

private struct ModelMenu: View {
    @Environment(AssistantStore.self) private var assistant
    @State private var showingKeySheet = false

    var body: some View {
        @Bindable var settings = assistant.settings
        Menu {
            Picker("Model", selection: $settings.model) {
                ForEach(ModelChoice.allCases) { choice in
                    Label(choice.title, systemImage: choice.symbol)
                        .tag(choice)
                        .disabled(choice.isClaude && !FoundationModelsCompatibility.supportsThirdPartyModels)
                }
            }
            .pickerStyle(.inline)
            if !FoundationModelsCompatibility.supportsThirdPartyModels {
                Text("Claude unavailable: SDK/OS Foundation Models mismatch")
            }
            Divider()
            Button("Anthropic API Key…") { showingKeySheet = true }
            Button("New Conversation") { assistant.resetConversation() }
        } label: {
            Image(systemName: settings.model.symbol)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(settings.model.title)
        .sheet(isPresented: $showingKeySheet) {
            APIKeySheet()
        }
    }
}

private struct APIKeySheet: View {
    @Environment(AssistantStore.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = assistant.settings
        Form {
            SecureField("Anthropic API Key", text: $settings.anthropicAPIKey, prompt: Text("sk-ant-…"))
            Text("Stored locally for development. Production builds should use App Attest or a proxy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
}

extension FocusedValues {
    @Entry var focusAssistant: FocusAddressBarAction?
}
