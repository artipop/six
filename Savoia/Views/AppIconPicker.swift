#if os(macOS)
import SwiftUI

extension AppIconChoice {
    var title: String {
        switch self {
        case .sky: String(localized: "Sky")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        case .lightWings: String(localized: "Light Wings")
        case .darkWings: String(localized: "Dark Wings")
        case .automatic: String(localized: "Automatic")
        case .automaticWings: String(localized: "Automatic Wings")
        }
    }
}

/// The icons Savoia can wear, as tiles; the chosen one is ringed.
struct AppIconPicker: View {
    @Environment(ConfigurationStore.self) private var settings

    private var tile: CGFloat { max(64, min(112, Platform.screenSize.width * 0.045)) }

    var body: some View {
        @Bindable var settings = settings
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile + 16), spacing: 12, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(AppIconChoice.allCases) { choice in
                Button { settings.appIcon = choice } label: {
                    VStack(spacing: 6) {
                        preview(of: choice)
                            .frame(width: tile, height: tile)
                            .padding(4)
                            .overlay {
                                RoundedRectangle(cornerRadius: tile * 0.24)
                                    .strokeBorder(Color.accentColor, lineWidth: settings.appIcon == choice ? 2.5 : 0)
                            }
                        Text(choice.title)
                            .font(.caption)
                            .foregroundStyle(settings.appIcon == choice ? .primary : .secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(settings.appIcon == choice ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func preview(of choice: AppIconChoice) -> some View {
        let icons = AppIconController.shared
        switch choice {
        case .automatic, .automaticWings:
            let wings = choice == .automaticWings
            ZStack {
                Image(nsImage: icons.image(for: wings ? .lightWings : .light)).resizable()
                Image(nsImage: icons.image(for: wings ? .darkWings : .dark)).resizable()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black, location: 0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        default:
            Image(nsImage: icons.image(for: choice)).resizable()
        }
    }
}
#endif
