import Foundation
import WebKit

/// The Swift half of the acting tools: running `PageActionScript` against a window's page, waiting
/// for the page to settle after an action, and writing a snapshot out for a model.
///
/// Every action answers with the snapshot taken after it, the way Playwright's MCP server does: the
/// next thing an agent needs after a click is always to look again, and one round trip is cheaper
/// than two — for an LLM agent that is the whole cost of a step.
@MainActor
enum PageActions {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    nonisolated static let defaultMaxElements = 250
    nonisolated static let defaultTextLimit = 3000

    static func snapshot(_ page: WebPage, maxElements: Int = defaultMaxElements, textLimit: Int = defaultTextLimit) async throws -> [String: Any] {
        let value = try await page.six(PageActionScript.snapshot, arguments: ["maxElements": maxElements, "textLimit": textLimit])
        guard let snapshot = value as? [String: Any] else { throw Failure(message: "The page returned no snapshot; it may still be navigating — try again") }
        return snapshot
    }

    /// Runs one action script and turns the page's own refusal (`{error, detail}`) into a failure the
    /// model reads. A script interrupted by the navigation it caused is a success: the click landed.
    static func run(_ page: WebPage, _ script: String, arguments: [String: Any]) async throws -> [String: Any] {
        let value: Any?
        do {
            value = try await page.six(script, arguments: arguments)
        } catch {
            return ["ok": true, "note": "the page navigated while the action ran"]
        }
        guard let result = value as? [String: Any] else { return ["ok": true] }
        if let error = result["error"] as? String {
            let detail = result["detail"] as? String ?? error
            throw Failure(message: error == "stale" ? "\(detail); take a new page_snapshot and use its refs" : detail)
        }
        return result
    }

    /// After an action: through any navigation it started, then until the DOM stops changing — two
    /// reads 100 ms apart that agree — bounded, because some pages never stop (a clock, a carousel).
    static func settle(_ tab: BrowserTab, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(120))
        var last = ""
        var agreeing = 0
        while Date() < deadline {
            if tab.isLoading {
                agreeing = 0
            } else if let now = try? await tab.page.six(PageActionScript.settle) as? [Any] {
                let key = now.map { "\($0)" }.joined(separator: "|")
                agreeing = key == last && now.count > 1 && (now[1] as? String) == "complete" ? agreeing + 1 : 0
                last = key
                if agreeing >= 2 { return }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Polls for text to appear on the rendered page. True when it did.
    static func wait(for text: String, in tab: BrowserTab, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !tab.isLoading, (try? await tab.page.six(PageActionScript.hasText, arguments: ["text": text])) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    // MARK: Writing it out

    static func json(_ snapshot: [String: Any], window: String) -> String {
        var object = snapshot
        object["window_id"] = window
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One line per element, in reading order, with the ones off screen grouped after a divider so a
    /// model sees what it can act on now before what needs a scroll (actions scroll by themselves).
    static func outline(_ snapshot: [String: Any], header: String) -> String {
        var lines = [header]
        let viewport = snapshot["viewport"] as? [Int] ?? []
        let scroll = snapshot["scroll"] as? [Int] ?? []
        var status = viewport.count == 2 ? "Viewport \(viewport[0])×\(viewport[1])" : "Viewport ?"
        if scroll.count == 2, let height = snapshot["pageHeight"] as? Int { status += ", scrolled to \(scroll[1]) of \(height)" }
        if let focused = snapshot["focused"] as? String { status += ". Focused: \(focused)" }
        if let ready = snapshot["readyState"] as? String, ready != "complete" { status += ". Still loading (\(ready))" }
        lines.append(status + ".")
        if let dialog = snapshot["dialog"] as? String {
            lines.append("A dialog is open: \"\(dialog)\" — it may cover the page behind it.")
        }
        let elements = snapshot["elements"] as? [[String: Any]] ?? []
        let visible = elements.filter { ($0["where"] as? String) == "visible" }
        let offscreen = elements.filter { ($0["where"] as? String) != "visible" }
        lines.append("")
        lines += visible.map(line)
        if !offscreen.isEmpty {
            lines.append("— off screen (actions scroll to them) —")
            lines += offscreen.map(line)
        }
        if elements.isEmpty { lines.append("(no interactive elements)") }
        if let omitted = snapshot["omitted"] as? Int, omitted > 0 {
            lines.append("… \(omitted) more not listed; raise max_elements or scroll")
        }
        if let text = snapshot["text"] as? String, !text.isEmpty {
            lines.append("")
            lines.append("Visible text:")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ element: [String: Any]) -> String {
        let ref = element["ref"] as? String ?? "?"
        let role = element["role"] as? String ?? "element"
        let name = element["name"] as? String ?? ""
        var text = "[\(ref)] \(role)"
        if !name.isEmpty { text += " \"\(name.count > 120 ? String(name.prefix(117)) + "…" : name)\"" }
        if let type = element["type"] as? String, !["text", "search"].contains(type) { text += " type=\(type)" }
        if let value = element["value"] as? String {
            text += value.isEmpty ? " (empty)" : " = \"\(value.count > 80 ? String(value.prefix(77)) + "…" : value)\""
        }
        if let placeholder = element["placeholder"] as? String { text += " placeholder=\"\(placeholder)\"" }
        for key in ["checked", "selected", "expanded", "pressed"] {
            if let flag = element[key] as? Bool { text += " \(key)=\(flag)" }
            else if let flag = element[key] as? String { text += " \(key)=\(flag)" }
        }
        if element["required"] as? Bool == true { text += " required" }
        if element["invalid"] as? Bool == true { text += " invalid" }
        if element["disabled"] as? Bool == true { text += " disabled" }
        if let options = element["options"] as? [String] {
            text += " options: " + options.joined(separator: " | ")
            if let more = element["moreOptions"] as? Int { text += " | … \(more) more" }
        }
        if let context = element["context"] as? String, !context.isEmpty { text += " in \"\(context)\"" }
        if let href = element["href"] as? String, role == "link" { text += " → \(href.count > 100 ? String(href.prefix(97)) + "…" : href)" }
        return text
    }
}
