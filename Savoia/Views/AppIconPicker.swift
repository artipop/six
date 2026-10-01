#if os(macOS)
import SwiftUI

extension AppIconChoice {
    /// What the picture is — the family — and which of its versions this is.
    var title: String {
        switch self {
        case .automaticWings, .lightWings, .darkWings: String(localized: "Wings")
        case .automatic: String(localized: "Dawn & Dusk")
        case .light: String(localized: "Dawn")
        case .dark: String(localized: "Dusk")
        case .sky: String(localized: "Sky")
        }
    }

    var detail: String? {
        switch self {
        case .automaticWings, .automatic: String(localized: "Automatic")
        case .lightWings, .light: String(localized: "Light")
        case .darkWings, .dark: String(localized: "Dark")
        case .sky: nil
        }
    }

    var label: String { [title, detail].compactMap { $0 }.joined(separator: ", ") }
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
                        VStack(spacing: 1) {
                            Text(choice.title)
                                .font(.caption)
                                .foregroundStyle(settings.appIcon == choice ? .primary : .secondary)
                            Text(choice.detail ?? " ")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
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
