import CWebKit2
import Foundation
@testable import SixCore
import WinSDK

/// Running JavaScript in a page, and getting an answer back.
///
/// This is the one thing every remaining feature on this front needs and none of it had: the page
/// walk translation does, the readable-page extractor, highlights, the assistant's `get_selection`.
/// `WKPageCallAsyncJavaScript` is WebKit's own `callAsyncJavaScript` — a function *body*, named
/// arguments, and a promise the caller waits on — so what is written here is the conversion around
/// it and nothing else.
///
/// **JSON in and JSON out, deliberately.** The C API hands the result back as an object graph of
/// `WKString`, `WKNumber`, `WKArray` and `WKDictionary`, and walking that into Swift values would
/// be a hundred lines that buy nothing: the scripts on the other side are `JSON.stringify`-shaped
/// already, and so is `webkit_web_view_call_async_javascript_function`'s `JSCValue` on the Linux
/// front. One argument goes in, named `input`, carrying the arguments as JSON text; one string
/// comes back. `PageSandbox` is the same bargain for the same reason.
extension RailWebView {
    /// `body` is an async function body. `input` is bound in it as a `String`.
    ///
    /// There is no timeout, and that is a known edge rather than an oversight: WebKit answers or the
    /// page goes away, and a page going away tears its process down with the callback in it. What
    /// that costs is one leaked continuation for the life of the process; what a timeout would cost
    /// is a translation that gives up on a page whose engine is merely slow, which is the common
    /// case here — a batch of twenty paragraphs is seconds of Marian.
    func callAsync(_ body: String, input: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard let script = Self.wkString(body), let key = Self.wkString("input"),
                  let value = Self.wkString(input), let arguments = WKMutableDictionaryCreate()
            else {
                continuation.resume(throwing: RailScriptError.noPage)
                return
            }
            WKDictionarySetItem(arguments, key, UnsafeRawPointer(value))
            // Every one of these came back at +1, and none of them is wanted after the call: WebKit
            // copies what it needs out of them synchronously.
            defer {
                WKRelease(UnsafeRawPointer(script))
                WKRelease(UnsafeRawPointer(key))
                WKRelease(UnsafeRawPointer(value))
                WKRelease(UnsafeRawPointer(arguments))
            }

            // The continuation travels to the callback as an opaque pointer, the way every other
            // "client info" in this file does — a C function pointer has no captures. Retained here
            // and consumed there, exactly once, because WebKit calls the callback exactly once.
            let reply = Unmanaged.passRetained(ScriptReply(continuation)).toOpaque()
            // `nil` for the frame is the main frame, which is the only one anything here talks to.
            WKPageCallAsyncJavaScript(page, script, arguments, nil, reply) { result, error, context in
                guard let context else { return }
                let reply = Unmanaged<ScriptReply>.fromOpaque(context).takeRetainedValue()
                if let error {
                    reply.resume(throwing: RailScriptError.javaScript(
                        RailWebView.string(from: WKErrorCopyLocalizedDescription(error))))
                    return
                }
                guard let result, WKGetTypeID(result) == WKStringGetTypeID() else {
                    // Anything that is not a string is a script that returned nothing, which is
                    // what `undefined` serialises to on the way out.
                    reply.resume(returning: "")
                    return
                }
                reply.resume(returning: RailWebView.string(from: OpaquePointer(result)))
            }
        }
    }

    /// A `WKStringRef` at +1. Every caller releases what it made.
    static func wkString(_ text: String) -> WKStringRef? {
        text.withCString { WKStringCreateWithUTF8CString($0) }
    }
}

/// One in-flight script call. A class because it has to survive as a pointer through C, and
/// `@unchecked Sendable` because that pointer is the only thing that carries it.
private final class ScriptReply: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, any Error>?

    init(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: String) {
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

nonisolated enum RailScriptError: LocalizedError {
    case javaScript(String)
    case noPage

    var errorDescription: String? {
        switch self {
        case .javaScript(let message): message
        case .noPage: "the page went away"
        }
    }
}

/// What the shared page walk asks of a web engine, answered here.
///
/// The body it hands over is a plain function body with named free variables — `budget`, `list`,
/// `lang` — so the wrapper below destructures them out of the one JSON argument and stringifies
/// whatever the body returns. `TranslationScript` is then the same text on this front as on the
/// Mac, which is the whole point of it being in `SixCore`.
extension RailWebView: PageScriptRunner {
    func runScript(_ body: String, arguments: [String: Any]) async throws -> Any? {
        let names = arguments.keys.sorted()
        let input = names.isEmpty
            ? "{}"
            : String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let prelude = names.isEmpty ? "" : "const { \(names.joined(separator: ", ")) } = JSON.parse(input);\n"
        // The body is wrapped rather than run directly because it is full of `return`s, and because
        // a script that returns nothing has to come back as something: `JSON.stringify(undefined)`
        // is `undefined`, not `"null"`, and that is a value the bridge cannot carry.
        let wrapped = prelude
            + "const value = (function () {\n" + body + "\n})();\n"
            + "return value === undefined ? 'null' : JSON.stringify(value);"
        let text = try await callAsync(wrapped, input: input)
        guard let data = text.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
