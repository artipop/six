import Foundation

/// Model choices returned by ACP session setup. Prefer config options, with support for older adapters.
nonisolated struct AgentModels: Equatable, Sendable {
    struct Model: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
    }

    var choices: [Model]
    var current: String
    var configID: String?

    init(configOptions: [ACPJSON]?, models: ACPJSON?) {
        if let option = configOptions?.first(where: {
            $0["type"]?.stringValue == "select"
                && ($0["category"]?.stringValue == "model" || $0["id"]?.stringValue == "model")
        }) {
            configID = option["id"]?.stringValue
            current = option["currentValue"]?.stringValue ?? ""
            choices = Self.options(option["options"]?.arrayValue ?? [])
        } else {
            configID = nil
            current = models?["currentModelId"]?.stringValue ?? ""
            choices = (models?["availableModels"]?.arrayValue ?? []).compactMap {
                guard let id = $0["modelId"]?.stringValue else { return nil }
                return Model(id: id, name: $0["name"]?.stringValue ?? id)
            }
        }
        var seen = Set<String>()
        choices = choices.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    private static func options(_ values: [ACPJSON]) -> [Model] {
        values.flatMap { value -> [Model] in
            if let group = value["options"]?.arrayValue { return options(group) }
            guard let id = value["value"]?.stringValue else { return [] }
            return [Model(id: id, name: value["name"]?.stringValue ?? id)]
        }
    }
}
