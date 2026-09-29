#if os(macOS)
import SwiftUI

/// Draws what `FlightStore` has in the air: the arc from a click to the downloads button.
///
/// An overlay over the strip, never hit-testable: it is a picture of an event, not a control. Both
/// ends are measured in the window (the click by AppKit against the content view, the button by
/// SwiftUI in `.global`), and the overlay subtracts its own origin from each, because the top bar is
/// outside its safe area and the button lives up there.
struct FlightsOverlay: View {
    @Environment(BrowserState.self) private var browser
    @State private var box = CGRect.zero

    var body: some View {
        ZStack {
            // Fills the overlay whatever else is in here. Without it the stack has no children
            // between flights, sizes itself to nothing, and is then measured as a zero-sized box in
            // the middle of the overlay — so a mark is placed against a frame that is not the
            // overlay's, and flies from and to the wrong points.
            Color.clear
            ForEach(browser.flights.flights) { flight in
                FlightMark(from: place(flight.from), to: place(flight.to),
                           accent: browser.selectedProfile.color)
                    .task {
                        try? await Task.sleep(for: .milliseconds(620))
                        browser.flights.landed(flight.id)
                    }
            }
        }
        .allowsHitTesting(false)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box = $0 }
    }

    private func place(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - box.minX, y: point.y - box.minY)
    }
}

/// One mark in flight. The horizontal and the vertical are animated on tracks of their own — that is
/// what makes it an arc rather than a diagonal: it carries on outward while it is already rising, the
/// way something thrown does.
private struct FlightMark: View {
    let from: CGPoint
    let to: CGPoint
    let accent: Color

    private struct Phase {
        var x: Double
        var y: Double
        var scale: Double
        var opacity: Double
    }

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 26))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, accent)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .keyframeAnimator(
                initialValue: Phase(x: from.x, y: from.y, scale: 0.4, opacity: 0),
                repeating: false
            ) { content, phase in
                content
                    .scaleEffect(phase.scale)
                    .opacity(phase.opacity)
                    .position(x: phase.x, y: phase.y)
            } keyframes: { _ in
                KeyframeTrack(\.x) {
                    CubicKeyframe(from.x, duration: 0.06)
                    CubicKeyframe(to.x, duration: 0.5)
                }
                // Up past the button and back down onto it: the overshoot is what reads as a throw.
                KeyframeTrack(\.y) {
                    SpringKeyframe(from.y - 26, duration: 0.2, spring: .bouncy)
                    CubicKeyframe(to.y - 14, duration: 0.28)
                    SpringKeyframe(to.y, duration: 0.08, spring: .snappy)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1, duration: 0.14, spring: .bouncy)
                    CubicKeyframe(0.75, duration: 0.32)
                    CubicKeyframe(0.35, duration: 0.1)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.38)
                    LinearKeyframe(0, duration: 0.1)
                }
            }
    }
}
#endif
