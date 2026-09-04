import ContentBlockerConverter
import FilterEngine
import Foundation
import JavaScriptCore
import WebKit

/// The half of a filter list WebKit's JSON cannot hold.
///
/// `RuleConversion` produces two things. One is the content-blocker JSON the network layer
/// enforces on its own, which is most of a list and all of what it costs nothing to run. The other
/// — about 12 000 rules of AdGuard Base alone — is everything that needs a JavaScript engine
/// inside the page: **scriptlets** (`example.com#%#//scriptlet('set-constant', 'flag', 'false')`),
/// **extended CSS** (`:has-text()`, `:contains()`, `:xpath()`, whose selectors no CSS engine
/// knows), and **CSS injection** (`#$#.ad { height: 0 !important; }`, where WebKit's JSON can only
/// say `display: none`). Anti-adblock circumvention is almost entirely the first of those, which is
/// why it arrives with this and could not have arrived before it.
///
/// Three pieces, and the reason each is where it is:
///
/// - **The lookup is AdGuard's `FilterEngine`**, from the same package as the converter. Answering
///   "which of 12 000 rules apply to this URL" is a domain index, a public-suffix comparison and a
///   pile of `$domain`/`$path` exception logic; it ships in the library, it is the code AdGuard's
///   own Safari extension runs, and it serialises to a binary that deserialises in a few
///   milliseconds instead of parsing the rules again at every launch.
/// - **Scriptlets are compiled in the app, not in the page.** AdGuard's scriptlet library is a
///   compiler: `invoke({name, args})` hands back the source of one scriptlet. Running it inside
///   every page would mean 350 KB of library per page load; running it here, in JavaScriptCore,
///   means a page carries only the few kilobytes that came out. It also means the result can be a
///   `WKUserScript` at document start — ahead of the page's own scripts, which is the only moment
///   at which a scriptlet that patches a global is any use, and out of reach of a
///   Content-Security-Policy that would have refused an injected `<script>`.
/// - **Extended CSS runs in six's own content world** (`WKContentWorld.six`), like everything else
///   six puts in a page: the site cannot see the library, cannot replace the DOM methods it
///   matches with, and cannot find the style element by looking for one it did not create.
///
/// **One engine over every list, which is the one place this is better than WebKit's own rules.**
/// `WKContentRuleList`s are evaluated separately, so an exception in one list cannot undo a block
/// from another (which is what forces a controller per window, see `ContentBlocker`). The advanced
/// rules of every enabled list go into a single engine, so `@@||example.com^$elemhide` written in
/// one list does cancel a cosmetic rule from another, exactly as the filter authors intend.
@MainActor
final class AdvancedRules {
    /// What applies to one page, ready to be handed to it.
    struct PageRules: Equatable {
        /// CSS rules and bare selectors, applied through the CSSOM in six's world.
        var css: [String] = []
        /// The same, but matched by AdGuard's ExtendedCss rather than by WebKit.
        var extendedCSS: [String] = []
        /// Scriptlets and `#%#` scripts, already compiled to the JavaScript that will run.
        var scripts: [String] = []

        var isEmpty: Bool { css.isEmpty && extendedCSS.isEmpty && scripts.isEmpty }
        var count: Int { css.count + extendedCSS.count + scripts.count }
    }

    /// The engine, once it has been built. Nil until the first build finishes — a launch answers
    /// no rules for a second or two rather than holding a navigation up, which is the same bargain
    /// the compiled rule lists make.
    private var webExtension: WebExtension?
    private var context: JSContext?
    /// name+args → the scriptlet's source. A page's scriptlets repeat across sites constantly
    /// (`set-constant`, `prevent-setTimeout`), so this is nearly always a hit after the first page.
    private var compiledScriptlets: [String: String] = [:]
    private var lookups: [String: PageRules] = [:]
    /// How many rules the engine was built from — what the panel and the log say.
    private(set) var ruleCount = 0

