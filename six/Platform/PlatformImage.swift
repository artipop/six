#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

/// The one image type the shared code names. Thumbnails are the only picture six holds of its own,
/// and the two frameworks agree on everything that needs: build it from PNG data, ask for the size,
/// hand it to SwiftUI.
#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platform image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}
