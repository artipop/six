#if canImport(WebKit)
import Foundation
import NaturalLanguage
import WebKit

/// Where the portable half of translation meets this platform.
///
/// Three small things, and each is the reason a seam exists at all: running a script in a page,
/// deciding what language the page is in, and remembering the choice.

// MARK: Running a script

extension BrowserTab: PageScriptRunner {
    /// `livePage`, deliberately, and **not** `page`.
    ///
    /// The house rule is that anything talking to the page uses `tab.page`, which materialises it.
    /// That is right for a click and wrong for the loop that follows a feed: waking a discarded
    /// window in the background is exactly what `LivePageCache` exists to prevent. A caller that
    /// needs the page alive has touched `tab.page` already, because the person was looking at it.
    func runScript(_ functionBody: String, arguments: [String: Any] = [:]) async throws -> Any? {
        guard let page = livePage else { throw CancellationError() }
        return try await page.six(functionBody, arguments: arguments)
    }
}

// MARK: What language is this?

enum TranslationLanguage {
    /// The page's own claim first, a detector second.
    ///
    /// `<html lang>` is right often enough to try and wrong often enough to check: a Russian article
    /// on a site whose template says `lang="en"` is an ordinary thing on the web. So a claim that
    /// disagrees with the text loses — the text is what the reader is looking at.
    static func source(of plan: TranslationPlan) -> Locale.Language? {
        let detected = detect(plan.sample)
        let claimed = plan.language.isEmpty ? nil : Locale.Language(identifier: plan.language)

        switch (claimed, detected) {
        case (let claimed?, nil):
            return claimed
        case (nil, let detected?):
            return detected
        case (let claimed?, let detected?):
            return claimed.languageCode == detected.languageCode ? claimed : detected
        case (nil, nil):
            return nil
        }
    }

    /// `NLLanguageRecognizer` is the same one `Embedder.language(of:)` uses for bookmarks.
    static func detect(_ text: String) -> Locale.Language? {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 40 else { return nil }    // below that it guesses, confidently
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(2000)))
        guard let dominant = recognizer.dominantLanguage, dominant != .undetermined else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    static var unreadable: String {
        String(localized: "There is nothing on this page to translate yet — try again once it has loaded")
    }

    static var noSelection: String {
        String(localized: "Select some text on the page first")
    }

    static var undetected: String {
        String(localized: "Could not tell what language this page is in")
    }

    static func alreadyInTarget(_ language: String) -> String {
        String(localized: "This page is already in \(language)")
    }

    /// Is this page worth offering to translate at all?
    static func isForeign(_ source: Locale.Language, to target: Locale.Language) -> Bool {
        source.languageCode != nil && source.languageCode != target.languageCode
    }
}

// MARK: The settings

/// The setting lives in the settings table; the knowledge of what its string means lives here,
/// beside the type it means it as. `SettingsStore` itself keeps only keys and strings.
extension SettingsStore {
    /// What to translate into. Defaults to the language the interface is in.
    var translationTarget: Locale.Language {
        get {
            guard let stored = self[.translationTarget], !stored.isEmpty else {
                return Locale.current.language
            }
            return Locale.Language(identifier: stored)
        }
        set { self[.translationTarget] = newValue.languageCode?.identifier ?? "" }
    }

    /// Which engine turns the words around.
    var translationEngine: TranslationEngineChoice {
        get { TranslationEngineChoice(rawValue: self[.translationEngine] ?? "") ?? .system }
        set { self[.translationEngine] = newValue.rawValue }
    }

    /// Sites translated without being asked.
    var alwaysTranslateHosts: [String] {
        get { decode(.translationHosts) ?? [] }
        set { encode(.translationHosts, newValue, keepingEmpty: false) }
    }
}
#endif
