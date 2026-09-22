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
    /// Six's own MCP server, here only so the assistant switch can stop and start it.
    @Environment(MCPHost.self) private var mcp
    /// What the focused page has selected — read by `SIX_VERB_SELFTEST` and nothing else here.
    @Environment(PageFocusStore.self) private var pageFocus
    /// Every key six answers itself, in one place — see `KeyRouter` for why it is a monitor and not
    /// a menu, and `KeyBindings` for the table it walks.
    @State private var keys = KeyRouter()
    /// The address field lives in the top bar now, so the focus that ⌘L moves lives beside it —
    /// above the strip, which no longer has one.
    @FocusState private var addressFocus: UUID?
    @State private var showAgentPanel = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var confirmClearHistory = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(addressFocus: $addressFocus)
                // In front of the rail, not behind it. They are siblings in a stack, so the rail is
                // drawn — and hit-tested — after the bar; anything of the rail's that reaches up into
                // the bar's band would take the click off its buttons.
                .zIndex(1)
            NiriStripView()
                .overlay(alignment: .bottom) {
                    if !browser.layout.isOverview, settings.isAIEnabled {
                        // Tucked away always, not just in fullscreen: a bar resting over the bottom of
                        // every page is in the way of the page — a video's controls sit exactly there.
                        // ⌘E brings it back (and an answer keeps it up), which is what it was for.
                        AssistantBar(place: .bottom)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                            .frame(maxWidth: 720)
                    }
                }
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay { FlightsOverlay() }
        // Over the top bar as well as over the rail: while ⌃ is held nothing else in the window is
        // being looked at.
        .overlay { WindowSwitcherOverlay() }
        // Mounted once, on the root, because six is a `Window` and not a `WindowGroup`. It draws
        // nothing: it only carries the `.translationTask` that can ask for a language download.
        .translationHost(browser.appleTranslator)
        // Not merely hidden: with the assistant switched off there is no panel to present, so the
        // ACP process is never spawned and Agent Panel has nothing to toggle (`ConfigurationStore.isAIEnabled`).
        .inspector(isPresented: Binding(get: { showAgentPanel && settings.isAIEnabled },
                                        set: { showAgentPanel = $0 })) {
            AgentPanel()
                .inspectorColumnWidth(min: 320, ideal: 400, max: 700)
        }
        .tint(browser.selectedProfile.color)
        .navigationTitle(browser.selectedTab?.title ?? "six")
        .focusedSceneValue(\.focusAddressBar, FocusAddressBarAction {
            browser.exitOverview()
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
        // A named workspace has just run out of windows and wants an answer (`NiriLayout`).
        .workspaceRemovalDialog()
        // The switch reaches the parts that are not views: the watcher in every page, and the
        // socket other agents drive six through. Both are off while it is.
        .onChange(of: settings.isAIEnabled) { _, enabled in
            browser.pageFocus?.isEnabled = enabled
            if enabled { mcp.start() } else { mcp.stop(); showAgentPanel = false }
        }
        // The rail's focus and AppKit's first responder are two different things, and they used to
        // be able to disagree: ⌥→ moved the border and the address field while the keys went on
        // arriving in the page you had walked away from. Invisible on a rail, where that window is
        // off the edge a moment later — and impossible to miss in a split, where one half is
        // highlighted and your typing lands in the other. `WebViewResponder` has the account.
        .onChange(of: browser.selectedTabID) { _, id in WebViewResponder.shared.focus(id) }
        .onAppear(perform: startKeyRouter)
        .onDisappear { keys.stop() }
        .task {
            // The first launch has one question, and it is asked as a window on the rail rather
            // than a sheet over it (`WelcomePage`).
            if !settings.hasAnsweredWelcome { browser.openBuiltIn(.welcome) }
        }
        .task {
            // SwiftUI hands a new window's focus to the first field it finds, and that is now the
            // address field: six would open with the caret up there and the page unable to hear a
            // key. `defaultFocus(_:nil)` does not cover it — the field has to be let go of after the
            // window has settled. ⌘L is how you ask for it.
            try? await Task.sleep(for: .milliseconds(200))
            addressFocus = nil
        }
        .task {
            // Debug harness: `SIX_ACP_SELFTEST="hi"` opens the agent panel and sends the text on launch,
            // so the ACP path can be exercised (with SIX_ACP_TRACE=1) without clicking.
            if let text = ProcessInfo.processInfo.environment["SIX_ACP_SELFTEST"], !text.isEmpty {
                showAgentPanel = true
                try? await Task.sleep(for: .seconds(1))
                agentSession.send(text)
            }
            // `SIX_KEY_SELFTEST=1` prints what every binding answers in every context — the only
            // way to check the keyboard on a Mac that cannot press its own keys (`KeySelfTest`).
            if ProcessInfo.processInfo.environment["SIX_KEY_SELFTEST"] == "page" {
                await KeySelfTest.pageOnly(browser)
            } else if ProcessInfo.processInfo.environment["SIX_KEY_SELFTEST"] == "assistant" {
                await KeySelfTest.assistantOnly(browser, assistant, pageFocus, agentSession)
            } else if ProcessInfo.processInfo.environment["SIX_KEY_SELFTEST"] != nil {
                KeySelfTest.run()
                await KeySelfTest.live(browser)
            }
            // `SIX_MCP_PANEL=1` opens the servers page on launch, so it can be looked at without
            // reaching for the menu (docs/mcp-apps.md).
            if ProcessInfo.processInfo.environment["SIX_MCP_PANEL"] != nil { browser.openBuiltIn(.apps) }
            // `SIX_ASSISTANT_SELFTEST="acp:claude-code:open example.com"` does the same through the ⌘E line.
            if let spec = ProcessInfo.processInfo.environment["SIX_ASSISTANT_SELFTEST"],
               let split = spec.range(of: ":", options: .backwards),
               let model = ModelChoice(rawValue: String(spec[..<split.lowerBound])) {
                assistant.settings.model = model
                try? await Task.sleep(for: .seconds(1))
                assistant.ask(String(spec[split.upperBound...]), about: browser.selectedTab)
            }
            // `SIX_VERB_SELFTEST=explain` presses a verb from the catalog on whatever the focused
            // page has selected, and narrates the answer. The bar it normally comes from is AppKit
            // over a web view, and nothing on this machine can click one (CLAUDE.md) — this is the
            // only way to see a verb run end to end, including which model took it while the ⌘E
            // line is set to an agent.
            if let id = ProcessInfo.processInfo.environment["SIX_VERB_SELFTEST"], !id.isEmpty {
                await verbSelfTest(id)
            }
            // `SIX_TRANSLATE_SELFTEST="https://ru.wikipedia.org/wiki/Браузер"` opens the address and
            // translates it, narrating each step — the download prompt is the framework's own and
            // still wants a person, but everything up to and after it can be watched from a terminal.
            if let address = ProcessInfo.processInfo.environment["SIX_TRANSLATE_SELFTEST"],
               let url = URL(string: address) {
                await translateSelfTest(url)
            }
            // `SIX_PERSONAL_SELFTEST="плов"` asks the start page's personal rows what they would
            // show for that query and prints both what the index answered and what survived the
            // floor — which is the only way to tune the floor against real bookmarks.
            if let query = ProcessInfo.processInfo.environment["SIX_PERSONAL_SELFTEST"], !query.isEmpty {
                await personalSelfTest(query)
            }
            // `SIX_FIND_SELFTEST="query:https://example.com"` drives ⌘F's own store — `show`,
            // `search`, `step`, `hide` — without a keystroke to send it, the same reason every
            // other selftest here exists (CLAUDE.md: nothing on this machine can post ⌘F from
            // outside the app, and `KeySelfTest` only covers the table, not menu items).
            if let spec = ProcessInfo.processInfo.environment["SIX_FIND_SELFTEST"], !spec.isEmpty {
                await findSelfTest(spec)
            }
            // `SIX_CRX_SELFTEST=1` builds a `.crx` from scratch — a fresh RSA and a fresh P-256 key,
            // both signing it — and runs `CRXSignature.verify` against it, then against one byte of
            // it flipped, then against a plain zip. No real signed `.crx` was reachable to test
            // against from here (the Chrome Web Store's update endpoint answers a bare 204 without a
            // running Chrome to ask on its behalf), so this is what stands in: it cannot say the
            // decoder reads a real file's exact byte layout, only that encoding and decoding agree
            // with each other and that a tampered file is told apart from an intact one.
            if ProcessInfo.processInfo.environment["SIX_CRX_SELFTEST"] != nil {
                crxSelfTest()
            }
        }
    }
}

