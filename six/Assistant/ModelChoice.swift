import Foundation
import FoundationModels

/// Which `LanguageModel` backs the assistant. All of them are driven through the same `LanguageModelSession`.
enum ModelChoice: String, CaseIterable, Identifiable, Codable {
    case onDevice
    case privateCloudCompute
    case claudeSonnet
    case claudeOpus
    /// ACP agents: the same ⌘K line, answered by Claude Code / Codex through the agent session.
    case claudeCodeAgent = "acp:claude-code"
    case codexAgent = "acp:codex"

    var id: String { rawValue }

    static let languageModels: [ModelChoice] = [.onDevice, .privateCloudCompute, .claudeSonnet, .claudeOpus]
    static let agents: [ModelChoice] = [.claudeCodeAgent, .codexAgent]

    var title: String {
        switch self {
        case .onDevice: "On-Device"
        case .privateCloudCompute: "Private Cloud Compute"
        case .claudeSonnet: "Claude Sonnet 5"
        case .claudeOpus: "Claude Opus 5"
        case .claudeCodeAgent: "Claude Code (ACP)"
        case .codexAgent: "Codex (ACP)"
        }
    }

    var symbol: String {
        switch self {
        case .onDevice: "cpu"
        case .privateCloudCompute: "icloud"
        case .claudeSonnet, .claudeOpus: "sparkles"
        case .claudeCodeAgent, .codexAgent: "terminal"
        }
    }

    var isClaude: Bool { self == .claudeSonnet || self == .claudeOpus }

    /// The ACP agent behind this choice, if it is one.
    var agentDefinition: ACPAgentDefinition? {
        switch self {
        case .claudeCodeAgent: .claudeCode
        case .codexAgent: .codex
        default: nil
        }
    }
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
        case .claudeCodeAgent, .codexAgent:
            throw AssistantError.unavailable("\(model.title) is an agent, not a language model")
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
