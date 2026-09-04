import ContentBlockerConverter
import Foundation

/// Filter rules as publishers write them → the JSON WebKit compiles, and the rest.
///
/// The syntax the whole ad-blocking world uses (`||host^$third-party`, `site.com##.banner`) is not
/// WebKit's; WebKit takes a JSON array of trigger/action pairs. AdGuard's converter is the one
/// place this translation is done properly — it is the same library behind AdGuard for Safari —
/// so six calls it rather than growing a parser of its own.
///
/// The conversion has **two outputs**, and six now takes both. `safariRulesJSON` is what the
/// network layer enforces on its own. `advancedRulesText` is what WebKit's JSON cannot express at
/// all — scriptlets, extended CSS, CSS injection — handed back as AdGuard rules for someone with a
/// JavaScript engine to run. six has one, in a content world of its own; that is `AdvancedRules`.
enum RuleConversion {
    struct Result: Sendable {
        var json: String
        /// The rules WebKit cannot take, in AdGuard syntax, for `AdvancedRules` to index.
        var advanced: String?
        var sourceRules: Int
        var safariRules: Int
        var advancedRules: Int
        /// Rules the converter understood but WebKit could not take (the 150k ceiling, mostly).
        var dropped: Int
    }

    /// Blocking on the main thread would be seconds of it; every caller is off the main actor.
    nonisolated static func safariJSON(for text: String) -> Result {
        // The converter parses `UTF8View` throughout, and a non-contiguous string makes it convert
        // the whole list first. A file just read from disk is usually contiguous already, in which
        // case this costs nothing.
        var text = text
        text.makeContiguousUTF8()
        let lines = text.components(separatedBy: .newlines)
        let converted = ContentBlockerConverter().convertArray(
            rules: lines,
            safariVersion: .autodetect(),
            advancedBlocking: true,
            maxJsonSizeBytes: nil,
            progress: nil
        )
        return Result(
            json: converted.safariRulesJSON,
            advanced: converted.advancedRulesText,
            sourceRules: converted.sourceRulesCount,
            safariRules: converted.safariRulesCount,
            advancedRules: converted.advancedRulesCount,
            dropped: converted.discardedSafariRules
        )
    }
}
