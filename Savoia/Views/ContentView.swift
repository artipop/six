#if os(macOS)
import CryptoKit
import Security
import SwiftUI
import WebKit

struct ContentView: View {
    @Environment(BrowserState.self) private var browser
    @Environment(AgentSessionStore.self) private var agentSession
    @Environment(AssistantStore.self) private var assistant
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(ConfigurationStore.self) private var settings
    @Environment(HighlightStore.self) private var highlights
    /// Savoia's own MCP server, here only so the assistant switch can stop and start it.
    @Environment(MCPHost.self) private var mcp
    /// What the focused page has selected — read by `SAVOIA_VERB_SELFTEST` and nothing else here.
    @Environment(PageFocusStore.self) private var pageFocus
    /// Every key Savoia answers itself, in one place — see `KeyRouter` for why it is a monitor and not
    /// a menu, and `KeyBindings` for the table it walks.
    @State private var keys = KeyRouter()
    /// The focus ⌘L moves into the address field.
    @FocusState private var addressFocus: UUID?
    @State private var showAgentPanel = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var confirmClearHistory = false
    var body: some View { contentBody }

    private var contentBody: AnyView {
        AnyView(TabbedWindowView(addressFocus: $addressFocus).modifier(AssistantBarOverlay())
        .ignoresSafeArea(.container, edges: .top)
        .modifier(FlightsOverlayModifier())
        // Over the tab bar as well: while ⌃ is held nothing else in the window is being looked at.
        .modifier(WindowSwitcherOverlayModifier())
        // Mounted once, on the root, because Savoia is a `Window` and not a `WindowGroup`. It draws
        // nothing: it only carries the `.translationTask` that can ask for a language download.
        .translationHost(browser.appleTranslator)
        // Not merely hidden: with the assistant switched off there is no panel to present, so the
        // ACP process is never spawned and nothing can ask for it (`ConfigurationStore.isAIEnabled`).
        .modifier(AgentPanelPresentation(isPresented: agentPanelPresentation))
        .tint(browser.selectedProfile.color)
        .navigationTitle(browser.selectedTab?.title ?? "Savoia")
        .focusedSceneValue(\.focusAddressBar, FocusAddressBarAction {
            addressFocus = browser.selectedTabID
        })
        .focusedSceneValue(\.toggleAgentPanel, settings.isAIEnabled
            ? FocusAddressBarAction { showAgentPanel.toggle() } : nil)
        .modifier(Panels(history: $showHistory, bookmarks: $showBookmarks))
        .focusedSceneValue(\.clearHistory, FocusAddressBarAction { confirmClearHistory = true })
        .focusedSceneValue(\.translatePage, FocusAddressBarAction {
            if let tab = browser.selectedTab { browser.toggleTranslation(of: tab) }
        })
        .focusedSceneValue(\.translateSelection, FocusAddressBarAction {
            if let tab = browser.selectedTab { browser.translateSelection(of: tab) }
        })
        .focusedSceneValue(\.showFindBar, FocusAddressBarAction {
            if let tab = browser.selectedTab { browser.find.show(tab.id) }
        })
        .clearHistoryDialog(isPresented: $confirmClearHistory)
        // A named group has just run out of tabs and wants an answer (`TilingLayout`).
        .workspaceRemovalDialog()
        // The one part the switch reaches that is not a view: the watcher Savoia puts in every page to
        // know what is selected, which exists for ⌘E. The socket deliberately stays up — see
        // `SavoiaApp`: it is how other programs drive this browser, not how this browser uses a model.
        .onChange(of: settings.isAIEnabled) { _, enabled in
            browser.pageFocus?.isEnabled = enabled
            if !enabled { showAgentPanel = false }
        }
        // The selected tab and AppKit's first responder are two different things; in a side-by-side
        // pair they can disagree (`WebViewResponder`).
        .onChange(of: browser.selectedTabID) { _, id in WebViewResponder.shared.focus(id) }
        .onAppear { browser.selectTabIfNone() }
        .onAppear(perform: startKeyRouter)
        .onDisappear { keys.stop() }
        .task {
            // The first launch has one question, and it is asked as a tab rather than a sheet (`WelcomePage`).
            if !settings.hasAnsweredWelcome { browser.openBuiltIn(.welcome) }
        }
        .task {
            // SwiftUI hands a new window's focus to the first field it finds, and that is now the
            // address field: Savoia would open with the caret up there and the page unable to hear a
            // key. `defaultFocus(_:nil)` does not cover it — the field has to be let go of after the
            // window has settled. ⌘L is how you ask for it.
            try? await Task.sleep(for: .milliseconds(200))
            addressFocus = nil
        }
        .task { await runDebugSelfTests() }
        )
    }
}