    /// Where the engine's binaries live: `WebExtension` puts them in a `.webext` folder of its own
    /// under this one, beside the lists they were built from.
    private static var containerURL: URL { FilterListStore.folder }

    // MARK: Building

    /// Builds the engine from the advanced rules of every enabled list, concatenated.
    ///
    /// The build is a parse of ~12 000 rules, an index and a write — the better part of a second,
    /// so it happens on a detached task against a `WebExtension` of its own. The instance used for
    /// lookups notices through the timestamp in the meta file (which is what that file is for) and
    /// deserialises the new engine the next time it is asked, so nothing has to be handed back.
    func rebuild(from rules: String) async {
        ruleCount = rules.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }
            .count
        lookups.removeAll()
        guard ruleCount > 0 else {
            webExtension = nil
            ContentBlocker.log("no advanced rules — nothing runs in the page")
            return
        }

        let container = Self.containerURL
        let started = ContinuousClock.now
        let built = await Task.detached(priority: .utility) { () -> Bool in
            do {
                let webExtension = try WebExtension(containerURL: container)
                _ = try webExtension.buildFilterEngine(rules: rules)
                return true
            } catch {
                ContentBlocker.log("advanced rules failed to build: \(error)")
                return false
            }
        }.value
        guard built else { webExtension = nil; return }

