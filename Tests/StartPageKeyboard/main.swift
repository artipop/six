import AppKit
import SwiftUI
import ObjectiveC

// Standalone AppKit integration test: compile with six/Views/SuggestionTextField.swift.
// Posts real key events through the app's queue; no Accessibility permission required.
@MainActor
@Observable
final class Model {
    var text = "git"
    var focused = true
    var selection: Int?
    var submits = 0
    var accent: Color = .purple
    let rows = ["https://github.com/", "https://gitlab.com/"]

    func move(_ step: Int) -> Bool {
        let next = (selection ?? -1) + step
        selection = next < 0 ? nil : min(next, rows.count - 1)
        return true
    }

    func complete() -> String? {
        guard let selection else { return nil }
        self.selection = nil
        return rows[selection]
    }
}

struct Harness: View {
    @Bindable var model: Model

    var body: some View {
        VStack {
            SuggestionTextField(text: $model.text, focused: $model.focused, accent: model.accent,
                                move: model.move, complete: model.complete,
                                submit: { model.submits += 1 },
                                escape: {
                                    if model.text.isEmpty { model.focused = false }
                                    else { model.text = ""; model.selection = nil }
                                })
            TextField("Another field", text: .constant("elsewhere"))
                .textFieldStyle(.plain)
                .font(.title3)
        }
        .padding()
        .frame(width: 480, height: 100)
        .tint(model.accent)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let model = MainActor.assumeIsolated { Model() }
let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 100),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.contentView = NSHostingView(rootView: Harness(model: model))
window.makeKeyAndOrderFront(nil)
app.activate()

@MainActor
func pause() async { try? await Task.sleep(for: .milliseconds(200)) }

@MainActor
func press(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) async {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: false, keyCode: code)!
    app.postEvent(event, atStart: false)
    await pause()
}

func arrow(_ scalar: Int) -> String { String(UnicodeScalar(scalar)!) }

@MainActor
func fields(_ view: NSView) -> [NSTextField] {
    if let field = view as? NSTextField { return [field] }
    return view.subviews.flatMap(fields)
}

@MainActor
func click(_ point: NSPoint) async {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      eventNumber: type == .leftMouseDown ? 1 : 2, clickCount: 1,
                                      pressure: type == .leftMouseDown ? 1 : 0)!
        app.postEvent(event, atStart: false)
    }
    await pause()
}