private struct AgentPanelPresentation: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.inspector(isPresented: $isPresented) {
            AgentPanel()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 700)
        }
    }
}

private struct AssistantBarOverlay: ViewModifier {
    @Environment(BrowserState.self) private var browser
    @Environment(ConfigurationStore.self) private var settings

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if settings.isAIEnabled {
                AssistantBar(place: .bottom)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 720)
            }
        }
    }
}

private struct FlightsOverlayModifier: ViewModifier {
    func body(content: Content) -> some View { content.overlay { FlightsOverlay() } }
}

private struct WindowSwitcherOverlayModifier: ViewModifier {
    func body(content: Content) -> some View { content.overlay { WindowSwitcherOverlay() } }
}

extension ContentView {
    private var agentPanelPresentation: Binding<Bool> {
        Binding(
            get: { showAgentPanel && settings.isAIEnabled },
            set: { showAgentPanel = $0 }
        )
    }

    private func runDebugSelfTests() async {
        let environment = ProcessInfo.processInfo.environment
        if let text = environment["SAVOIA_ACP_SELFTEST"], !text.isEmpty {
            showAgentPanel = true
            try? await Task.sleep(for: .seconds(1))
            agentSession.send(text)
        }
        await runKeySelfTest(environment["SAVOIA_KEY_SELFTEST"])
        if environment["SAVOIA_MCP_PANEL"] != nil {
            browser.openBuiltIn(.configuration, section: "assistant")
        }
        if let spec = environment["SAVOIA_ASSISTANT_SELFTEST"],
           let split = spec.range(of: ":", options: .backwards),
           let model = ModelChoice(rawValue: String(spec[..<split.lowerBound])) {
            assistant.settings.model = model
            try? await Task.sleep(for: .seconds(1))
            assistant.ask(String(spec[split.upperBound...]), about: browser.selectedTab)
        }
        if let id = environment["SAVOIA_VERB_SELFTEST"], !id.isEmpty { await verbSelfTest(id) }
        if let address = environment["SAVOIA_TRANSLATE_SELFTEST"], let url = URL(string: address) {
            await translateSelfTest(url)
        }
        if let query = environment["SAVOIA_PERSONAL_SELFTEST"], !query.isEmpty { await personalSelfTest(query) }
        if let spec = environment["SAVOIA_FIND_SELFTEST"], !spec.isEmpty { await findSelfTest(spec) }
        if environment["SAVOIA_CRX_SELFTEST"] != nil { crxSelfTest() }
        if environment["SAVOIA_TABS_SELFTEST"] != nil { await TabsSelfTest.run(browser) }
        if environment["SAVOIA_INSPECTOR_SELFTEST"] != nil { await WebInspectorSelfTest.run(browser) }
        if let mode = environment["SAVOIA_TOPICS_SELFTEST"] { await TabTopicsSelfTest.run(browser, grid: mode == "grid", compare: mode == "compare") }
        if let text = environment["SAVOIA_CHATS_SELFTEST"], !text.isEmpty {
            await agentSession.chatsSelfTest(prompt: text, browser: browser)
        }
        if let text = environment["SAVOIA_LINE_CHATS_SELFTEST"], !text.isEmpty {
            await assistant.lineChatsSelfTest(prompt: text, agents: agentSession, browser: browser)
        }
    }

