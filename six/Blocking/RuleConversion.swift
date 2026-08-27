import ContentBlockerConverter
import Foundation

/// Filter rules as publishers write them → the JSON WebKit compiles.
///
/// The syntax the whole ad-blocking world uses (`||host^$third-party`, `site.com##.banner`) is not
/// WebKit's; WebKit takes a JSON array of trigger/action pairs. AdGuard's converter is the one
/// place this translation is done properly — it is the same library behind AdGuard for Safari —
/// so six calls it rather than growing a parser of its own.
///
/// **Advanced rules are deliberately left behind.** Scriptlets and extended CSS (`:has-text()`,
/// `:xpath()`) cannot be expressed in WebKit's JSON at all; they need a JavaScript engine running
/// inside every page. Plain element hiding does convert — WebKit has `css-display-none` — so the
/// visible half of blocking is here, and the rest waits for six to have somewhere to run it.
enum RuleConversion {
    struct Result: Sendable {
        var json: String
        var sourceRules: Int
        var safariRules: Int
        /// Rules the converter understood but WebKit could not take (the 150k ceiling, mostly).
        var dropped: Int
    }

    /// Blocking on the main thread would be seconds of it; every caller is off the main actor.
    nonisolated static func safariJSON(for text: String) -> Result {
        let lines = text.components(separatedBy: .newlines)
        let converted = ContentBlockerConverter().convertArray(
            rules: lines,
            safariVersion: .autodetect(),
            advancedBlocking: false,
            maxJsonSizeBytes: nil,
            progress: nil
        )
        return Result(
            json: converted.safariRulesJSON,
            sourceRules: converted.sourceRulesCount,
            safariRules: converted.safariRulesCount,
            dropped: converted.discardedSafariRules
        )
    }
}