// Observe the public cursor API: Escape must undo AppKit's hide-until-mouse-moves state.
var pointerHiddenUntilMove = false
extension NSCursor {
    @objc class func recordHiddenUntilMouseMoves(_ hidden: Bool) {
        MainActor.assumeIsolated { pointerHiddenUntilMove = hidden }
        recordHiddenUntilMouseMoves(hidden)
    }
}
method_exchangeImplementations(
    class_getClassMethod(NSCursor.self, #selector(NSCursor.setHiddenUntilMouseMoves(_:)))!,
    class_getClassMethod(NSCursor.self, #selector(NSCursor.recordHiddenUntilMouseMoves(_:)))!)

var failures = 0
func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
    guard let lhs = lhs?.usingColorSpace(.sRGB), let rhs = rhs?.usingColorSpace(.sRGB) else { return false }
    return abs(lhs.redComponent - rhs.redComponent) < 0.005
        && abs(lhs.greenComponent - rhs.greenComponent) < 0.005
        && abs(lhs.blueComponent - rhs.blueComponent) < 0.005
        && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.005
}

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: \(label)") }
    else { print("FAIL: \(label)"); failures += 1 }
}

Task { @MainActor in
    await pause()
    check(window.firstResponder is NSTextView, "field owns the keyboard on opening")
    await press(125, arrow(NSDownArrowFunctionKey), flags: [.function, .numericPad])
    check(model.selection == 0, "Down selects the first suggestion")
    await press(48, "\t")
    check(model.text == model.rows[0], "Tab fills the selected URL")
    check(model.submits == 0, "completion does not navigate")
    check((window.firstResponder as? NSTextView)?.selectedRange() == NSRange(location: model.text.utf16.count, length: 0),
          "Tab retains the editor with the caret at the end")
    await press(0, "x")
    check(model.text == model.rows[0] + "x", "typing continues after the completed URL")

    model.text = "git"
    await pause()
    await press(125, arrow(NSDownArrowFunctionKey))
    await press(125, arrow(NSDownArrowFunctionKey))
    check(model.selection == 1, "Down reaches the second suggestion")
    await press(126, arrow(NSUpArrowFunctionKey))
    check(model.selection == 0, "Up selects the previous suggestion")
    await press(124, arrow(NSRightArrowFunctionKey), flags: [.function, .numericPad])
    check(model.text == model.rows[0], "Right fills the selected URL")

    model.text = "git"
    await pause()
    app.deactivate()
    await pause()
    app.activate()
    window.makeKeyAndOrderFront(nil)
    await pause()
    await press(125, arrow(NSDownArrowFunctionKey))
    check(model.selection == 0, "Down still works after app deactivation and reactivation")
    await press(48, "\t")
    check(model.text == model.rows[0], "Tab still completes after reactivation")

    // Exercise the shared field editor leaving this control and returning to it too.
    window.makeFirstResponder(nil)
    await pause()
    model.focused = true
    model.text = "git"
    await pause()
    await press(125, arrow(NSDownArrowFunctionKey))
    await press(124, arrow(NSRightArrowFunctionKey))
    check(model.text == model.rows[0], "completion survives ending and restarting editing")

    model.selection = 0
    await press(124, arrow(NSRightArrowFunctionKey), flags: [.shift])
    check(model.selection == 0, "Shift-Right does not accept a suggestion")
    model.selection = nil
    await press(123, arrow(NSLeftArrowFunctionKey))
    let before = (window.firstResponder as? NSTextView)?.selectedRange().location
    await press(124, arrow(NSRightArrowFunctionKey))
    check((window.firstResponder as? NSTextView)?.selectedRange().location == before.map { $0 + 1 },
          "Right moves the caret normally without a selected suggestion")
    await press(36, "\r")
    check(model.submits == 1, "Return submits once")
    NSCursor.setHiddenUntilMouseMoves(true)
    await press(53, "\u{1b}")
    check(model.text.isEmpty, "Escape clears the field")
    check(!pointerHiddenUntilMove, "Escape restores the mouse pointer after clearing text")
    NSCursor.setHiddenUntilMouseMoves(true)
    await press(53, "\u{1b}")
    check(!(window.firstResponder is NSTextView), "Escape in an empty field releases focus")
    check(!pointerHiddenUntilMove, "Escape restores the mouse pointer after releasing focus")

    if let reference = fields(window.contentView!).first(where: { !($0 is SuggestionTextField.Field) }),
       let native = fields(window.contentView!).first(where: { $0 is SuggestionTextField.Field }) {
        let fieldPoint = native.convert(NSPoint(x: native.bounds.midX, y: native.bounds.midY), to: nil)
        for attempt in 1...3 {
            await click(fieldPoint)
            check(native.currentEditor() != nil, "click \(attempt) focuses the field without typing")
            check(model.focused, "click \(attempt) updates the focus binding without typing")
            // The same state change as StartPage's background onTapGesture. The important case
            // is a click into the field with no text change before requesting dismissal.
            model.focused = false
            await pause()
            check(!model.focused && native.currentEditor() == nil,
                  "background dismissal \(attempt) removes the caret without typing first")
        }
        await click(fieldPoint)
        await press(53, "\u{1b}")
        check(!model.focused && native.currentEditor() == nil, "Escape releases a clicked empty field without typing first")

        await click(fieldPoint)
        await press(48, "\t")
        check(!model.focused && native.currentEditor() == nil, "Tab leaves an unedited field when no suggestion is selected")
        await press(48, "\t", flags: [.shift])
        check(model.focused && native.currentEditor() != nil, "Shift-Tab restores focus without typing")
        await press(53, "\u{1b}")
        check(!model.focused && native.currentEditor() == nil, "Escape releases the field after keyboard focus traversal")

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            await pause()
            window.makeFirstResponder(native)
            await pause()
            let nativeEditor = window.firstResponder as? NSTextView
            let nativeCaret = nativeEditor?.insertionPointColor
            let nativeSelection = nativeEditor?.selectedTextAttributes[.backgroundColor] as? NSColor
            let nativeText = nativeEditor?.textColor
            let nativeFontSize = nativeEditor?.font?.pointSize
            window.makeFirstResponder(reference)
            await pause()
            guard let editor = window.firstResponder as? NSTextView else {
                check(false, "reference field has an editor")
                continue
            }
            check(native.focusRingType == .none, "no extra AppKit focus ring")
            check(nativeFontSize == editor.font?.pointSize, "font size matches the original SwiftUI field")
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                check(sameColor(nativeCaret, editor.insertionPointColor), "caret matches SwiftUI in \(name.rawValue)")
                check(sameColor(nativeSelection, editor.selectedTextAttributes[.backgroundColor] as? NSColor),
                      "selection matches SwiftUI in \(name.rawValue)")
                check(sameColor(nativeText, editor.textColor), "text matches SwiftUI in \(name.rawValue)")
            }
        }
    } else {
        check(false, "both fields are available for the appearance comparison")
    }

    print("\(failures) failures")
    exit(failures == 0 ? 0 : 1)
}
app.run()