extension ContentView {
    /// The table's actions, turned into calls. This is the view that has all of them in one place —
    /// the rail, the ring, the page being read and the highlights — which is why the router is
    /// installed here and not down in the strip, where the ⌥ keys used to live: half the table was
    /// out of that view's reach, and that is how `⌥⇧T` and `⌥⇧H` ended up as menu items a focused
    /// page could swallow.
    private func startKeyRouter() {
        keys.isSwitching = { browser.switcher.isOpen }
        keys.isOverview = { browser.layout.isOverview }
        keys.performExtensionCommand = { event in
            guard let extensions = browser.extensions else { return false }
            return extensions.performCommand(for: event, in: browser.selectedProfileID)
        }
        keys.perform = { action in
            switch action {
            case .focusColumn(let step): browser.focusColumn(step)
            case .moveColumn(let step): browser.moveColumn(step)
            case .focusColumnEdge(let last): browser.focusColumnEdge(last: last)
            case .focusWorkspace(let step): browser.focusWorkspace(step)
            case .moveColumnToWorkspace(let step): browser.moveColumnToWorkspace(step)
            case .toggleFullWidth: browser.toggleFullWindow()
            case .toggleSplit: browser.toggleSplit()
            case .toggleOverview: browser.toggleOverview()
            case .toggleCenterFocus: browser.toggleCenterFocus()
            case .stepSwitcher(let step): browser.stepWindowSwitch(step)
            case .walkSwitcher(let step): browser.walkWindowSwitch(step)
            case .landSwitcher: browser.endWindowSwitch()
            case .cancelSwitcher: browser.cancelWindowSwitch()
            case .leaveOverview:
                // The one action that can decline: outside the overview `⎋` is the page's own, and
                // the start page's field clears itself with it.
                guard browser.layout.isOverview else { return false }
                browser.exitOverview()
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

    /// `SIX_VERB_SELFTEST=fix` — run one verb on the focused page's selection and say what came back.
    fileprivate func verbSelfTest(_ id: String) async {
        func say(_ line: String) { Log.info(.ui, "verb selftest: \(line)") }
        guard let action = AssistantAction.action(id) else {
            return say("no such verb: \(id) — have \(AssistantAction.all.map(\.id).joined(separator: ", "))")
        }
        // Waits for something to be pointed at rather than assuming it already is: the selection
        // is made from outside, over MCP, after six is up.
        var found: (BrowserTab, PageFocus)?
        for _ in 0..<60 {
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

    /// `SIX_FIND_SELFTEST="query:url"` — loads `url`, searches `query`, walks a couple of matches
    /// and closes the bar, printing the count and current index at each step.
    fileprivate func findSelfTest(_ spec: String) async {
        func say(_ text: String) { print("[find] \(text)"); fflush(stdout) }

        guard let split = spec.range(of: ":"), let url = URL(string: String(spec[split.upperBound...])) else {
            return say("usage: SIX_FIND_SELFTEST=\"query:https://example.com\"")
        }
        let query = String(spec[..<split.lowerBound])
        // A fresh window rather than whatever the strip already had focused: the selftest must not
        // depend on the last-open window being an ordinary page — `load` is a no-op on six's own
        // pages (`BrowserTab.isWebPage`), which is exactly what a restored `six://settings` window
        // is one launch out of every few.
        let tab = browser.newTab(url: url)
        for _ in 0..<80 where tab.isLoading || tab.currentURL == nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        say("loaded \(tab.currentURL?.absoluteString ?? "nothing")")

        browser.find.show(tab.id)
        say("shown: isActive=\(browser.find[tab.id]?.isActive ?? false)")

        await browser.find.search(query, in: tab, id: tab.id)
        say("search \(query.debugDescription): \(describe(tab))")

        await browser.find.step(1, in: tab, id: tab.id)
        say("step +1: \(describe(tab))")
        await browser.find.step(1, in: tab, id: tab.id)
        say("step +1: \(describe(tab))")
        await browser.find.step(-1, in: tab, id: tab.id)
        say("step -1: \(describe(tab))")

        await browser.find.search("", in: tab, id: tab.id)
        say("cleared: \(describe(tab))")

        browser.find.hide(tab, id: tab.id)
        say("hidden: isActive=\(browser.find[tab.id]?.isActive ?? true)")
    }

    fileprivate func describe(_ tab: BrowserTab) -> String {
        guard let state = browser.find[tab.id] else { return "no state" }
        return "count=\(state.count) current=\(state.current)"
    }

    /// `SIX_CRX_SELFTEST=1` — builds a `.crx` from scratch, RSA-signed and separately ECDSA-signed,
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

        // `SIX_CRX_SELFTEST=/some/dir` (a path rather than `1`) also writes the fixtures there, so
        // the real install dialog can be tried against a signature that is actually known-good or
        // known-tampered, rather than only ever a real-world file whose answer nobody here checked.
        // Installing one all the way needs a real zip behind the signature — `ditto` unpacks it the
        // same way it would a real `.crx` — so this builds a minimal, genuinely valid extension
        // rather than reusing the placeholder bytes the plain print-only run is content with.
        let writeTo = ProcessInfo.processInfo.environment["SIX_CRX_SELFTEST"]
            .flatMap { $0 == "1" ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        func realExtensionZip() -> Data? {
            let scratch = FileManager.default.temporaryDirectory.appending(path: "six-crx-selftest-\(UUID().uuidString)")
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

        // `SIX_TRANSLATE_SELFTEST_TARGETS="en,de"` runs the page through more than one language in
        // a row, which is the case that found the stale armed pair: the second language's download
        // sheet never came up while the first one's task was still mounted.
        let codes = (ProcessInfo.processInfo.environment["SIX_TRANSLATE_SELFTEST_TARGETS"] ?? "en")
            .split(separator: ",").map(String.init)
        for code in codes {
            await runOnce(tab, source: source, target: Locale.Language(identifier: code), say: say)
        }
        say("armed at the end: \(browser.appleTranslator.armedPairs.map(\.id))")

        // `SIX_TRANSLATE_SELFTEST_SELECTION=1` selects a paragraph and opens the system popover.
        if ProcessInfo.processInfo.environment["SIX_TRANSLATE_SELFTEST_SELECTION"] == "1" {
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

/// The bar in the (hidden) title bar area — the window's one piece of chrome, and now the only one.
///
/// Left: which profile you are in, and how the layout is showing the strip. Middle: the focused
/// window's address, with the star against its trailing edge — the two things that are about the
/// page you are reading, because that band of the window was empty and an address field is exactly
/// the shape of it. Right: everything about the strip rather than the page — what is downloading,
/// where in the stack of workspaces you are, the overview, the agent.
/// The two panels that are opened from a menu item: each one is a focused value the menu reaches
/// across the scene, and a sheet that answers it.
///
/// There were six. Filter lists, extensions, site permissions and certificates were the other four,
/// and every one of them was a settings screen wearing a sheet — a thing that covers the window it
/// is describing so that it can describe it. They are sections of `six://settings` now. History and
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
    }
}

private struct TopBar: View {
    var addressFocus: FocusState<UUID?>.Binding
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 8) {
            Color.clear.frame(width: 68, height: 1) // room for the window buttons
            ProfileMenuButton()
            Spacer(minLength: 8)
            // Against the field, not out with the rail's buttons. The star is about the page whose
            // address is right there — it fills for that page and ⌘D toggles it — and every browser
            // that has one keeps it at the end of the address field for exactly that reason. Out on
            // the right it sat among the things that describe the *strip*, and read as one of them.
            //
            // Which is also why it comes and goes with the field rather than outliving it. On an
            // empty workspace there is no focused window, the field is not drawn, and a star left
            // behind on its own is a control about nothing — greyed out, in the middle of the bar,
            // beside a page that says "New Window".
            if let tab = browser.selectedTab {
                AddressBar(tab: tab, addressFocus: addressFocus)
                    .frame(maxWidth: addressWidth)
                BookmarkButton(tab: tab)
                ShareButton(tab: tab)
            }
            Spacer(minLength: 8)
            DownloadsButton()
            ExtensionActionBar()
            WorkspaceStepper()
            Button { browser.toggleOverview() } label: {
                Image(systemName: layout.isOverview ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
            }
            .buttonStyle(.borderless)
            .help("Overview (⌥O)")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
        // The focused page's progress, along the bottom edge of the bar that carries its address —
        // where the hairline under a window's title bar used to be, before the description moved up
        // here and the window became the page. It replaces the divider rather than sitting beside
        // it: two lines a point apart is a border with a bug in it.
        .overlay(alignment: .bottom) {
            if let tab = browser.selectedTab, !tab.isDocument, tab.isLoading {
                LoadingLine(progress: tab.estimatedProgress, accent: accent(of: tab))
            } else {
                Divider()
            }
        }
        .animation(.easeOut(duration: 0.2), value: browser.selectedTab?.isLoading)
    }

    private func accent(of tab: BrowserTab) -> Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    /// A share of the window rather than a number of points: on a 5K panel a fixed field is a slot in
    /// the middle of nowhere, and on a laptop it crowds out the buttons on either side. The floor and
    /// the ceiling are the two places where a share stops being sensible.
    private var addressWidth: CGFloat {
        max(280, min(760, browser.layout.viewport.width * 0.4))
    }
}

/// The star: filled when the page this bar is describing is bookmarked; a click saves it (or forgets
/// it). It takes that window rather than reading the selection, because it is only ever drawn beside
/// that window's address — there is no state of this button that means "no window".
private struct BookmarkButton: View {
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
private struct ShareButton: View {
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

/// The workspace indicator with a chevron on each side, so the vertical stack is reachable by mouse.
private struct WorkspaceStepper: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 6) {
            Button { browser.focusWorkspace(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!layout.canFocusWorkspace(-1))
                .help("Workspace above (⌥↑)")
            WorkspacePips()
            Button { browser.focusWorkspace(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!layout.canFocusWorkspace(1))
                .help("Workspace below (⌥↓)")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// Vertical position in the workspace stack — niri's workspace indicator, laid out horizontally.
private struct WorkspacePips: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        HStack(spacing: 4) {
            ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { index, workspace in
                let current = index == layout.focusedWorkspaceIndex
                Capsule()
                    .fill(current ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.quaternary))
                    .frame(width: current ? 20 : 8, height: 6)
                    .overlay {
                        if workspace.isEmpty && !current {
                            Capsule().strokeBorder(.tertiary, lineWidth: 1)
                        }
                    }
                    .onTapGesture { browser.focusWorkspace(at: index) }
                    .help(workspace.isEmpty
                          ? String(localized: "\(layout.title(at: index)) (empty)")
                          : "\(layout.title(at: index)) · \(String(localized: "\(workspace.columns.count) windows"))")
            }
        }
        .animation(NiriLayout.switchAnimation, value: layout.focusedWorkspaceIndex)
    }
}
#endif
