import SwiftUI

/// The loading line, drawn by hand: a linear `ProgressView` brings a track and a thickness of its
/// own, and a browser wants a hairline the page seems to push along, not a control.
///
/// It is what a page arriving has always looked like, and the reason it is a line rather than the
/// spinner that briefly replaced it: a determinate circle at the end of an address is six pixels of
/// pie chart, too small to read as progress and easy to take for a full stop. A line has the width
/// of the thing it is describing, which is the only reason anybody notices it moving.
///
/// Two places draw one. The top bar draws it under the address field, for the window you are
/// reading; every other window draws its own across the top of its card, because that is the one
/// thing a neighbour still has to be able to say for itself.
struct LoadingLine: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(accent)
                .frame(width: max(3, proxy.size.width * min(max(progress, 0.03), 1)))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
        .transition(.opacity)
    }
}
