import CWebKitGTK
import Foundation
import SixWebKitCore

@testable internal import SixCore

/// Running JavaScript in a page, and getting an answer back.
///
/// The one thing the shared page walk needs from a web engine, and the thing this front has owed it
/// since translation was written: `TranslationSegment.swift` says as much in its own comment —
/// *"On Linux it is `webkit_web_view_call_async_javascript_function`, which `SixGtk.WebKitView` does
/// not expose yet — and will have to for highlights and the readable-page extractor too."* This is
/// that, and the readable-page extractor gets it for free.
///
/// **JSON in and JSON out**, the same bargain `RailScript` makes on Windows and for the same reason:
/// one string is a value shape both engines' bridges agree on, where a `JSCValue` graph on one side
/// and a `WKDictionary` graph on the other are a hundred lines each that buy nothing.
///
/// The argument does not travel as a `GVariant`. It could — `a{sv}` is what the function takes — but
/// building one from Swift means `g_variant_builder_add`, which is variadic and out of reach, or
/// three nested constructors. A JSON document is also a JavaScript expression, so the argument is
/// simply written into the top of the script as a string literal, which is both shorter and
/// impossible to get wrong.
final class LivePage: PageScriptRunner {
    let view: UnsafeMutablePointer<WebKitWebView>

    init(_ view: UnsafeMutablePointer<WebKitWebView>) {
        self.view = view
    }

    /// The page a column is showing, if it has one.
    static func focused(_ tabID: UUID) -> LivePage? {
        PageRegistry.page(for: tabID).map(LivePage.init)
    }

    /// `body` is an async function body; `input` is bound in it as a `String`.
    ///
    /// No timeout, deliberately, and the same note as on Windows applies: WebKit answers or the page
    /// goes away with the callback in it. A timeout would give up on a page whose engine is merely
    /// slow, which here is the common case — one batch of twenty paragraphs is seconds of Marian.
    func callAsync(_ body: String, input: String) async throws -> String {
        let script = "const input = " + Self.literal(input) + ";\n" + body
        return try await withCheckedThrowingContinuation { continuation in
            let reply = Unmanaged.passRetained(ScriptReply(view: view, continuation: continuation)).toOpaque()
            webkit_web_view_call_async_javascript_function(
                view, script, -1,
                nil,        // arguments: the one argument is in the script itself, see above
                nil,        // world: the page's own, which is where `TranslationScript` keeps its state
                nil,        // source uri: nothing points at this script
                nil,        // cancellable: a run is cancelled by its own token, not by WebKit
                { _, result, data in
                    guard let data else { return }
                    let reply = Unmanaged<ScriptReply>.fromOpaque(data).takeRetainedValue()
                    var error: UnsafeMutablePointer<GError>?
                    let value = webkit_web_view_call_async_javascript_function_finish(
                        reply.view, result, &error
                    )
                    if let error {
                        let message = String(cString: error.pointee.message)
                        g_error_free(error)
                        reply.continuation.resume(throwing: PageScriptError.javaScript(message))
                        return
                    }
                    guard let value else {
                        reply.continuation.resume(returning: "")
                        return
                    }
                    // `jsc_value_to_string` transfers the string, and the value itself came at +1.
                    let text = jsc_value_to_string(value).map { characters -> String in
                        let answer = String(cString: characters)
                        g_free(characters)
                        return answer
                    } ?? ""
                    g_object_unref(UnsafeMutableRawPointer(value))
                    reply.continuation.resume(returning: text)
                },
                reply
            )
        }
    }

    // MARK: What the shared page walk asks

    func runScript(_ body: String, arguments: [String: Any]) async throws -> Any? {
        let names = arguments.keys.sorted()
        let input = names.isEmpty
            ? "{}"
            : String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let prelude = names.isEmpty ? "" : "const { " + names.joined(separator: ", ") + " } = JSON.parse(input);\n"
        // Wrapped rather than run directly because the body is full of `return`s, and because a
        // script that returns nothing has to come back as something: `JSON.stringify(undefined)` is
        // `undefined`, not `"null"`, and that is not a value the bridge can carry.
        let wrapped = prelude
            + "const value = (function () {\n" + body + "\n})();\n"
            + "return value === undefined ? 'null' : JSON.stringify(value);"
        let text = try await callAsync(wrapped, input: input)
        guard let data = text.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// A Swift string as a JavaScript string literal, quotes and all.
    ///
    /// JSON's escaping is JavaScript's, with two exceptions that were only exceptions until ES2019:
    /// the line and paragraph separators are legal in a JavaScript string literal now, but escaping
    /// them costs nothing and the alternative is a syntax error that would only ever show up on a
    /// page that happened to contain one.
    private static func literal(_ text: String) -> String {
        let encoded = (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return encoded
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// One call in flight, kept alive across the trip through C. `@unchecked Sendable` because an opaque
/// pointer is the only thing carrying it, and it is handed straight back to the main loop that made
/// it.
private final class ScriptReply: @unchecked Sendable {
    let view: UnsafeMutablePointer<WebKitWebView>
    let continuation: CheckedContinuation<String, any Error>

    init(view: UnsafeMutablePointer<WebKitWebView>, continuation: CheckedContinuation<String, any Error>) {
        self.view = view
        self.continuation = continuation
    }
}

nonisolated enum PageScriptError: LocalizedError {
    case javaScript(String)
    case noPage

    var errorDescription: String? {
        switch self {
        case .javaScript(let message): message
        case .noPage: "the page went away"
        }
    }
}
