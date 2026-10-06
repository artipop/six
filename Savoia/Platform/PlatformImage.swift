import AppKit
import SwiftUI

/// The one image type the shared code names. Thumbnails are the only picture Savoia holds of its own,
/// and the two frameworks agree on everything that needs: build it from PNG data, ask for the size,
/// hand it to SwiftUI.
typealias PlatformImage = NSImage

extension Image {
    init(platform image: PlatformImage) {
        self.init(nsImage: image)
    }
}

extension NSImage {
    var pngData: Data? {
        guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
