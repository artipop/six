import Foundation
import Observation

/// The arc a download draws from the click that asked for it to the button that now holds it.
///
/// A download happens somewhere else: the file is fetched in the background and the only sign is a
/// small button appearing in the corner of a bar nobody was looking at. The arc answers "did that
/// work?", and it doubles as the answer to "where did it go?", which is the more useful half. (A
/// ⌘-click has the same problem and a different answer — the strip leans over to show what arrived;
/// see `NiriLayout.peek`.)
///
/// The store knows where a flight starts. Where the button is on screen is the view's business, so
/// the button keeps saying (`note`) and a mark reads it when it is made.
@MainActor
@Observable
final class FlightStore {
    struct Flight: Identifiable {
        let id = UUID()
        /// Where the click was, in the window.
        let from: CGPoint
        /// Where it lands. Fixed when the mark is made: the arc is built from it, and a target that
        /// moved mid-flight would restart the animation.
        let to: CGPoint
    }

    private(set) var flights: [Flight] = []
    /// Bumped by every arrival, so the button can answer with a bounce.
    private(set) var landings = 0

    /// Where the button last said it was. Deliberately not observed: it is storage, read at the one
    /// moment a mark needs aiming, and a window being resized should not redraw anything for it.
    @ObservationIgnored private var buttonCentre: CGPoint?

    /// The button saying where it is, on every layout pass.
    func note(buttonCentre point: CGPoint) {
        buttonCentre = point
    }

    /// Sends one up. A nil origin means nobody clicked — an agent asked for this, or the pointer was
    /// not in the window — and then there is nothing to fly from and no flight.
    ///
    /// The origin is taken now, because the pointer is on the link now and will not be in a moment.
    /// The target is read a beat later: on the very first download the button does not exist yet, it
    /// comes into being with the row that flight is for.
    func launch(from origin: CGPoint?) {
        guard let origin else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, let to = buttonCentre else { return }
            let flight = Flight(from: origin, to: to)
            flights.append(flight)
            // The end of its life, scheduled now. The overlay normally takes it down on arrival; this
            // is for when nothing ever draws it — a window in fullscreen has no overlay — because a
            // mark nobody removes would sit in the list and take off late, on its own.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                self?.flights.removeAll { $0.id == flight.id }
            }
        }
    }

    func landed(_ id: Flight.ID) {
        guard flights.contains(where: { $0.id == id }) else { return }
        flights.removeAll { $0.id == id }
        landings += 1
    }
}
