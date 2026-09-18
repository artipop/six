import Foundation
import Testing
@testable import SixCore

struct AgentModelsTests {
    private func json(_ value: String) throws -> ACPJSON {
        try JSONDecoder().decode(ACPJSON.self, from: Data(value.utf8))
    }

    @Test func prefersModelConfigOptionOverLegacyList() throws {
        let response = try json("""
        {"configOptions":[
            {"id":"mode","type":"select","currentValue":"ask","options":[{"value":"ask","name":"Ask"}]},
            {"id":"agent-model","category":"model","type":"select","currentValue":"account/model-b",
             "options":[{"value":"account/model-a","name":"Model A"},{"value":"account/model-b","name":"Model B"}]}
        ],"models":{"currentModelId":"old","availableModels":[{"modelId":"old","name":"Old"}]}}
        """)
        let models = AgentModels(configOptions: response["configOptions"]?.arrayValue, models: response["models"])
        #expect(models.configID == "agent-model")
        #expect(models.current == "account/model-b")
        #expect(models.choices.map(\.id) == ["account/model-a", "account/model-b"])
    }

    @Test func readsLegacyModelsAndKeepsTheirWireIdentifiers() throws {
        let models = AgentModels(configOptions: nil, models: try json("""
        {"currentModelId":"model/high","availableModels":[
            {"modelId":"model/high","name":"Model (high)"},
            {"modelId":"model/low","name":"Model (low)"}
        ]}
        """))
        #expect(models.configID == nil)
        #expect(models.current == "model/high")
        #expect(models.choices.map(\.id) == ["model/high", "model/low"])
    }

    @Test func flattensGroupsAndIgnoresDuplicatesAndMalformedOptions() throws {
        let options = try json("""
        [{"id":"model","type":"select","currentValue":"a","options":[
            {"group":"Provider","options":[{"value":"a","name":"A"},{"value":"b","name":"B"}]},
            {"value":"a","name":"Duplicate"},{"name":"No ID"},{"value":""}
        ]}]
        """)
        let models = AgentModels(configOptions: options.arrayValue, models: nil)
        #expect(models.choices.map(\.id) == ["a", "b"])
    }

    @Test func unrelatedOptionsDoNotSuppressLegacyModels() throws {
        let options = try json("""
        [{"id":"mode","category":"mode","type":"select","currentValue":"ask","options":[]}]
        """)
        let models = AgentModels(configOptions: options.arrayValue,
                                 models: try json(#"{"availableModels":[{"modelId":"a"}]}"#))
        #expect(models.choices == [.init(id: "a", name: "a")])
        #expect(AgentModels(configOptions: nil, models: nil).choices.isEmpty)
    }
}
