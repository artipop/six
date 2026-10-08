#if os(macOS)
import AppKit
import WebKit

/// `SAVOIA_DIALOGS_SELFTEST=1` — a page's dialogs answered the way a person does, by the sheet's own
/// buttons, and the way an agent does; each step says what the sheet and the page were left with.
enum DialogsSelfTest {
    private static let page = """
        <!doctype html><title>Dialogs selftest</title>
        <input type=file id=f style="position:fixed;left:40px;top:40px" onchange="window.r = [...this.files].map(f => f.name).join(',')">
        """

    static func run(_ browser: BrowserState) async {
        func say(_ line: String) { Log.info(.ui, "dialogs selftest: \(line)") }
        func until(_ seconds: Double = 3, _ done: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if done() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return done()
        }
        try? await Task.sleep(for: .milliseconds(600))
        let tab = browser.newTab(url: URL(string: "about:blank"))
        await tab.loadSettled()
        tab.page.loadHTMLString(page, baseURL: URL(string: "https://dialogs.selftest/"))
        try? await Task.sleep(for: .seconds(1))
        NSApp.activate()
        guard let window = tab.livePage?.window else { return say("the tab's page is in no window") }
        window.makeKeyAndOrderFront(nil)

        func sheet() -> String { window.attachedSheet.map { "\(type(of: $0))" } ?? "none" }
        func read() async -> String { ((try? await tab.callWithoutGesture("return String(window.r)", in: .page)) as? String) ?? "unread" }
        func press(_ characters: String, _ code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: (window.attachedSheet ?? window).windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
        let enter = { press("\r", 36) }

        /// Raises a dialog from a timer and waits for its sheet.
        func raise(_ script: String) async -> PageDialog? {
            // Not awaited: WebKit holds the call's reply while the dialog it raised is up.
            Task { _ = try? await tab.callWithoutGesture("window.r = 'unset'; setTimeout(() => { \(script) }, 0)", in: .page) }
            guard await until(3, { tab.dialogs.stoppingScript != nil }), let dialog = tab.dialogs.stoppingScript else {
                say("  no dialog came up for: \(script)")
                return nil
            }
            _ = await until(1) { window.attachedSheet != nil }
            return dialog
        }
        /// Waits for the answer; a dialog still open is taken down so the next step starts clean.
        func ending(_ label: String, _ dialog: PageDialog, expecting: String) async {
            let answered = await until { tab.dialogs.open.isEmpty }
            if !answered { dialog.resolve(.dismissed) }
            _ = await until(1) { window.attachedSheet == nil }
            var value = await read()
            let deadline = Date().addingTimeInterval(2)
            while value != expecting, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
                value = await read()
            }
            let verdict = answered && value == expecting && window.attachedSheet == nil ? "ok" : "FAILED"
            say("\(verdict) — \(label): \(answered ? "answered" : "the key never answered it"), page read \(value) (expected \(expecting)), sheet after \(sheet())")
        }
        func byKeys(_ label: String, _ script: String, expecting: String, _ keys: () -> Void) async {
            guard let dialog = await raise(script) else { return }
            say("  \(label): sheet \(sheet()), key window is the sheet \(NSApp.keyWindow === window.attachedSheet)")
            // A sheet still sliding out takes no keys.
            try? await Task.sleep(for: .milliseconds(700))
            keys()
            await ending(label, dialog, expecting: expecting)
        }

        func views<View: NSView>(_ kind: View.Type, in view: NSView?) -> [View] {
            guard let view else { return [] }
            return (view as? View).map { [$0] } ?? [] + view.subviews.flatMap { views(kind, in: $0) }
        }
        /// The sheet's button, pressed as a click presses it; a text goes in the field first.
        func byButton(_ label: String, _ script: String, expecting: String, title: String, typing text: String? = nil) async {
            guard let dialog = await raise(script) else { return }
            try? await Task.sleep(for: .milliseconds(700))
            let content = window.attachedSheet?.contentView
            if let text { views(NSTextField.self, in: content).first { $0.isEditable }?.stringValue = text }
            let buttons = views(NSButton.self, in: content)
            guard let button = buttons.first(where: { $0.title == title }) else {
                dialog.resolve(.dismissed)
                return say("FAILED — \(label): no \(title) among \(buttons.map(\.title))")
            }
            button.performClick(nil)
            await ending(label, dialog, expecting: expecting)
        }

        let ok = String(localized: "OK"), cancel = String(localized: "Cancel")
        say("a person's buttons")
        await byButton("confirm, OK", "window.r = confirm('Sure?')", expecting: "true", title: ok)
        await byButton("confirm, Cancel", "window.r = confirm('Sure?')", expecting: "false", title: cancel)
        await byButton("prompt, OK", "window.r = prompt('Name?', 'anon')", expecting: "anon", title: ok)
        await byButton("prompt, a text then OK", "window.r = prompt('Name?', 'anon')", expecting: "zed", title: ok, typing: "zed")
        await byButton("prompt, Cancel", "window.r = prompt('Name?', 'anon')", expecting: "null", title: cancel)
        await byButton("alert, OK", "alert('Hello'); window.r = 'after'", expecting: "after", title: ok)

        say("a person's keys")
        await byKeys("confirm, Return", "window.r = confirm('Sure?')", expecting: "true", enter)
        await byKeys("alert, Return", "alert('Hello'); window.r = 'after'", expecting: "after", enter)

        say("an agent's answer")
        if let dialog = await raise("window.r = confirm('Sure?')") {
            say("  confirm: sheet \(sheet())")
            dialog.resolve(.accepted(nil))
            await ending("confirm, accepted in code", dialog, expecting: "true")
        }
        if let dialog = await raise("window.r = prompt('Name?', 'anon')") {
            dialog.resolve(.accepted("agent"))
            await ending("prompt, a text in code", dialog, expecting: "agent")
        }

        say("the file chooser")
        func chooser() async -> PageDialog? {
            _ = try? await tab.callWithoutGesture("window.r = 'unset'", in: .page)
            tab.click(atViewport: CGPoint(x: 60, y: 50))
            guard await until(3, { tab.dialogs.fileChooser != nil }), let dialog = tab.dialogs.fileChooser else {
                say("  FAILED — a click on the input opened no chooser")
                return nil
            }
            _ = await until(2) { window.attachedSheet != nil }
            say("  chooser: sheet \(sheet())")
            return dialog
        }
        if let dialog = await chooser() {
            try? await Task.sleep(for: .milliseconds(700))
            (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
            await ending("chooser, its Cancel action", dialog, expecting: "unset")
        }
        if let dialog = await chooser() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dialogs-selftest.txt")
            try? Data("selftest".utf8).write(to: file)
            dialog.resolve(.files([file]))
            await ending("chooser, a file in code", dialog, expecting: "dialogs-selftest.txt")
            try? FileManager.default.removeItem(at: file)
        }

        say("a tab closed under its dialog")
        if await raise("window.r = confirm('Sure?')") != nil {
            say("  confirm: sheet \(sheet())")
            browser.closeTabs([tab.id])
            let gone = await until { window.attachedSheet == nil }
            say("\(gone ? "ok" : "FAILED") — closed tab: sheet after \(sheet())")
        } else {
            browser.closeTabs([tab.id])
        }
        say("done")
    }
}
#endif