    private func runKeySelfTest(_ mode: String?) async {
        switch mode {
#if DEBUG
        case "alert": await KeySelfTest.alertOnly(browser)
#endif
        case "assistant": await KeySelfTest.assistantOnly(browser, assistant, pageFocus, agentSession)
        case "chats": await KeySelfTest.chatsOnly(browser, assistant, agentSession)
        case .some:
            KeySelfTest.run()
            await KeySelfTest.live(browser)
        case nil: break
        }
    }

    /// The table's actions, turned into calls — here, because this view has the tabs, the ring, the
    /// page being read and the highlights all in one place.
    private func startKeyRouter() {
        keys.isSwitching = { browser.switcher.isOpen }
        keys.performExtensionCommand = { event in
            guard let extensions = browser.extensions else { return false }
            return extensions.performCommand(for: event, in: browser.selectedProfileID)
        }
        keys.perform = { action in
            switch action {
            case .stepSwitcher(let step): browser.stepWindowSwitch(step)
            case .walkSwitcher(let step): browser.walkWindowSwitch(step)
            case .landSwitcher: browser.endWindowSwitch()
            case .cancelSwitcher: browser.cancelWindowSwitch()
            case .translateSelection:
                guard let tab = browser.selectedTab else { return false }
                browser.translateSelection(of: tab)
            case .highlightSelection:
                guard let tab = browser.selectedTab, !tab.isDocument, !tab.showsStartPage else { return false }
                Task { _ = await highlights.highlightSelection(in: tab) }
            case .pictureInPicture:
                // Declined on a window with no live page, so the key falls through to whatever else
                // wanted it rather than being swallowed by a card.
                guard let tab = browser.selectedTab, tab.hasLivePage else { return false }
                tab.togglePictureInPicture()
            case .copyAddress:
                // Declined on a window with no address of its own — a start page, a document, an
                // app window — for the same reason.
                return browser.copyAddress()
            }
            return true
        }
        keys.start()
    }

