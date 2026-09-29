import SwiftUI

/// The assistant's text mark, or a provider's own system icon.
struct AssistantSymbol: View {
    var systemImage: String? = nil

    var body: some View {
        if let systemImage {
            Image(systemName: systemImage)
        } else {
            Text(verbatim: "Ai")
                .fontWeight(.semibold)
                .fixedSize()
                .accessibilityLabel("Assistant")
        }
    }
}
