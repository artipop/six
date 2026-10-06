import Foundation
import WebKit

/// The Mac's way into `ReadablePage`, for a web view that is no tab's and so not a `PageScriptRunner`.
extension ReadablePage {
    @MainActor
    static func extract(from page: WKWebView) async throws -> ReadablePage {
        try decode(try await page.savoia(script))
    }
}