    /// `SAVOIA_VERB_SELFTEST=fix` — run one verb on the focused page's selection and say what came back.
    fileprivate func verbSelfTest(_ id: String) async {
        func say(_ line: String) { Log.info(.ui, "verb selftest: \(line)") }
        guard let action = AssistantAction.action(id) else {
            return say("no such verb: \(id) — have \(AssistantAction.all.map(\.id).joined(separator: ", "))")
        }
        // Waits for something to be pointed at rather than assuming it already is: the selection
        // is made from outside, over MCP, after Savoia is up.
        var found: (BrowserTab, PageFocus)?
        for _ in 0..<60 {
            await pageFocus.refresh(browser.selectedTab)
            if let tab = browser.selectedTab, !pageFocus[tab.id].isEmpty { found = (tab, pageFocus[tab.id]); break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let (tab, focus) = found else { return say("nothing selected in 30 s") }
        say("\(action.id) on \(focus.kind.rawValue) \"\(focus.subject.prefix(60))\" — answered by \(assistant.settings.model.title)")
        assistant.run(action, focus: focus, about: tab)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let answer = assistant.answer else { break }
            if answer.isRunning { continue }
            if let error = answer.error { return say("failed: \(error)") }
            return say("answered (\(answer.landing), applicable \(answer.isApplicable)): \(answer.text.prefix(200))")
        }
        say("no answer in 20 s")
    }

    /// Runs each `;`-separated query through the personal rows the way the start page does, and says
    /// what the index answered before `PersonalSuggestions` had its say — which is the only way to
    /// tune the cutoff against real bookmarks. The first query pays for loading the embedder (and,
    /// if the weights aren't down yet, for downloading them).
    fileprivate func personalSelfTest(_ queries: String) async {
        for query in queries.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !query.isEmpty {
            await personalSelfTest(one: query)
        }
    }

    fileprivate func personalSelfTest(one query: String) async {
        func say(_ text: String) { print("[personal] \(text)"); fflush(stdout) }

        let profileID = browser.selectedProfile.id
        let scope = settings.bookmarkScope
        say("query \(query.debugDescription) · scope \(scope.rawValue) · profile \(browser.selectedProfile.name)")
        say("bookmarks in scope: \(bookmarks.count(in: scope, profileID: profileID)) · embedder \(bookmarks.embedder.modelID)")

        let started = ContinuousClock.now
        let all = await bookmarks.search(query, in: scope, profileID: profileID, limit: 12)
        say("the index answered \(all.count) in \(ContinuousClock.now - started):")
        for hit in all {
            say(String(format: "  %.3f  ", hit.score) + hit.bookmark.displayTitle + "  — " + hit.snippet.prefix(70).replacingOccurrences(of: "\n", with: " "))
        }

        let personal = PersonalSuggestions()
        personal.update(for: query, in: bookmarks, scope: scope, profileID: profileID)
        for _ in 0..<80 where personal.hits.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        say("the field would show \(personal.hits.count):")
        for hit in personal.hits {
            say(String(format: "  %.3f  ", hit.score) + hit.bookmark.displayTitle + "  · " + hit.bookmark.displayDetail)
        }
    }

    /// `SAVOIA_FIND_SELFTEST="query:url"` — loads `url`, searches `query`, walks a couple of matches
    /// and closes the bar, printing the count and current index at each step.
    fileprivate func findSelfTest(_ spec: String) async {
        func say(_ text: String) { print("[find] \(text)"); fflush(stdout) }

        guard let split = spec.range(of: ":"), let url = URL(string: String(spec[split.upperBound...])) else {
            return say("usage: SAVOIA_FIND_SELFTEST=\"query:https://example.com\"")
        }
        let query = String(spec[..<split.lowerBound])
        // A fresh tab rather than whatever was selected: the selftest must not
        // depend on the last-open window being an ordinary page — `load` is a no-op on Savoia's own
        // pages (`BrowserTab.isWebPage`), which is exactly what a restored `savoia://settings` window
        // is one launch out of every few.
        let tab = browser.newTab(url: url)
        for _ in 0..<80 where tab.isLoading || tab.currentURL == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        say("loaded \(tab.currentURL?.absoluteString ?? "nothing")")

        browser.find.show(tab.id)
        say("shown: isActive=\(browser.find[tab.id]?.isActive ?? false)")

        await browser.find.search(query, id: tab.id)
        say("search \(query.debugDescription): \(describe(tab))")

        await browser.find.step(1, id: tab.id)
        say("step +1: \(describe(tab))")
        await browser.find.step(1, id: tab.id)
        say("step +1: \(describe(tab))")
        await browser.find.step(-1, id: tab.id)
        say("step -1: \(describe(tab))")

        await browser.find.search("", id: tab.id)
        say("cleared: \(describe(tab))")

        browser.find.hide(tab.id)
        say("hidden: isActive=\(browser.find[tab.id]?.isActive ?? true)")
    }

    fileprivate func describe(_ tab: BrowserTab) -> String {
        guard let state = browser.find[tab.id] else { return "no state" }
        return "found=\(state.isFound)"
    }

    /// `SAVOIA_CRX_SELFTEST=1` — builds a `.crx` from scratch, RSA-signed and separately ECDSA-signed,
    /// and runs `CRXSignature.verify` against each, against one flipped byte, and against a plain
    /// zip. `CRXSignature` only ever decodes; the encoder here exists nowhere else and is not meant
    /// to — its one job is proving the decoder reads back exactly what a correct encoder writes.
    fileprivate func crxSelfTest() {
        func say(_ text: String) { print("[crx] \(text)"); fflush(stdout) }

        func varint(_ value: UInt64) -> Data {
            var v = value; var out = Data()
            repeat {
                var byte = UInt8(v & 0x7F); v >>= 7
                if v != 0 { byte |= 0x80 }
                out.append(byte)
            } while v != 0
            return out
        }
        func field(_ number: Int, _ content: Data) -> Data {
            varint(UInt64((number << 3) | 2)) + varint(UInt64(content.count)) + content
        }
        func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
        func assemble(header: Data, archive: Data) -> Data {
            Data("Cr24".utf8) + le32(3) + le32(header.count) + header + archive
        }
        func signedPayload(over signedHeaderData: Data, archive: Data) -> Data {
            var payload = Data("CRX3 SignedData\0".utf8)
            payload.append(le32(signedHeaderData.count))
            payload.append(signedHeaderData)
            payload.append(archive)
            return payload
        }

        // `SAVOIA_CRX_SELFTEST=/some/dir` (a path rather than `1`) also writes the fixtures there, so
        // the real install dialog can be tried against a signature that is actually known-good or
        // known-tampered, rather than only ever a real-world file whose answer nobody here checked.
        // Installing one all the way needs a real zip behind the signature — `ditto` unpacks it the
        // same way it would a real `.crx` — so this builds a minimal, genuinely valid extension
        // rather than reusing the placeholder bytes the plain print-only run is content with.
        let writeTo = ProcessInfo.processInfo.environment["SAVOIA_CRX_SELFTEST"]
            .flatMap { $0 == "1" ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        func realExtensionZip() -> Data? {
            let scratch = FileManager.default.temporaryDirectory.appending(path: "savoia-crx-selftest-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let manifest = #"{"manifest_version":3,"name":"CRX Signature Selftest","version":"1.0"}"#
                try manifest.write(to: scratch.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
                let zip = scratch.appending(path: "archive.zip")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.currentDirectoryURL = scratch
                process.arguments = ["-q", zip.lastPathComponent, "manifest.json"]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return try Data(contentsOf: zip)
            } catch {
                return nil
            }
        }

        let archive = (writeTo != nil ? realExtensionZip() : nil) ?? Data("PK\u{03}\u{04} pretend this is a zip archive".utf8)

        // A CRX3 public key is X.509 SubjectPublicKeyInfo; `SecKeyCopyExternalRepresentation` for
        // an RSA key hands back the bare PKCS#1 structure it wraps, so the wrapping is by hand —
        // the mirror image of `PKCS1.unwrap` in `CRXSignature`, proving the two sides agree.
        func derLength(_ n: Int) -> Data {
            if n < 128 { return Data([UInt8(n)]) }
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func derSequence(_ content: Data) -> Data { Data([0x30]) + derLength(content.count) + content }
        func derBitString(_ content: Data) -> Data { Data([0x03]) + derLength(content.count + 1) + Data([0x00]) + content }
        let rsaAlgorithmID = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])

        func rsaCRX() -> Data? {
            let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
                say("RSA key generation failed: \(error!.takeRetainedValue())"); return nil
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey),
                  let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
            else { return nil }
            let spki = derSequence(rsaAlgorithmID + derBitString(pkcs1))
            let crxID = Data(SHA256.hash(data: spki)).prefix(16)
            let signedHeaderData = field(1, crxID)
            let payload = signedPayload(over: signedHeaderData, archive: archive)
            guard let signature = SecKeyCreateSignature(
                privateKey, .rsaSignatureMessagePKCS1v15SHA256, payload as CFData, &error
            ) as Data? else {
                say("RSA signing failed: \(error!.takeRetainedValue())"); return nil
            }
            let proof = field(1, spki) + field(2, signature)
            return assemble(header: field(2, proof) + field(4, signedHeaderData), archive: archive)
        }

        func ecdsaCRX() -> Data? {
            let key = P256.Signing.PrivateKey()
            let spki = key.publicKey.derRepresentation
            let crxID = Data(SHA256.hash(data: spki)).prefix(16)
            let signedHeaderData = field(1, crxID)
            let payload = signedPayload(over: signedHeaderData, archive: archive)
            guard let signature = try? key.signature(for: SHA256.hash(data: payload)) else { return nil }
            let proof = field(1, spki) + field(2, signature.derRepresentation)
            return assemble(header: field(3, proof) + field(4, signedHeaderData), archive: archive)
        }

        if let rsa = rsaCRX() {
            say("RSA proof: \(CRXSignature.verify(rsa))")
            var tampered = rsa
            tampered[tampered.count - 1] ^= 0xFF
            say("RSA proof, one byte flipped: \(CRXSignature.verify(tampered))")
            if let writeTo {
                try? rsa.write(to: writeTo.appending(path: "rsa-signed.crx"))
                try? tampered.write(to: writeTo.appending(path: "rsa-tampered.crx"))
            }
        } else {
            say("could not build an RSA fixture")
        }
        if let ecdsa = ecdsaCRX() {
            say("ECDSA proof: \(CRXSignature.verify(ecdsa))")
            if let writeTo { try? ecdsa.write(to: writeTo.appending(path: "ecdsa-signed.crx")) }
        } else {
            say("could not build an ECDSA fixture")
        }
        say("plain zip, no crx header at all: \(CRXSignature.verify(archive))")
    }

    /// Drives one page through translation from launch, printing what happened. A harness, in the
    /// shape the ACP and assistant ones already have.
    fileprivate func translateSelfTest(_ url: URL) async {
        func say(_ text: String) { print("[translate] \(text)"); fflush(stdout) }

        guard let tab = browser.selectedTab else { return say("no tab") }
        tab.load(url)
        for _ in 0..<80 where tab.isLoading || tab.currentURL == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        say("loaded \(tab.currentURL?.absoluteString ?? "nothing")")

        await browser.appleTranslator.loadLanguages()
        let offered = browser.appleTranslator.languages
        say("menu offers \(offered.count) languages: \(offered.prefix(6).map { AppleTranslator.name(of: $0) }.joined(separator: ", "))…")
        say("target from settings: \(AppleTranslator.name(of: browser.translationTarget))")

        guard let plan = try? await browser.translation.plan(tab) else { return say("no plan") }
        say("plan: lang=\(plan.language.isEmpty ? "-" : plan.language) unsupported=\(plan.unsupported.isEmpty ? "-" : plan.unsupported) sample=\(plan.sample.prefix(60))…")
        if let refusal = plan.refusal { return say("refused: \(refusal)") }

        guard let source = TranslationLanguage.source(of: plan) else { return say("no source language") }
        say("the button would offer: \(browser.suggestedTargets(excluding: source).map { AppleTranslator.name(of: $0) })")

        // `SAVOIA_TRANSLATE_SELFTEST_TARGETS="en,de"` runs the page through more than one language in
        // a row, which is the case that found the stale armed pair: the second language's download
        // sheet never came up while the first one's task was still mounted.
        let codes = (ProcessInfo.processInfo.environment["SAVOIA_TRANSLATE_SELFTEST_TARGETS"] ?? "en")
            .split(separator: ",").map(String.init)
        for code in codes {
            await runOnce(tab, source: source, target: Locale.Language(identifier: code), say: say)
        }
        say("armed at the end: \(browser.appleTranslator.armedPairs.map(\.id))")

        // `SAVOIA_TRANSLATE_SELFTEST_SELECTION=1` selects a paragraph and opens the system popover.
        if ProcessInfo.processInfo.environment["SAVOIA_TRANSLATE_SELFTEST_SELECTION"] == "1" {
            _ = try? await tab.runScript("""
            const p = document.querySelector('p');
            const range = document.createRange();
            range.selectNodeContents(p);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            return p.textContent.slice(0, 40);
            """)
            browser.translateSelection(of: tab)
            try? await Task.sleep(for: .seconds(2))
            say("selection: \(browser.translation.selection.prefix(50))…")
            say("editable: \(browser.translation.selectionIsEditable), popover up: \(browser.translation.showsSelection)")
        }
    }

    fileprivate func runOnce(
        _ tab: BrowserTab, source: Locale.Language, target: Locale.Language,
        say: @escaping (String) -> Void
    ) async {
        browser.translation.forget(tab.id)
        say("--- \(source.maximalIdentifier) -> \(target.maximalIdentifier), status \(await browser.appleTranslator.status(from: source, to: target))")

        let run = Task { await browser.translation.translate(tab, id: tab.id, from: source, to: target) }
        var sawArmed = false
        var sawDownloading = false
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(500))
            let armed = browser.appleTranslator.armedPairs.map(\.id)
            if !armed.isEmpty, !sawArmed {
                sawArmed = true
                say("ARMED \(armed) — the framework should be asking to download now")
            }
            guard let state = browser.translation[tab.id] else { continue }
            switch state.phase {
            case .done: say("DONE"); return
            case .failed(let why): say("FAILED: \(why)"); return
            case .working(let d, let n) where n > 0 && d % 300 == 0: say("working \(d)/\(n)")
            case .downloading:
                if !sawDownloading { sawDownloading = true; say("PHASE .downloading — the spinner should be turning") }
            default: break
            }
        }
        run.cancel()
        say("gave up waiting")
    }
}

