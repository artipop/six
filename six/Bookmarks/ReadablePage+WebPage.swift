import Foundation
import WebKit

/// The Mac's way into `ReadablePage`, kept out of `SixCore` because `WebPage.six` — six's own content
/// world — is the app's. `BookmarkStore` reads through this twice: the window's page when a star is
/// pressed, and an off-screen `WebPage` when a bookmark is refreshed, which is not a `BrowserTab`
/// and so not a `PageScriptRunner`.
extension ReadablePage {
    @MainActor
    static func extract(from page: WebPage) async throws -> ReadablePage {
        try decode(try await page.six(script))
    }
}
