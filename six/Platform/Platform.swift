#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import SwiftUI

/// The handful of things the shared code needs from the system that AppKit and UIKit spell
/// differently. Anything bigger than a spelling difference — windows, panels, file panels, global
/// event monitors — is not in here: it belongs to one platform and lives behind `#if os(macOS)`.
enum Platform {
    /// The pasteboard, for the "Copy Link" of every list.
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = string
        #endif
    }

    /// The area a sheet may size itself against. Layouts are written in fractions of this rather
    /// than in points, so a sheet is the same share of a 5K display and of a phone.
    static var screenSize: CGSize {
        #if os(macOS)
        NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        #elseif os(iOS)
        screenBounds.size
        #endif
    }

    #if os(iOS)
    /// There is no `UIScreen.main` any more — a screen is something a scene has, and an app can have
    /// scenes on more than one. The one the person is looking at is the foreground scene; an app with
    /// none on screen is asked this only to size something it is not showing, so any scene will do,
    /// and a plausible phone answers when there is not even one.
    static var screenBounds: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
    }
    #endif
}

extension Color {
    /// The paper a document window is written on: the same white a text field has, so the editor and
    /// the rendered preview are the same sheet.
    static var documentBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #elseif os(iOS)
        Color(uiColor: .systemBackground)
        #endif
    }
}
