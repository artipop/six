import Foundation
import FoundationModels

/// Which `LanguageModel` backs the assistant. All of them are driven through the same `LanguageModelSession`.
/// The Mac has two cases the phone does not: Claude through the vendored `LanguageModel`, whose
/// FoundationModels SPI only the Command Line Tools SDK has, and the ACP agents, which are local
/// processes. A setting saved on one and read on the other falls back to `.onDevice`.
enum ModelChoice: String, CaseIterable, Identifiable, Codable {
    case onDevice
    case privateCloudCompute
    #if os(macOS)
    case claudeSonnet
    case claudeOpus
    /// Any server speaking the OpenAI `/chat/completions` wire format — OpenAI itself, or the
    /// endpoint and model named in the settings (a gateway, a local llama.cpp, Ollama).
    case openAICompatible = "openai"
    /// ACP agents: the same ⌘E line, answered by Claude Code / Codex through the agent session.
    case claudeCodeAgent = "acp:claude-code"
    case codexAgent = "acp:codex"
    #endif

    var id: String { rawValue }

    #if os(macOS)
    static let languageModels: [ModelChoice] = [.onDevice, .privateCloudCompute, .claudeSonnet, .claudeOpus, .openAICompatible]
    static let agents: [ModelChoice] = [.claudeCodeAgent, .codexAgent]
    #elseif os(iOS)
    static let languageModels: [ModelChoice] = [.onDevice, .privateCloudCompute]
    static let agents: [ModelChoice] = []
    #endif

    var title: String {
        switch self {
        case .onDevice: "On-Device"
        case .privateCloudCompute: "Private Cloud Compute"
        #if os(macOS)
        case .claudeSonnet: "Claude Sonnet 5"
        case .claudeOpus: "Claude Opus 5"
        case .openAICompatible: "OpenAI-compatible"
        case .claudeCodeAgent: "Claude Code (ACP)"
        case .codexAgent: "Codex (ACP)"
        #endif
        }
    }

    var symbol: String {
        switch self {
        case .onDevice: "cpu"
        case .privateCloudCompute: "icloud"
        #if os(macOS)
        case .claudeSonnet, .claudeOpus: "sparkles"
        case .openAICompatible: "network"
        case .claudeCodeAgent, .codexAgent: "terminal"
        #endif
        }
    }

    /// True for the models that are somebody else's server behind a third-party `LanguageModel` —
    /// the ones the executor-ABI probe has to clear before they can be picked at all.
    var isThirdParty: Bool {
        #if os(macOS)
        self == .claudeSonnet || self == .claudeOpus || self == .openAICompatible
        #elseif os(iOS)
        false
        #endif
    }

    /// True when the choice is an agent rather than a language model — an agent answers through a
    /// session of its own and is no use for the in-process jobs the tools run.
    var isAgent: Bool { Self.agents.contains(self) }

    #if os(macOS)
    /// The ACP agent behind this choice, if it is one.
    var agentDefinition: ACPAgentDefinition? {
        switch self {
        case .claudeCodeAgent: .claudeCode
        case .codexAgent: .codex
        default: nil
        }
    }
    #endif
}

