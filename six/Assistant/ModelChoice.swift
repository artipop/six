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
    /// ACP agents: the same ⌘K line, answered by Claude Code / Codex through the agent session.
    case claudeCodeAgent = "acp:claude-code"
    case codexAgent = "acp:codex"
    #endif

    var id: String { rawValue }

    #if os(macOS)
    static let languageModels: [ModelChoice] = [.onDevice, .privateCloudCompute, .claudeSonnet, .claudeOpus]
    static let agents: [ModelChoice] = [.claudeCodeAgent, .codexAgent]
    #else
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
        case .claudeCodeAgent, .codexAgent: "terminal"
        #endif
        }
    }

    var isClaude: Bool {
        #if os(macOS)
        self == .claudeSonnet || self == .claudeOpus
        #else
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
    @ObservationIgnored private let store: SettingsStore

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

    init(store: SettingsStore) {
        self.store = store
        anthropicAPIKey = defaults.string(forKey: "six.assistant.anthropicKey")
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
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
            let system = SystemLanguageModel.default
            guard case .available = system.availability else {
                throw AssistantError.unavailable("On-device model is not available: \(system.availability)")
            }
            return LanguageModelSession(model: system, tools: tools, instructions: instructions)
        case .privateCloudCompute:
            let pcc = PrivateCloudComputeLanguageModel()
            guard case .available = pcc.availability else {
                throw AssistantError.unavailable("Private Cloud Compute is not available: \(pcc.availability)")
            }
            return LanguageModelSession(model: pcc, tools: tools, instructions: instructions)
        #if os(macOS)
        case .claudeSonnet, .claudeOpus:
            guard FoundationModelsCompatibility.supportsThirdPartyModels else {
                throw AssistantError.unavailable(FoundationModelsCompatibility.mismatchExplanation)
            }
            let key = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw AssistantError.missingAPIKey }
            let claude = ClaudeLanguageModel(
                name: model == .claudeOpus ? .opus5 : .sonnet5,
                auth: .apiKey(key)
            )
            return LanguageModelSession(model: claude, tools: tools, instructions: instructions)
        #endif
        }
    }
}

enum AssistantError: LocalizedError {
    case unavailable(String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .missingAPIKey: "Add an Anthropic API key in the model menu to use Claude."
        }
    }
}
