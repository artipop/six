import Foundation

/// What a person allowed on an agent's card for the tools that are asked about on every call
/// (`BrowserTool.asksEveryCall`): each answer covers the one call it was given for.
@MainActor
final class ToolConsent {
    private struct Answer {
        var tool: String
        var arguments: ACPJSON
        var at: Date
    }

    /// The call follows its card at once; an answer nobody used is not kept for a later one.
    private static let life: TimeInterval = 30

    private var answers: [Answer] = []
    var asksEveryCall: (String) -> Bool = { _ in false }

    func allowed(_ tool: String, arguments: ACPJSON?) {
        guard let arguments else { return }
        answers.append(Answer(tool: tool, arguments: arguments, at: Date()))
    }

    /// Whether this very call was allowed on a card; true once.
    func take(_ tool: String, arguments: ACPJSON) -> Bool {
        answers.removeAll { Date().timeIntervalSince($0.at) > Self.life }
        guard let index = answers.firstIndex(where: { $0.tool == tool && $0.arguments == arguments }) else { return false }
        answers.remove(at: index)
        return true
    }
}
