#if os(macOS)
import SwiftUI

/// The first window six ever opens, and the one question it has to ask.
///
/// A page and not a sheet, for the reason written on `BuiltInPage`: a browser's answer to "show me
/// something" is a window on the rail. It can be closed, it can be opened again from the menu, and
/// it teaches the layout in the act of being read — the first thing a new person does here is close
/// a column.
///
/// One question, and one more if the answer is yes: six is built around language models, and
/// whether they run at all is not a preference to discover in a settings pane three days later. A
/// yes that stops there, though, leaves a ⌘E line that can do nothing until somebody finds the key
/// field — so the second step is which model answers, set up on the spot. Everything else six could
/// ask — the default browser, what to block — either has a right answer or asks itself at the
/// moment it matters.
struct WelcomePage: View {
    let tab: BrowserTab

    @Environment(ConfigurationStore.self) private var settings
    @Environment(BrowserState.self) private var browser
    @Environment(AssistantStore.self) private var assistant
    @Environment(AgentSessionStore.self) private var agentSession

    private enum Step { case question, provider }
    @State private var step: Step = .question

    /// The four doors on the second step. "API" is one card over three models, because the choice
    /// between them is a key a person already has, not a thing to weigh on a welcome page.
    private enum Provider: CaseIterable { case onDevice, claudeCode, codex, api }
    @State private var provider: Provider = .onDevice
    @State private var apiModel: ModelChoice = .claudeSonnet

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("six")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(browser.selectedProfile.color)
                Text("A browser with a rail instead of tabs: a page is a full-height window, the windows stand side by side, and the rail scrolls. ⌥← and ⌥→ move along it; ⌥↑ and ⌥↓ move between workspaces.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().padding(.vertical, 28)

                switch step {
                case .question: question
                case .provider: providerStep
                }

                Text("You can change this at any time in Configuration ▸ Assistant.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            }
            // A share of the window rather than a constant: this is a column on a 5K panel and a
            // column on a laptop, and a 640-point measure is a different thing on each.
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(.background)
    }

    @ViewBuilder private var question: some View {
        Text("Should six use language models?")
            .font(.title2.weight(.semibold))
        Text("The ⌘E line, actions over selected text, the agent panel, deep research and the MCP server.")
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
            Choice(title: "Yes, use them",
                   detail: "The on-device model keeps everything on this Mac; others need your own key.",
                   symbol: "sparkles",
                   isProminent: true) {
                // Written now, not on Done: the agent rows below ask the toolchain, which is only
                // built with the switch on. The welcome itself stays unanswered until Done, so a
                // quit halfway through asks again.
                settings.isAIEnabled = true
                step = .provider
            }
            Choice(title: "No, don't use them",
                   detail: "Nothing is loaded or added to pages. Bookmark search and translation still work.",
                   symbol: "nosign",
                   isProminent: false) { answer(false) }
        }
        .padding(.top, 20)
    }

    @ViewBuilder private var providerStep: some View {
        Text("Which model should answer?")
            .font(.title2.weight(.semibold))

        HStack(spacing: 12) {
            ForEach(Provider.allCases, id: \.self) { item in
                Choice(title: title(item), detail: detail(item), symbol: symbol(item),
                       isProminent: provider == item, height: 130) { provider = item }
                    .disabled(item == .api && !FoundationModelsCompatibility.supportsThirdPartyModels)
            }
        }
        .padding(.top, 20)

        setup
            .padding(.top, 16)

        HStack {
            Button("Back") { step = .question }
            Spacer()
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.top, 20)
    }

    /// What the chosen door needs, and nothing for the ones not chosen. Nothing here blocks Done: a
    /// key left empty is said again by the ⌘E line itself (`AssistantSettings.trouble`).
    @ViewBuilder private var setup: some View {
        switch provider {
        case .onDevice:
            if let trouble = assistant.settings.trouble(for: .onDevice) {
                Text(trouble.message).font(.caption).foregroundStyle(.orange)
            }
        case .claudeCode:
            AgentToolchainRow(agent: .claudeCode)
        case .codex:
            AgentToolchainRow(agent: .codex)
        case .api:
            if FoundationModelsCompatibility.supportsThirdPartyModels {
                @Bindable var settings = assistant.settings
                Form {
                    Section {
                        Picker("Model", selection: $apiModel) {
                            ForEach([ModelChoice.claudeSonnet, .claudeOpus, .openAICompatible]) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                    }
                    // The same fields Configuration ▸ Assistant shows, answering to whatever the ⌘E
                    // line is set to — so the choice is written as it is made, not only on Done.
                    AssistantProviderConfiguration()
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(minHeight: 220)
                .onAppear { settings.model = apiModel }
                .onChange(of: apiModel) { settings.model = apiModel }
            } else {
                Text("Remote models unavailable: SDK/OS Foundation Models mismatch")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func model(for item: Provider) -> ModelChoice {
        switch item {
        case .onDevice: .onDevice
        case .claudeCode: .claudeCodeAgent
        case .codex: .codexAgent
        case .api: apiModel
        }
    }

    private func title(_ item: Provider) -> LocalizedStringResource {
        switch item {
        case .onDevice: "On-Device"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .api: "API Key"
        }
    }

    private func detail(_ item: Provider) -> LocalizedStringResource {
        switch item {
        case .onDevice: "Apple's model. Nothing leaves this Mac."
        case .claudeCode: "Your Claude subscription, through the claude CLI."
        case .codex: "Your ChatGPT subscription, through the codex CLI."
        case .api: "Anthropic or any OpenAI-compatible server."
        }
    }

    private func symbol(_ item: Provider) -> String {
        switch item {
        case .onDevice: "cpu"
        case .claudeCode, .codex: "terminal"
        case .api: "key"
        }
    }

    /// The ⌘E line and the agent panel are pointed at the same thing: a person who picked Codex
    /// here and opened the panel to find Claude Code in it would have been asked for nothing.
    private func finish() {
        let choice = model(for: provider)
        assistant.settings.model = choice
        if let agent = choice.agentDefinition { agentSession.agent = agent }
        settings.hasAnsweredWelcome = true
        browser.closeTab(tab.id)
    }

    /// Answering is the whole of it: the switch is written, the question is marked asked, and the
    /// window closes — the rail is left empty rather than holding a page nobody needs twice.
    private func answer(_ enabled: Bool) {
        settings.isAIEnabled = enabled
        settings.hasAnsweredWelcome = true
        browser.closeTab(tab.id)
    }

    private struct Choice: View {
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        let symbol: String
        let isProminent: Bool
        var height: CGFloat = 170
        let action: () -> Void

        @Environment(BrowserState.self) private var browser
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(isProminent ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.secondary))
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isProminent ? browser.selectedProfile.color.opacity(0.7) : Color.secondary.opacity(0.25),
                                      lineWidth: isProminent ? 2 : 1)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
#endif
