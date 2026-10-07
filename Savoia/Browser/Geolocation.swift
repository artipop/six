#if os(macOS)
import CoreLocation
import WebKit

/// Where the positions pages ask for come from: WebKit decides who may ask, and expects the app to supply.
/// [permissions.md](../../docs/permissions.md#geolocation) has the C API this stands on.
final class Geolocation: NSObject, CLLocationManagerDelegate {
    static let shared = Geolocation()

    struct Position: Equatable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        var altitude: Double?
        var altitudeAccuracy: Double?
        var heading: Double?
        var speed: Double?
    }

    /// What stands in for CoreLocation.
    enum Override: Equatable {
        case position(Position)
        case unavailable
    }

    var override: Override? {
        didSet { if override != oldValue, !updating.isEmpty { report() } }
    }

    /// Kept alive: a manager is only as good as its pool.
    private var pools: [NSObject] = []
    private var updating: Set<OpaquePointer> = []
    private var location: CLLocationManager?
    /// CoreLocation's word: nothing yet, a position, or `.unavailable`.
    private var last: Override?
    private var repeating: Timer?

    /// Idempotent per process pool; called for every configuration a tab is built on.
    func serve(_ configuration: WKWebViewConfiguration) {
        // KVC: the property is deprecated for making pools, not for reading the one there is.
        guard let pool = configuration.value(forKey: "processPool") as? NSObject,
              !pools.contains(where: { $0 === pool }) else { return }
        pools.append(pool)
        // On Apple's ports a WKContextRef is the process pool object itself.
        let context = OpaquePointer(Unmanaged.passUnretained(pool).toOpaque())
        guard let manager = WKContextGetGeolocationManager(context) else { return }
        var provider = WKGeolocationProviderV1(
            base: WKGeolocationProviderBase(version: 1, clientInfo: nil),
            startUpdating: { manager, _ in MainActor.assumeIsolated { Geolocation.shared.start(manager) } },
            stopUpdating: { manager, _ in MainActor.assumeIsolated { Geolocation.shared.stop(manager) } },
            setEnableHighAccuracy: { _, enabled, _ in MainActor.assumeIsolated { Geolocation.shared.setHighAccuracy(enabled) } })
        withUnsafePointer(to: &provider) {
            $0.withMemoryRebound(to: WKGeolocationProviderBase.self, capacity: 1) {
                WKGeolocationManagerSetProvider(manager, $0)
            }
        }
    }

    // MARK: What WebKit asks

    private func start(_ manager: OpaquePointer?) {
        guard let manager else { return }
        updating.insert(manager)
        Log.info(.pages, "geolocation: a page started watching")
        // A request made while another is being served waits for the next position, so there has to be one.
        if repeating == nil {
            repeating = .scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { Geolocation.shared.report() }
            }
        }
        guard source == .system else { return report() }
        let location = self.location ?? CLLocationManager()
        if self.location == nil {
            location.delegate = self
            self.location = location
        }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        location.startUpdatingLocation()
        report()
    }

    private func stop(_ manager: OpaquePointer?) {
        guard let manager else { return }
        updating.remove(manager)
        guard updating.isEmpty else { return }
        location?.stopUpdatingLocation()
        repeating?.invalidate()
        repeating = nil
    }

    private func setHighAccuracy(_ enabled: Bool) {
        location?.desiredAccuracy = enabled ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
    }

    // MARK: What it is told

    private enum Source { case system, stand }

    /// The test driver never reads the Mac's own position: a test must not learn where it runs.
    private var source: Source { override != nil || TestDriver.isOn ? .stand : .system }

    private func report() {
        // The stand with nothing set is a place that cannot be found, not the Mac's.
        guard let known = source == .system ? last : override ?? .unavailable else { return }
        for manager in updating {
            guard case .position(let position) = known else {
                WKGeolocationManagerProviderDidFailToDeterminePosition(manager)
                continue
            }
            let made = WKGeolocationPositionCreate_b(
                Date().timeIntervalSince1970, position.latitude, position.longitude, position.accuracy,
                position.altitude != nil, position.altitude ?? 0,
                position.altitudeAccuracy != nil, position.altitudeAccuracy ?? 0,
                position.heading != nil, position.heading ?? 0,
                position.speed != nil, position.speed ?? 0)
            WKGeolocationManagerProviderDidChangePosition(manager, made)
            WKRelease(UnsafeRawPointer(made))
        }
    }

    // MARK: CoreLocation

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let found = locations.last else { return }
        last = .position(Position(latitude: found.coordinate.latitude, longitude: found.coordinate.longitude,
                        accuracy: max(found.horizontalAccuracy, 0),
                        altitude: found.verticalAccuracy >= 0 ? found.altitude : nil,
                        altitudeAccuracy: found.verticalAccuracy >= 0 ? found.verticalAccuracy : nil,
                        heading: found.course >= 0 ? found.course : nil,
                        speed: found.speed >= 0 ? found.speed : nil))
        if source == .system { report() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Log.info(.pages, "geolocation: \(error.localizedDescription)")
        // `locationUnknown` is "not yet"; CoreLocation keeps trying.
        guard (error as? CLError)?.code != .locationUnknown else { return }
        last = .unavailable
        if source == .system { report() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted else { return }
        last = .unavailable
        if source == .system { report() }
    }
}
#endif