/// The two panels that are opened from a menu item: each one is a focused value the menu reaches
/// across the scene, and a sheet that answers it.
///
/// There were six. Filter lists, extensions, site permissions and certificates were the other four,
/// and every one of them was a settings screen wearing a sheet — a thing that covers the window it
/// is describing so that it can describe it. They are sections of `savoia://settings` now. History and
/// bookmarks stay sheets because they are not settings: they are a search over everything, asked in
/// passing (⌘Y, ⌘⌥B) and closed again.
///
/// They are a modifier rather than more lines on the body because the body had reached the size
/// where the type checker gives up on it — *"unable to type-check this expression in reasonable
/// time"*, which arrives all at once when a chain grows by one. Anything added here goes in this
/// list, not up there.
private struct Panels: ViewModifier {
    @Binding var history: Bool
    @Binding var bookmarks: Bool

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.showHistory, FocusAddressBarAction { history = true })
            .sheet(isPresented: $history) { HistoryView() }
            .focusedSceneValue(\.showBookmarks, FocusAddressBarAction { bookmarks = true })
            .sheet(isPresented: $bookmarks) { BookmarksView() }
            .tabCleanupSheet()
    }
}

/// The star: filled when the page this bar is describing is bookmarked; a click saves it (or forgets
/// it). It takes that window rather than reading the selection, because it is only ever drawn beside
/// that window's address — there is no state of this button that means "no window".
struct BookmarkButton: View {
    let tab: BrowserTab

