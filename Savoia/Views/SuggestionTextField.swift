#if os(macOS)
import AppKit
import SwiftUI

/// Commands belong to the field editor, including after the window regains the keyboard.
/// SwiftUI's key handlers can lose that route while its TextField is being edited.
struct SuggestionTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let accent: Color
    let move: (Int) -> Bool
    let complete: () -> String?
    let submit: () -> Void
    let escape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.cell = Cell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        // StartPage draws its own focus outline around the whole search capsule.
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular) + 2)
        field.placeholderString = String(localized: "Search or enter address")
        field.setAccessibilityLabel(field.placeholderString)
        field.cell?.isScrollable = true
        field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.didFocus = { [weak coordinator = context.coordinator] field in
            coordinator?.didFocus(field)
        }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if let cell = field.cell as? Cell {
            cell.accent = NSColor(accent)
            if let editor = field.currentEditor() as? NSTextView { cell.style(editor) }
        }
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.string = text
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
        guard coordinator.wantsFocus != focused else { return }
        coordinator.wantsFocus = focused
        field.wantsFocus = focused
        // First-responder changes can notify the delegate; keep them out of SwiftUI's update pass.
        DispatchQueue.main.async { [weak field] in field?.applyFocus() }
    }

    final class Cell: NSTextFieldCell {
        var accent: NSColor = .controlAccentColor

        override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
            let editor = super.setUpFieldEditorAttributes(textObj)
            if let editor = editor as? NSTextView { style(editor) }
            return editor
        }

        func style(_ editor: NSTextView) {
            editor.insertionPointColor = accent
            let tint = accent
            // Match the plain SwiftUI field's tinted selection in both appearances.
            let selection = NSColor(name: nil) { appearance in
                var color = tint
                appearance.performAsCurrentDrawingAppearance {
                    if let rgb = tint.usingColorSpace(.sRGB) {
                        let base: CGFloat = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.35 : 1
                        color = NSColor(srgbRed: rgb.redComponent * 0.3 + base * 0.7,
                                        green: rgb.greenComponent * 0.3 + base * 0.7,
                                        blue: rgb.blueComponent * 0.3 + base * 0.7, alpha: 1)
                    }
                }
                return color
            }
            editor.selectedTextAttributes = [.backgroundColor: selection]
        }
    }

    final class Field: NSTextField {
        var wantsFocus = false
        var didFocus: ((Field) -> Void)?

        // NSTextField's didBeginEditing notification waits for a text change. A click or Tab
        // already gives it a caret, so the binding must follow first-responder acquisition too.
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { didFocus?(self) }
            return accepted
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if currentEditor() != nil { didFocus?(self) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.applyFocus() }
        }

        func applyFocus() {
            guard let window else { return }
            if wantsFocus {
                if currentEditor() == nil { window.makeFirstResponder(self) }
            } else if currentEditor() != nil {
                window.makeFirstResponder(nil)
                NSCursor.setHiddenUntilMouseMoves(false)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuggestionTextField
        var wantsFocus = false

        init(_ parent: SuggestionTextField) { self.parent = parent }

        func didFocus(_ field: Field) {
            wantsFocus = true
            field.wantsFocus = true
            parent.focused = true
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? Field { didFocus(field) }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            wantsFocus = false
            (notification.object as? Field)?.wantsFocus = false
            parent.focused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            // Leave IME composition and modified editing/navigation commands to AppKit.
            guard !textView.hasMarkedText(),
                  (NSApp.currentEvent?.modifierFlags ?? []).intersection([.command, .control, .option, .shift]).isEmpty
            else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): return parent.move(1)
            case #selector(NSResponder.moveUp(_:)): return parent.move(-1)
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveRight(_:)):
                guard let value = parent.complete() else { return false }
                control.stringValue = value
                textView.string = value
                textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
                parent.text = value
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.escape()
                // AppKit hides the pointer while handling text-field keystrokes. Escape ends
                // that interaction; restore it after the editor finishes handling the event.
                DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(false) }
                return true
            default: return false
            }
        }
    }
}
#endif
