import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The mark at the top of Savoia's own pages, as chosen in Configuration ▸ General (`PageLogo`).
struct PageMark: View {
    let size: CGFloat
    var weight: Font.Weight = .light
    let color: Color

    @Environment(ConfigurationStore.self) private var settings

    var body: some View {
        switch settings.pageLogo {
        case .name:
            if !settings.pageName.isEmpty { name }
        case .icon:
            if let icon = Self.icon {
                // A share of the type size, so the icon and the name it replaces stand as tall.
                icon.resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 1.6, height: size * 1.6)
            } else {
                name
            }
        case .none:
            EmptyView()
        }
    }

    private var name: some View {
        Text(verbatim: settings.pageName)
            .font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private static let icon: Image? = {
        #if os(macOS)
        return Image(nsImage: NSApplication.shared.applicationIconImage)
        #else
        let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = (primary?["CFBundleIconFiles"] as? [String] ?? []).reversed() + ["AppIcon"]
        return names.lazy.compactMap { UIImage(named: $0) }.first.map { Image(uiImage: $0) }
        #endif
    }()
}
