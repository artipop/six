import Foundation
import SixBrowser

@testable import SixCore

/// The page the bookmark embedder runs in, handed to the model that needs it.
///
/// A second `RailSandbox`, not a share of the translator's. The two hold different programs and
/// different weights — Bergamot is forty megabytes of wasm heap, E5 about a hundred and fifty — and
/// nothing about either is improved by putting both in one document: a reader who never translates
/// anything should not have Marian in memory because they saved a page, and a reader who never
/// saves one should not have E5 in memory because they translated. Two off-screen web processes,
/// each made on first use, is what the seam was for.
///
/// Made lazily for that reason, and touched exactly once, from `create`: the model needs the
/// sandbox before the first bookmark, and there is no window to hang an off-screen page on until
/// then.
@MainActor
final class RailEmbedding {
    private let sandbox = RailSandbox()

    /// Gives `RailModel` the two calls it needs and nothing else. The closures hold the sandbox, so
    /// this object exists for as long as the model is willing to embed.
    init(model: RailModel) {
        model.attachSandbox(
            open: { [sandbox] url in try await sandbox.open(url) },
            call: { [sandbox] body, input in try await sandbox.call(body, input: input) }
        )
    }
}

extension RailWindow {
    /// The star and `Ctrl+D`: save the page on screen, and hand the model the page itself so the
    /// bookmark is its text and not only its title. Weakly, because the reading happens a moment
    /// after the click and a column closed in that moment should not be kept alive for it.
    func bookmarkFocusedPage() {
        guard let view = focusedWebView else {
            model.toggleFocusedPageBookmark()
            return
        }
        model.toggleFocusedPageBookmark(runScript: { [weak view] body, arguments in
            guard let view else { throw RailScriptError.noPage }
            return try await view.runScript(body, arguments: arguments)
        })
    }
}