/// User-facing assistant settings.
@MainActor
@Observable
final class AssistantSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let store: ConfigurationStore

    /// Lives in the settings table with the other preferences.
    var model: ModelChoice {
        get { store.assistantModel }
        set { store.assistantModel = newValue }
    }

    /// Development-only credential, kept out of the database (which may sync one day): `UserDefaults`
    /// for now, the Keychain later. For shipping, use `AuthMode.appAttest` or a proxy — never bundle a key.
    var anthropicAPIKey: String {
        didSet { defaults.set(anthropicAPIKey, forKey: "six.assistant.anthropicKey") }
    }

    /// The same, for whatever OpenAI-compatible endpoint is configured. Empty is a valid answer:
    /// a llama.cpp or Ollama server on this machine wants no credential at all, and sending an
    /// empty `Authorization` header to one is worse than sending none.
    var openAIAPIKey: String {
        didSet { defaults.set(openAIAPIKey, forKey: "six.assistant.openAIKey") }
    }

    /// Where that endpoint is, and which model it is asked for. Not secrets, so they live in the
    /// settings table with the rest of the preferences.
    var openAIBaseURL: String {
        get { store.assistantOpenAIBaseURL }
        set { store.assistantOpenAIBaseURL = newValue }
    }

    var openAIModel: String {
        get { store.assistantOpenAIModel }
        set { store.assistantOpenAIModel = newValue }
    }

    init(store: ConfigurationStore) {
        self.store = store
        anthropicAPIKey = defaults.string(forKey: "six.assistant.anthropicKey")
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        openAIAPIKey = defaults.string(forKey: "six.assistant.openAIKey")
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    /// Whether the chosen model could answer right now, asked before anything is sent — the ⌘E line
    /// says so where the verbs would be, rather than letting a person press one and read the same
    /// thing as a failure. Two kinds, because they want different things of the person: something to
    /// fill in here, or something that is not theirs to fix.
    enum Trouble: Equatable {
        /// A key, an endpoint, a model name: `six://configuration` ▸ Assistant.
        case notConfigured(LocalizedStringResource)
        /// A model still coming down, a Mac that cannot run it, an SDK that does not match the OS.
        case unavailable(LocalizedStringResource)

        var message: LocalizedStringResource {
            switch self {
            case .notConfigured(let why), .unavailable(let why): why
            }
        }

        var isConfiguration: Bool {
            if case .notConfigured = self { return true }
            return false
        }
    }

    /// Nil when the chosen model is ready. Cheap enough to read in a view body: nothing here builds
    /// a session or touches the network.
    var trouble: Trouble? { trouble(for: model) }

    /// Asked about any choice, not only the current one, so a self-test can print the lot without
    /// setting six's own model as a side effect.
    func trouble(for model: ModelChoice) -> Trouble? {
        switch model {
        #if os(macOS)
        case .claudeCodeAgent, .codexAgent:
            // An agent is a process six starts when it is asked to; whether it is installed is
            // something only starting it says, and the panel says it then.
            return nil
        #endif
        case .onDevice:
            return Self.trouble(with: SystemLanguageModel.default.availability, called: "On-Device")
        case .privateCloudCompute:
            // Its own `Availability`, with its own reasons: the two types have the same shape and no
            // common protocol, so the switch is written twice rather than made generic over nothing.
            switch PrivateCloudComputeLanguageModel().availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .systemNotReady:
                    return .unavailable("Private Cloud Compute is not ready yet — it answers when it is")
                case .deviceNotEligible:
                    return .unavailable("This Mac cannot use Private Cloud Compute")
                @unknown default:
                    return .unavailable("Private Cloud Compute is unavailable")
                }
            @unknown default: return nil
            }
        #if os(macOS)
        case .claudeSonnet, .claudeOpus:
            guard FoundationModelsCompatibility.supportsThirdPartyModels else {
                return .unavailable("\(FoundationModelsCompatibility.mismatchExplanation)")
            }
            guard !anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .notConfigured("Claude needs an API key")
            }
            return nil
        case .openAICompatible:
            guard FoundationModelsCompatibility.supportsThirdPartyModels else {
                return .unavailable("\(FoundationModelsCompatibility.mismatchExplanation)")
            }
            let address = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: address), url.scheme != nil, url.host() != nil else {
                return .notConfigured(address.isEmpty ? "This model needs an address to ask"
                                                      : "That address is not one six can ask")
            }
            guard !openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .notConfigured("Name the model this address should answer with")
            }
            return nil
        #endif
        }
    }

    /// What Foundation Models says, in words about what to do next. The reason matters more than the
    /// name of it: a model still coming down is a wait, Apple Intelligence switched off is a switch
    /// in System Settings, and a Mac that cannot run it is a different model in the menu.
    private static func trouble(with availability: SystemLanguageModel.Availability,
                                called name: LocalizedStringResource) -> Trouble? {
        switch availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable("Apple Intelligence is switched off in System Settings")
            case .modelNotReady:
                return .unavailable("\(name) is still downloading — it answers when it is here")
            case .deviceNotEligible:
                return .unavailable("This Mac cannot run \(name)")
            @unknown default:
                return .unavailable("\(name) is unavailable")
            }
        @unknown default:
            return nil
        }
    }

    /// The same question `trouble` answers, as the thing to say before building a session.
    private func check() throws {
        switch trouble {
        case .none: return
        case .notConfigured(let why): throw AssistantError.notConfigured(why)
        case .unavailable(let why): throw AssistantError.unavailable(why)
        }
    }

    /// Builds a session for the selected model. Throws a readable error when the model isn't usable.
    /// `tools` are offered to the model (browser tools for the assistant; none for one-off jobs).
    func makeSession(instructions: String, tools: [any Tool] = []) throws -> LanguageModelSession {
        switch model {
        #if os(macOS)
        case .claudeCodeAgent, .codexAgent:
            throw AssistantError.unavailable("\(model.title) is an agent, not a language model")
        #endif
        case .onDevice:
            try check()
            return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
        case .privateCloudCompute:
            try check()
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        #if os(macOS)
        case .claudeSonnet, .claudeOpus:
            try check()
            let key = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let claude = ClaudeLanguageModel(
                name: model == .claudeOpus ? .opus5 : .sonnet5,
                auth: .apiKey(key)
            )
            return LanguageModelSession(model: claude, tools: tools, instructions: instructions)
        case .openAICompatible:
            try check()
            let address = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: address), url.scheme != nil, url.host() != nil else {
                throw AssistantError.notConfigured("That address is not one six can ask")
            }
            let name = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            // No key is a real answer — a server on this machine asks for none — so the header
            // goes on only when there is something to put in it.
            let openAIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let openAI = ChatCompletionsLanguageModel(
                name: name,
                url: url,
                additionalHeaders: openAIKey.isEmpty ? [:] : ["Authorization": "Bearer \(openAIKey)"]
            )
            return LanguageModelSession(model: openAI, tools: tools, instructions: instructions)
        #endif
        }
    }
}

