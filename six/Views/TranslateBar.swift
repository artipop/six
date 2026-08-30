import SwiftUI

/// What translating a page is doing, said where the page is — not in six pixels at the end of a URL.
///
/// The address field keeps the control, because that is where you go to *ask* for a translation.
/// This is for the answer, and only while the answer is worth a sentence: fetching a language can
/// take minutes, and `Translation.framework` gives no progress to show for it — no byte count, only
/// `status(from:to:)` and `isReady`. A spinner the size of a full stop, at the end of a long
/// address, is technically the truth and practically invisible; that is the complaint this exists
/// to answer.
///
/// A sibling of the web view in the column's stack, like `PermissionBar` and for the same reason:
/// it pushes the page down instead of covering it, so its button sees the mouse without going
/// through `HostedOverlay`.
struct TranslateBar: View {
    let tab: BrowserTab
    let state: TabTranslation

    @Environment(BrowserState.self) private var browser

    var body: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .downloading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                Text("Downloading \(AppleTranslator.name(of: state.target)) — this continues in the background")
                    .font(.caption)
            case .working(let done, let total):
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 90)
                Text("Translating into \(AppleTranslator.name(of: state.target))…")
                    .font(.caption)
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(why).font(.caption).lineLimit(2)
            default:
                EmptyView()
            }

            Spacer(minLength: 8)

            if case .failed = state.phase {
                Button("Try Again") { browser.toggleTranslation(of: tab) }
            } else {
                Button("Stop") { browser.stopTranslating(tab) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thickMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