    @Environment(BrowserState.self) private var browser
    @Environment(BookmarkStore.self) private var bookmarks

    var body: some View {
        let saved = bookmarks.isBookmarked(tab)
        let indexing = tab.currentURL.flatMap { bookmarks.bookmark(for: $0, in: tab.profileID) }
            .map { bookmarks.indexing.contains($0.id) } ?? false
        Button {
            if saved, let url = tab.currentURL, let existing = bookmarks.bookmark(for: url, in: tab.profileID) {
                bookmarks.remove(existing.id)
            } else {
                Task { try? await bookmarks.add(tab) }
            }
        } label: {
            // Saved is saved: the star fills as soon as the row exists. The embedding that follows is the
            // index's business and shows in the bookmarks window — a spinner here reads as "still saving".
            Image(systemName: saved ? "bookmark.fill" : "bookmark")
                .foregroundStyle(saved ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .disabled(tab.showsStartPage || browser.isPrivate(tab.profileID))
        .help(saved ? (indexing ? "Saved; indexing for search… Remove Bookmark (⌘D)" : "Remove Bookmark (⌘D)") : "Add Bookmark (⌘D)")
    }
}

/// The system's share picker for the page this bar describes — Mail, Messages, AirDrop, Notes, and
/// every other app's share extension. Greyed out rather than gone when there is nothing to share, so
/// the bar does not shift under the pointer between a page and a start page.
struct ShareButton: View {
    let tab: BrowserTab

    var body: some View {
        if let url = tab.shareableURL {
            ShareLink(item: url, subject: Text(tab.shareTitle), preview: SharePreview(tab.shareTitle)) {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Share")
        } else {
            Button {} label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .disabled(true)
                .help("Share")
        }
    }
}

#endif