/// Why the assistant could not answer, in the words the line shows. `notConfigured` is the half a
/// person can do something about without leaving six, and the line offers the way there.
enum AssistantError: LocalizedError {
    case unavailable(LocalizedStringResource)
    case notConfigured(LocalizedStringResource)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .notConfigured(let reason): String(localized: reason)
        }
    }

    var isConfiguration: Bool {
        if case .notConfigured = self { return true }
        return false
    }
}

// MARK: - Configuration

/// The setting lives in the settings table; the knowledge of what its string means lives here,
/// beside the type it means it as. `ConfigurationStore` itself keeps only keys and strings.
extension ConfigurationStore {
    /// Which model answers ⌘E.
    var assistantModel: ModelChoice {
        get { ModelChoice(rawValue: self[.assistantModel] ?? "") ?? .onDevice }
        set { self[.assistantModel] = newValue.rawValue }
    }

    /// The OpenAI-compatible endpoint and the model asked of it. Both start at what OpenAI itself
    /// answers to, and the environment can name either for a run without touching the settings.
    var assistantOpenAIBaseURL: String {
        get {
            self[.assistantOpenAIBaseURL]
                ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
                ?? "https://api.openai.com/v1"
        }
        set { self[.assistantOpenAIBaseURL] = newValue }
    }

    var assistantOpenAIModel: String {
        get {
            self[.assistantOpenAIModel]
                ?? ProcessInfo.processInfo.environment["OPENAI_MODEL"]
                ?? "gpt-5"
        }
        set { self[.assistantOpenAIModel] = newValue }
    }
}