        webExtension = try? WebExtension(containerURL: container)
        // Deserialising the index is the one slow lookup; spending it here keeps it out of the
        // first navigation that needs rules.
        _ = webExtension?.lookup(pageUrl: URL(string: "https://example.org/")!, topUrl: nil)
        ContentBlocker.log("advanced rules ready: \(ruleCount) rules in \(started.duration(to: .now))")
    }

    /// The engine is only as good as the library that runs what it finds: a scriptlet the JS
    /// library does not know by that name is a rule that silently does nothing. The converter
    /// states which versions its output was written for, and `scripts/blocking-payload.sh` writes
    /// the ones it bundled next to the payload — so the two can be compared rather than trusted.
    static func checkPayloadVersions() {
        guard let url = Bundle.main.url(forResource: "blocking-versions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundled = try? JSONDecoder().decode([String: String].self, from: data) else {
            log("blocking-versions.json is missing — the JavaScript half of blocking is not in the bundle")
            return
        }
        let expected = [
            "library": ContentBlockerConverterVersion.library,
            "scriptlets": ContentBlockerConverterVersion.scriptlets,
            "extendedCss": ContentBlockerConverterVersion.extendedCSS,
        ]
        for (key, want) in expected where bundled[key] != want {
            log("payload \(key) is \(bundled[key] ?? "absent") but the converter expects \(want) — run scripts/blocking-payload.sh")
        }
    }

    private static func log(_ message: @autoclosure () -> String) { ContentBlocker.log(message()) }

    // MARK: Looking up

    /// What applies to this page. Cheap enough to call on every navigation, before the load
    /// starts: the engine is an index, and a URL asked for twice is answered from `lookups`.
    func rules(for url: URL) -> PageRules {
        guard let webExtension else { return PageRules() }
        let key = url.absoluteString
        if let cached = lookups[key] { return cached }
        guard let configuration = webExtension.lookup(pageUrl: url, topUrl: nil) else { return PageRules() }

        var rules = PageRules(css: configuration.css, extendedCSS: configuration.extendedCss)
        rules.scripts = configuration.js
        for scriptlet in configuration.scriptlets {
            if let code = scriptletCode(name: scriptlet.name, args: scriptlet.args) {
                rules.scripts.append(code)
            }
        }
        // A browser keeps hundreds of windows open across a session and each navigation is a key;
        // the cache is for the reloads and the back/forward walks, not for the whole history.
        if lookups.count > 256 { lookups.removeAll(keepingCapacity: true) }
        lookups[key] = rules
        return rules
    }

    /// The source of one scriptlet, compiled by AdGuard's own library under JavaScriptCore.
    private func scriptletCode(name: String, args: [String]) -> String? {
        let key = ([name] + args).joined(separator: "\u{1}")
        if let cached = compiledScriptlets[key] { return cached }
        guard let context = scriptletContext() else { return nil }
        guard let invoke = context.objectForKeyedSubscript("sixScriptlets")?.objectForKeyedSubscript("invoke"),
              !invoke.isUndefined else {
            ContentBlocker.log("scriptlet payload did not define sixScriptlets.invoke")
            return nil
        }
        let source: [String: Any] = [
            "engine": "six",
            "name": name,
            "args": args,
            "version": ContentBlockerConverterVersion.library,
            "verbose": false,
        ]
        // An unknown scriptlet name throws, which the exception handler turns into a log line and
        // a nil here — one rule the library has outgrown, not a page without any of the others.
        guard let value = invoke.call(withArguments: [source]), value.isString,
              let code = value.toString(), !code.isEmpty else { return nil }
        // A few kilobytes each, and a long session over many sites could accumulate every scriptlet
        // in the lists. The hit rate is what matters, not the history: `set-constant` and
        // `prevent-setTimeout` are asked for on site after site.
        if compiledScriptlets.count > 512 { compiledScriptlets.removeAll(keepingCapacity: true) }
        compiledScriptlets[key] = code
        return code
    }

    private func scriptletContext() -> JSContext? {
        if let context { return context }
        guard let url = Bundle.main.url(forResource: "blocking-scriptlets", withExtension: "js"),
              let payload = try? String(contentsOf: url, encoding: .utf8) else {
            ContentBlocker.log("blocking-scriptlets.js is not in the bundle — no scriptlet will run")
            return nil
        }
        let context = JSContext()
        context?.exceptionHandler = { _, exception in
            ContentBlocker.log("scriptlet: \(exception?.toString() ?? "unknown error")")
        }
        context?.evaluateScript(payload)
        self.context = context
        return context
    }

    // MARK: What a page is given

    /// The user scripts that carry these rules into a page, in the order they must run.
    ///
    /// **Main frame only.** A user script's source is fixed when it is installed, and the rules
    /// that apply to a subframe are the ones for the subframe's *own* address — which is not known
    /// until it loads. Handing a third-party frame the top document's cosmetic rules would hide
    /// things inside it for no reason, so it is given none; what blocks inside a frame is the
    /// network half, which is per-request and needs nobody's help.
    func userScripts(for rules: PageRules) -> [WKUserScript] {
        guard !rules.isEmpty else { return [] }
        var scripts: [WKUserScript] = []

        // The page's own world, first, and at document start: a scriptlet earns its keep by
        // patching a global before the script that reads it exists.
        if !rules.scripts.isEmpty {
            let body = rules.scripts.joined(separator: "\n;\n")
            scripts.append(WKUserScript(
                source: "(function(){try{\n\(body)\n}catch(e){console.error('six: scriptlet failed', e)}})();",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page))
        }

        if !rules.css.isEmpty || !rules.extendedCSS.isEmpty {
            guard let payload = cosmeticPayload else { return scripts }
            let call = "sixCosmetic(\(Self.jsArray(rules.css)), \(Self.jsArray(rules.extendedCSS)));"
            scripts.append(WKUserScript(
                source: payload + "\n" + call,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .six))
        }
        return scripts
    }

    private var cosmeticPayloadCache: String??
    private var cosmeticPayload: String? {
        if let cached = cosmeticPayloadCache { return cached }
        let payload = Bundle.main.url(forResource: "blocking-cosmetic", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if payload == nil { ContentBlocker.log("blocking-cosmetic.js is not in the bundle — no extended CSS will apply") }
        cosmeticPayloadCache = .some(payload)
        return payload
    }

    /// A JavaScript array literal. `JSONSerialization` because a filter list's selectors contain
    /// quotes, backslashes and the odd line separator, and hand-escaping them is how a page ends
    /// up with a syntax error instead of a blocker.
    private static func jsArray(_ strings: [String]) -> String {
        guard !strings.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: strings),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
