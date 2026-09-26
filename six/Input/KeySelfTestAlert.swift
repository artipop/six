#if os(macOS) && DEBUG
import AppKit
import ObjectiveC
import WebKit

/// `SIX_KEY_SELFTEST=alert`: real key events in the browser, with AppKit's unhandled-key
/// endpoint observed as well as the DOM. Silence alone would also pass if a key were eaten.
extension KeySelfTest {
    static func alertOnly(_ browser: BrowserState) async {
        NSApp.activate()
        var testWindow: NSWindow?
        for _ in 0..<100 {
            testWindow = NSApp.keyWindow ?? NSApp.mainWindow
                ?? NSApp.windows.first { $0.canBecomeKey && $0.contentView != nil && !($0 is NSPanel) }
            if testWindow != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let window = testWindow else { return note("alert: FAIL no window") }
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(2))
        let originalStyle = browser.interfaceStyle
        let originalTab = browser.selectedTabID
        let original = class_getInstanceMethod(NSResponder.self, #selector(NSResponder.noResponder(for:)))!
        let observed = class_getInstanceMethod(NSResponder.self, #selector(NSResponder.six_alertNoResponder(for:)))!
        method_exchangeImplementations(original, observed)
        defer {
            method_exchangeImplementations(original, observed)
            browser.setInterfaceStyle(originalStyle)
            if let originalTab { browser.selectTab(originalTab) }
        }
        var failures = 0
        func check(_ passed: Bool, _ message: String) {
            if !passed { failures += 1 }
            note("alert: \(passed ? "PASS" : "FAIL") \(message)")
        }

        // A positive control: the observer must see the endpoint before its absence means anything.
        AlertObservation.count = 0
        NSResponder().noResponder(for: #selector(NSResponder.keyDown(with:)))
        check(AlertObservation.count == 1, "unhandled-key detector control")

        typealias Case = (name: String, html: String, setup: String, code: UInt16, text: String,
                          flags: NSEvent.ModifierFlags, count: Int, expected: String)
        let cases: [Case] = [
            ("Return on a short page", "short", "", 36, "\r", [], 1, "downs === 1"),
            ("Shift-Return on a short page", "short", "", 36, "\r", .shift, 1, "downs === 1"),
            ("keypad Enter on a short page", "short", "", 76, "\u{3}", [], 1, "downs === 1"),
            ("Space on a short page", "short", "", 49, " ", [], 1, "downs === 1"),
            ("Space with Caps Lock", "short", "", 49, " ", .capsLock, 1, "downs === 1"),
            ("Shift-Space on a short page", "short", "", 49, " ", .shift, 1, "downs === 1"),
            ("Space scrolls", "<div style='height:30000px'>tall</div>", "", 49, " ", [], 1, "scrollY > 0"),
            ("Shift-Space scrolls back", "<div style='height:30000px'>tall</div>", "scrollTo(0,3000)", 49, " ", .shift, 1, "scrollY < 3000"),
            ("Space at bottom", "<div style='height:30000px'>tall</div>", "scrollTo(0,99999)", 49, " ", [], 1, "downs === 1"),
            ("Space in input", "<input id=f>", "f.focus()", 49, " ", [], 1, "f.value === ' '"),
            ("Return submits form", "<form onsubmit='event.preventDefault(); submits++'><input id=f><button>go</button></form>", "f.focus()", 36, "\r", [], 1, "submits === 1"),
            ("keypad Enter submits form", "<form onsubmit='event.preventDefault(); submits++'><input id=f><button>go</button></form>", "f.focus()", 76, "\u{3}", [], 1, "submits === 1"),
            ("Return in textarea", "<textarea id=f></textarea>", "f.focus()", 36, "\r", [], 1, "f.value === '\\n'"),
            ("Shift-Return in textarea", "<textarea id=f></textarea>", "f.focus()", 36, "\r", .shift, 1, "f.value === '\\n'"),
            ("Space in contenteditable", "<div id=f contenteditable></div>", "f.focus()", 49, " ", [], 1, "f.textContent.length === 1"),
            ("Space activates button", "<button id=f onclick='clicks++'>go</button>", "f.focus()", 49, " ", [], 1, "clicks === 1"),
            ("Return activates button", "<button id=f onclick='clicks++'>go</button>", "f.focus()", 36, "\r", [], 1, "clicks === 1"),
            ("page cancels Return", "short", "document.onkeydown = e => { downs++; e.preventDefault() }", 36, "\r", [], 1, "downs === 1"),
            ("page cancels Space", "short", "document.onkeydown = e => { downs++; e.preventDefault() }", 49, " ", [], 1, "downs === 1"),
            ("rapid Return repeats", "short", "", 36, "\r", [], 20, "downs === 20"),
            ("rapid Space repeats", "short", "", 49, " ", [], 20, "downs === 20"),
            ("rapid typing spaces", "<input id=f>", "f.focus()", 49, " ", [], 20, "f.value.length === 20"),
            ("Escape on a short page", "short", "", 53, "\u{1b}", [], 1, "downs === 1"),
            ("Down on a short page", "short", "", 125, "\u{F701}", [], 1, "downs === 1"),
            ("Up on a short page", "short", "", 126, "\u{F700}", [], 1, "downs === 1"),
            ("Left on a short page", "short", "", 123, "\u{F702}", [], 1, "downs === 1"),
            ("Right on a short page", "short", "", 124, "\u{F703}", [], 1, "downs === 1"),
            ("Shift-Down on a short page", "short", "", 125, "\u{F701}", .shift, 1, "downs === 1"),
            ("Home on a short page", "short", "", 115, "\u{F729}", [], 1, "downs === 1"),
            ("End on a short page", "short", "", 119, "\u{F72B}", [], 1, "downs === 1"),
            ("Page Up on a short page", "short", "", 116, "\u{F72C}", [], 1, "downs === 1"),
            ("Page Down on a short page", "short", "", 121, "\u{F72D}", [], 1, "downs === 1"),
            ("Down scrolls", "<div style='height:30000px'>tall</div>", "", 125, "\u{F701}", [], 1, "scrollY > 0"),
            ("Left moves the caret", "<input id=f value=hello>", "f.focus(); f.setSelectionRange(5,5)", 123, "\u{F702}", [], 1, "f.selectionStart === 4")
        ]
        for style in [InterfaceStyle.tabs, .row] {
            browser.setInterfaceStyle(style)
            try? await Task.sleep(for: .milliseconds(800))
            let tab = browser.newTab(url: URL(string: "about:blank"))
            try? await Task.sleep(for: .milliseconds(1200))
            guard let web = WebViewResponder.shared.webView(for: tab.id) else {
                check(false, "\(style): no web view")
                browser.closeTab(tab.id, remembering: false)
                continue
            }
            for item in cases {
                do {
                    let html = String(data: try JSONSerialization.data(withJSONObject: [item.html]), encoding: .utf8)!
                    _ = try await tab.page.callJavaScript("""
                        document.body.innerHTML = \(html)[0];
                        window.downs = 0; window.ups = 0; window.clicks = 0; window.submits = 0; window.seen = [];
                        document.onkeydown = e => { downs++; seen.push(e.code) }; document.onkeyup = () => ups++;
                        scrollTo(0,0); \(item.setup)
                        """)
                    _ = window.makeFirstResponder(web)
                    try? await Task.sleep(for: .milliseconds(150))
                    AlertObservation.count = 0
                    for index in 0..<item.count {
                        for kind in [NSEvent.EventType.keyDown, .keyUp] {
                            if kind == .keyUp && index + 1 < item.count { continue }
                            // An arrow's scroll animates only while the key is down.
                            if kind == .keyUp { try? await Task.sleep(for: .milliseconds(200)) }
                            let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: item.flags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, characters: item.text, charactersIgnoringModifiers: item.text,
                                isARepeat: kind == .keyDown && index > 0, keyCode: item.code)!
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(550))
                    // WebKit handles posted events asynchronously. Read the assertion and its
                    // evidence together, and allow a busy web process time to finish the key.
                    var works = false
                    var state = "?"
                    for attempt in 0..<20 {
                        if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                        state = (try await tab.page.callJavaScript("""
                            return JSON.stringify({
                                works: (\(item.expected)) && downs === \(item.count) && ups === 1,
                                downs,ups,seen,clicks,submits,y:scrollY,value:document.getElementById('f')?.value
                            })
                            """)) as? String ?? "?"
                        let snapshot = try JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any]
                        works = snapshot?["works"] as? Bool == true
                        if works { break }
                    }
                    check(works && AlertObservation.count == 0, "\(style) \(item.name): alerts=\(AlertObservation.count), \(state)")
                } catch { check(false, "\(style) \(item.name): \(error)") }
            }
            await alertBrowserControls(browser, tab: tab, in: window, check: check)
            browser.closeTab(tab.id, remembering: false)
        }
        await alertNativeSheet(in: window, check: check)
        note("alert: DONE failures=\(failures)")
    }

    private static func alertBrowserControls(_ browser: BrowserState, tab: BrowserTab, in window: NSWindow,
                                             check: (Bool, String) -> Void) async {
        let style = browser.interfaceStyle
        func focus(_ id: UUID) async {
            browser.selectTab(id)
            try? await Task.sleep(for: .milliseconds(450))
            _ = window.makeFirstResponder(WebViewResponder.shared.webView(for: id))
        }
        func press(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) async {
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        // A second live page also exercises detaching and reattaching the web view in tab mode.
        let neighbor = browser.newTab(url: URL(string: "about:blank"))
        defer { browser.closeTab(neighbor.id, remembering: false) }
        await focus(tab.id)
        await focus(neighbor.id)
        await press(48, "\t", .control)
        check(browser.switcher.isOpen, "\(style) Control-Tab opens the switcher")
        let destination = browser.switcher.selection
        await press(36, "\r", .control)
        check(!browser.switcher.isOpen && destination != nil && browser.selectedTabID == destination,
              "\(style) Return confirms the switcher")
        browser.cancelWindowSwitch()
        await focus(neighbor.id)
        if style == .row {
            await press(123, "\u{F702}", .option)
            check(browser.selectedTabID == tab.id, "row Option-Left still handles WebKit's returned key")
            await focus(neighbor.id)
            _ = try? await neighbor.page.callJavaScript("document.body.innerHTML = '<input id=f value=hello>'; f.focus(); f.setSelectionRange(5,5)")
            await press(123, "\u{F702}", [.control, .option])
            check(browser.selectedTabID == tab.id, "row reserved Control-Option-Left still leaves a page field")
        }
        await focus(tab.id)
        do {
            _ = try await tab.page.callJavaScript("document.body.innerHTML = '<input id=f value=hello>'; f.focus(); f.setSelectionRange(5,5)")
            await press(123, "\u{F702}", .option)
            let caret = (try await tab.page.callJavaScript("return f.selectionStart")) as? Int
            check(browser.selectedTabID == tab.id && caret == 0, "\(style) Option-Left moves the page caret")
            _ = try await tab.page.callJavaScript("document.body.innerHTML = 'short'; window.downs = 0; document.onkeydown = () => downs++")
            AlertObservation.count = 0
            await press(36, "\r")
            let downs = (try await tab.page.callJavaScript("return downs")) as? Int
            check(downs == 1 && AlertObservation.count == 0, "\(style) reattached page still receives Return silently")
        } catch { check(false, "\(style) page caret / reattachment: \(error)") }

        // AppKit must still consider a window's default button before quieting the unhandled key.
        let actions = AlertNativeActions()
        let defaultButton = NSButton(title: "Keyboard test", target: actions, action: #selector(AlertNativeActions.submit(_:)))
        defaultButton.frame = NSRect(x: 20, y: 20, width: 160, height: 32)
        defaultButton.keyEquivalent = "\r"
        let originalDefault = window.defaultButtonCell
        window.contentView?.addSubview(defaultButton)
        window.defaultButtonCell = defaultButton.cell as? NSButtonCell
        try? await Task.sleep(for: .milliseconds(300))
        await press(36, "\r")
        check(actions.submissions == 1, "\(style) Return still reaches the native default button beside the page")
        window.defaultButtonCell = originalDefault
        defaultButton.removeFromSuperview()

        // A real menu key must still leave WebKit, and the native field must receive its own
        // Space and Return. The destination stays local and belongs to this test's page alone.
        // AppKit can deliver posted page keys to an inactive app, but its menu cannot resolve
        // focused scene values there. Wait for activation rather than calling that a dead shortcut.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<30 where !NSApp.isActive || !window.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard NSApp.isActive && window.isKeyWindow else {
            check(false, "\(style) could not activate the browser for menu keys")
            return
        }
        await focus(tab.id)
        note("alert: \(style) before Command-L: active=\(NSApp.isActive), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder)), sheet=\(window.attachedSheet != nil)")
        await press(37, "l", .command)
        guard let field = window.firstResponder as? NSTextView else {
            check(false, "\(style) Command-L focuses the address field")
            return
        }
        check(true, "\(style) Command-L focuses the address field")
        field.selectAll(nil)
        field.insertText("about:blank#alert", replacementRange: NSRange(location: NSNotFound, length: 0))
        AlertObservation.count = 0
        await press(49, " ")
        check(field.string == "about:blank#alert " && AlertObservation.count == 0, "\(style) Space types in the native address field")
        await press(36, "\r")
        check(tab.currentURL?.absoluteString == "about:blank#alert" && AlertObservation.count == 0,
              "\(style) Return submits the native address field")
    }

    private static func alertNativeSheet(in window: NSWindow, check: (Bool, String) -> Void) async {
        note("alert: native sheet starting")
        let parent = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 400, height: 230),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                            styleMask: [.titled], backing: .buffered, defer: false)
        let actions = AlertNativeActions()
        let field = NSTextField(frame: NSRect(x: 20, y: 100, width: 320, height: 24))
        field.target = actions
        field.action = #selector(AlertNativeActions.submit(_:))
        let text = NSTextView(frame: NSRect(x: 20, y: 15, width: 320, height: 65))
        sheet.contentView?.addSubview(field)
        sheet.contentView?.addSubview(text)
        parent.beginSheet(sheet, completionHandler: nil)
        defer { parent.endSheet(sheet); sheet.orderOut(nil); parent.close(); window.makeKeyAndOrderFront(nil) }
        sheet.makeFirstResponder(field)
        try? await Task.sleep(for: .milliseconds(300))
        AlertObservation.count = 0
        post(flags: [], rawCode: 49, characters: " ", in: sheet)
        try? await Task.sleep(for: .milliseconds(300))
        check(field.stringValue == " " && AlertObservation.count == 0, "native sheet field receives Space")
        post(flags: [], rawCode: 36, characters: "\r", in: sheet)
        try? await Task.sleep(for: .milliseconds(300))
        check(actions.submissions == 1 && AlertObservation.count == 0, "native sheet field receives Return")
        sheet.makeFirstResponder(text)
        post(flags: [], rawCode: 49, characters: " ", in: sheet)
        post(flags: [], rawCode: 36, characters: "\r", in: sheet)
        try? await Task.sleep(for: .milliseconds(300))
        check(text.string == " \n" && AlertObservation.count == 0, "native multiline field receives Space and newline")
    }
}

private final class AlertNativeActions: NSObject {
    var submissions = 0
    @objc func submit(_ sender: Any?) { submissions += 1 }
}

private enum AlertObservation {
    static var count = 0
    static var printedStack = false
}

extension NSResponder {
    @objc fileprivate func six_alertNoResponder(for selector: Selector) {
        if selector == #selector(NSResponder.keyDown(with:)) {
            AlertObservation.count += 1
            if !AlertObservation.printedStack, NSApp.currentEvent?.type == .keyDown {
                AlertObservation.printedStack = true
                KeySelfTest.note("alert: unhandled stack \(Thread.callStackSymbols.joined(separator: "\n"))")
            }
        }
        six_alertNoResponder(for: selector)
    }
}
#endif
