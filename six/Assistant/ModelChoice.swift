import Foundation
import FoundationModels
import ClaudeForFoundationModels

/// Which `LanguageModel` backs the assistant. All of them are driven through the same `LanguageModelSession`.
enum ModelChoice: String, CaseIterable, Identifiable, Codable {
    case onDevice
    case privateCloudCompute
    case claudeSonnet
    case claudeOpus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: "On-Device"
        case .privateCloudCompute: "Private Cloud Compute"
        case .claudeSonnet: "Claude Sonnet 5"
        case .claudeOpus: "Claude Opus 5"
        }
    }

    var symbol: String {
        switch self {
        case .onDevice: "cpu"
        case .privateCloudCompute: "icloud"
        case .claudeSonnet, .claudeOpus: "sparkles"
        }
    }

    var isClaude: Bool { self == .claudeSonnet || self == .claudeOpus }
}

/// User-facing assistant settings.
@MainActor
@Observable
final class AssistantSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var model: ModelChoice {
        didSet { defaults.set(model.rawValue, forKey: "six.assistant.model") }
    }

    /// Development-only credential. For shipping, use `AuthMode.appAttest` or a proxy — never bundle a key.
    var anthropicAPIKey: String {
        didSet { defaults.set(anthropicAPIKey, forKey: "six.assistant.anthropicKey") }
    }

    init() {
        model = ModelChoice(rawValue: defaults.string(forKey: "six.assistant.model") ?? "") ?? .onDevice
        anthropicAPIKey = defaults.string(forKey: "six.assistant.anthropicKey")
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    }

    /// Builds a session for the selected model. Throws a readable error when the model isn't usable.
    func makeSession(instructions: String) throws -> LanguageModelSession {
        switch model {
        case .onDevice:
            let system = SystemLanguageModel.default
            guard case .available = system.availability else {
                throw AssistantError.unavailable("On-device model is not available: \(system.availability)")
            }
            return LanguageModelSession(model: system, instructions: instructions)
        case .privateCloudCompute:
            let pcc = PrivateCloudComputeLanguageModel()
            guard case .available = pcc.availability else {
                throw AssistantError.unavailable("Private Cloud Compute is not available: \(pcc.availability)")
            }
            return LanguageModelSession(model: pcc, instructions: instructions)
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
            return LanguageModelSession(model: claude, instructions: instructions)
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
