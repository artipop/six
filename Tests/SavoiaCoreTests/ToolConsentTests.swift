import Foundation
import Testing
@testable import SavoiaCore

@MainActor
struct ToolConsentTests {
    @Test func anAnswerCoversOneCallWithTheSameArguments() {
        let consent = ToolConsent()
        consent.allowed("upload_file", arguments: ["path": "/tmp/a.txt", "ref": "e1"])
        #expect(!consent.take("upload_file", arguments: ["path": "/tmp/b.txt", "ref": "e1"]))
        #expect(!consent.take("click", arguments: ["path": "/tmp/a.txt", "ref": "e1"]))
        #expect(consent.take("upload_file", arguments: ["path": "/tmp/a.txt", "ref": "e1"]))
        #expect(!consent.take("upload_file", arguments: ["path": "/tmp/a.txt", "ref": "e1"]))
    }

    @Test func aCardWithoutArgumentsAllowsNothing() {
        let consent = ToolConsent()
        consent.allowed("upload_file", arguments: nil)
        #expect(!consent.take("upload_file", arguments: [:]))
    }

    @Test func onlyTheServersOwnToolIsNamed() {
        #expect(AgentToolName.tool("mcp__savoia__upload_file", of: "savoia") == "upload_file")
        #expect(AgentToolName.tool("mcp__other__upload_file", of: "savoia") == nil)
        #expect(AgentToolName.tool("Run mcp__savoia__upload_file", of: "savoia") == nil)
        #expect(AgentToolName.tool("mcp__savoia__", of: "savoia") == nil)
    }
}
