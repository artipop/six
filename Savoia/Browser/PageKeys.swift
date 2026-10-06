#if os(macOS)
import AppKit
import WebKit

/// A key as a page names it (`KeyboardEvent.key`), with what AppKit needs to say the same thing.
struct PageKey {
    let code: UInt16
    let characters: String
    var modifier: NSEvent.ModifierFlags?
    var isShifted = false

    private static let named: [String: (UInt16, String)] = [
        "Enter": (36, "\r"), "Tab": (48, "\t"), "Space": (49, " "), " ": (49, " "), "Backspace": (51, "\u{7F}"),
        "Escape": (53, "\u{1B}"), "Delete": (117, "\u{F728}"), "Home": (115, "\u{F729}"), "End": (119, "\u{F72B}"),
        "PageUp": (116, "\u{F72C}"), "PageDown": (121, "\u{F72D}"), "ArrowLeft": (123, "\u{F702}"),
        "ArrowRight": (124, "\u{F703}"), "ArrowDown": (125, "\u{F701}"), "ArrowUp": (126, "\u{F700}"),
    ]
    private static let modifiers: [String: (UInt16, NSEvent.ModifierFlags)] = [
        "Meta": (55, .command), "Shift": (56, .shift), "Alt": (58, .option), "Control": (59, .control),
    ]
    /// The ANSI layout by key code; a space where the code is not a character key.
    private static let plain = Array("asdfhgzxcv bqweryt123465=97-80]ou[ip lj'k;\\,/nm.  `")
    private static let shifted = Array("ASDFHGZXCV BQWERYT!@#$^%+(&_*)}OU{IP LJ\"K:|<?NM>  ~")

    init?(_ name: String) {
        if let (code, characters) = Self.named[name] {
            self.code = code
            self.characters = characters
        } else if let (code, flag) = Self.modifiers[name] {
            self.code = code
            characters = ""
            modifier = flag
        } else if name.count == 1, let character = name.first, character != " ",
                  let index = Self.plain.firstIndex(of: character) ?? Self.shifted.firstIndex(of: character) {
            code = UInt16(index)
            characters = name
            isShifted = Self.plain[index] != character
        } else {
            return nil
        }
    }
}

extension NSEvent.ModifierFlags {
    /// `Meta+Shift`, in the names `KeyboardEvent.key` gives the modifiers.
    init(pageKeys names: String) {
        self = names.split(separator: "+").reduce(into: []) { flags, name in
            if let flag = PageKey(String(name))?.modifier { flags.insert(flag) }
        }
    }
}

extension WKWebView {
    /// The Edit menu's keys. WebKit hands them to the menu bar, which leaves Paste greyed out on a
    /// page with nothing editable; sent as the menu's action, the page gets its `paste` either way.
    private static let editing: [String: Selector] = [
        "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
        "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
    ]

    /// A key going down or up, as an event handed to the view: trusted, and with WebKit's own
    /// default action. False when the view is in no window.
    @discardableResult
    func key(_ key: PageKey, down: Bool, holding held: NSEvent.ModifierFlags = []) -> Bool {
        guard let window else { return false }
        if held.intersection([.command, .control, .option, .shift]) == .command, let action = Self.editing[key.characters] {
            return !down || NSApp.sendAction(action, to: self, from: nil)
        }
        var flags = held
        if key.isShifted { flags.insert(.shift) }
        if let modifier = key.modifier {
            if down { flags.insert(modifier) } else { flags.remove(modifier) }
        }
        let type: NSEvent.EventType = key.modifier != nil ? .flagsChanged : down ? .keyDown : .keyUp
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) else { return false }
        switch type {
        case .flagsChanged: flagsChanged(with: event)
        case .keyDown: keyDown(with: event)
        default: keyUp(with: event)
        }
        return true
    }

    @discardableResult
    func press(_ key: PageKey, holding held: NSEvent.ModifierFlags = []) -> Bool {
        self.key(key, down: true, holding: held) && self.key(key, down: false, holding: held)
    }
}
#endif
