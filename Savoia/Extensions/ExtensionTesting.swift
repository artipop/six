import Foundation
import WebKit

/// `SAVOIA_EXTENSION_TESTING=1`: WebKit's own `browser.test` for the extensions, its verdicts in the log.
enum ExtensionTesting {
    static let isOn = ProcessInfo.processInfo.environment["SAVOIA_EXTENSION_TESTING"] != nil

    static func prepare(_ controller: WKWebExtensionController) {
        guard isOn, controller.responds(to: Selector(("_setTestingMode:"))) else { return }
        controller.setValue(true, forKey: "testingMode")
    }
}

/// The private half of the delegate, which WebKit calls only in testing mode.
extension ExtensionDelegate {
    private func record(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        store?.log("test " + String(decoding: data, as: UTF8.self))
    }

    @objc(_webExtensionController:recordTestAssertionResult:withMessage:andSourceURL:lineNumber:)
    func testAssertion(_ controller: WKWebExtensionController, result: Bool, message: String, source: String, line: UInt32) {
        record(["kind": "assert", "result": result, "message": message, "line": line])
    }

    @objc(_webExtensionController:recordTestEqualityResult:expectedValue:actualValue:withMessage:andSourceURL:lineNumber:)
    func testEquality(_ controller: WKWebExtensionController, result: Bool, expected: String, actual: String, message: String, source: String, line: UInt32) {
        record(["kind": "equal", "result": result, "expected": expected, "actual": actual, "message": message, "line": line])
    }

    @objc(_webExtensionController:logTestMessage:andSourceURL:lineNumber:)
    func testLog(_ controller: WKWebExtensionController, message: String, source: String, line: UInt32) {
        record(["kind": "log", "message": message, "line": line])
    }

    @objc(_webExtensionController:recordTestAddedWithName:andSourceURL:lineNumber:)
    func testAdded(_ controller: WKWebExtensionController, name: String, source: String, line: UInt32) {
        record(["kind": "added", "name": name])
    }

    @objc(_webExtensionController:recordTestStartedWithName:andSourceURL:lineNumber:)
    func testStarted(_ controller: WKWebExtensionController, name: String, source: String, line: UInt32) {
        record(["kind": "started", "name": name])
    }

    @objc(_webExtensionController:recordTestFinishedWithName:result:message:andSourceURL:lineNumber:)
    func testFinished(_ controller: WKWebExtensionController, name: String, result: Bool, message: String, source: String, line: UInt32) {
        record(["kind": "finished", "name": name, "result": result, "message": message])
    }
}
