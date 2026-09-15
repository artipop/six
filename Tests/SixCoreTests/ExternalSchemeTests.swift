import Foundation
import Testing

@testable import SixCore

/// Which addresses a window of six's shows, and which are handed to somebody else's app — asked of
/// every navigation on Windows, where the answer decides whether a page may start another program.
@MainActor
struct ExternalSchemeTests {
    @Test func whatAWindowShowsIsNotExternal() {
        for address in ["https://example.com", "http://localhost:8080", "file:///C:/x.html", "about:blank",
                        "data:text/plain,hi", "blob:https://example.com/1", "six://settings",
                        "mcp-app://tool/", "mcp-app-content://tool/"] {
            #expect(!ExternalScheme.isExternal(URL(string: address)!), "\(address)")
        }
    }

    @Test func somebodyElsesSchemesAre() {
        for address in ["mailto:someone@example.com", "tel:+100", "magnet:?xt=urn:btih:0",
                        "ms-settings:display", "search-ms:query=x", "zoommtg://join"] {
            #expect(ExternalScheme.isExternal(URL(string: address)!), "\(address)")
        }
    }

    @Test func theSchemeIsReadWithoutRegardToCase() {
        #expect(!ExternalScheme.isExternal(URL(string: "HTTPS://example.com")!))
        #expect(ExternalScheme.isExternal(URL(string: "MAILTO:x@example.com")!))
    }

    @Test func anAddressWithNoSchemeIsNotHandedAnywhere() {
        #expect(!ExternalScheme.isExternal(URL(string: "example.com/path")!))
    }
}
