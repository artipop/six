import Foundation

/// A page six owns, that nobody can see, and that runs whatever six asks it to.
///
/// The seam exists because of a shape that keeps recurring off the Mac: something six wants to run
/// is not a library it can link, it is a program written for a JavaScript engine — and every front
/// here already ships one, in its own process, with its own heap. Bergamot is five megabytes of
/// Marian compiled to wasm; an on-device sentence embedder is the same bargain. Rather than a
/// dependency and a build per front, six opens a page of its own, off screen, and talks to it.
///
/// Two methods, and neither is invented for this: opening a local page and calling a function in
/// one are what the page walk in `TranslationScript` and the readable-page extractor need anyway.
/// What a front has to write is `WKPageCallAsyncJavaScript` or
/// `webkit_web_view_call_async_javascript_function` and the conversion around it — four lines and a
/// continuation each.
///
/// JSON in, JSON out, deliberately. It is the one value shape every engine's script bridge agrees
/// on: WebKit's Windows C API hands back an object graph of `WKString`/`WKNumber`/`WKDictionary`,
/// WebKitGTK hands back a `JSCValue`, and walking either into Swift values is work that buys
/// nothing when both can serialise a string.
///
/// The separate process is a feature and not an accident. Marian's decoder blocks the thread it
/// runs on for as long as a sentence takes; on the browser's own main thread that is a stutter per
/// batch, and in a web process holding one 1 × 1 page it is nothing at all.
@MainActor
protocol PageSandbox: AnyObject {
    /// Load this local page and return once its document is ready. Called once per launch.
    func open(_ url: URL) async throws

    /// Run `body` as the body of an async function in the page, with `input` bound to the JSON text
    /// given, and hand back what it returned — as JSON text.
    func call(_ body: String, input: String) async throws -> String
}
