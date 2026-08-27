import Foundation
import Observation
import WebKit

/// One device a site can ask for.
///
/// WebKit asks about the camera and the microphone in a single question when a call wants both
/// (`WKMediaCaptureType.cameraAndMicrophone`). six asks that question once and writes *two* answers,
/// so a page that later wants the microphone alone is not asked a second time.
enum SitePermission: String, Codable, CaseIterable, Sendable, Identifiable {
    case camera
    case microphone
    /// `DeviceOrientationEvent` and `DeviceMotionEvent`. A desktop has neither sensor, but the
    /// question still arrives here, and answering it costs less than explaining the silence.
    case motion

    var id: String { rawValue }

    /// Lowercase on purpose: it is read inside a sentence ("wants to use your camera").
    var label: String {
        switch self {
        case .camera: String(localized: "camera")
        case .microphone: String(localized: "microphone")
        case .motion: String(localized: "motion sensors")
        }
    }

    var symbol: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .motion: "gyroscope"
        }
    }
}

/// What the user answered when a site asked for the camera, the microphone or the motion sensors —
/// and, while a question is on screen, the question itself.
///
/// **Why six answers at all.** A `WebPage` left alone answers `.prompt`: WebKit puts up a popover of
/// its own, the site gets its answer, and nothing is written down — so the same site asks again on
/// every load, and there is nowhere to take an answer back. Deciding the request ourselves is what
/// buys the memory and the undo; the bar under the window's title bar is the price.
///
/// An answer is filed under the *origin* (`https://example.com`, port and all), not the host: the
/// same host over plain HTTP is a different site, and the origin is the boundary the web platform
/// itself draws. WebKit hands us exactly that.
///
/// A private profile's answers live in memory for as long as the profile does and are never written
/// to the database — the point of the profile is that nothing about it survives it.
///
/// This is not the only gate. macOS holds the camera behind TCC, and its prompt — the one
/// `NSCameraUsageDescription` fills in — comes *first*: WebKit only calls this closure once the
/// system has been answered. So the first request a user ever makes costs two answers, one for the
/// app and one for the site, and every request after it costs at most one.
@MainActor
@Observable
final class SitePermissions {
    /// One remembered answer.
    struct Decision: Codable, Hashable, Sendable {
        var profileID: UUID
        var origin: String
        var permission: SitePermission
        var isAllowed: Bool
    }

    /// A question waiting for the user, drawn as a bar in the window that asked.
    struct Question: Identifiable {
        let id = UUID()
        let profileID: UUID
        /// `https://example.com` — what the answer is filed under.
        let origin: String
        /// Everything asked for at once: "camera and microphone" is one bar and two answers.
        let permissions: [SitePermission]
        fileprivate let pending: Pending

        /// What the bar shows. The origin without its scheme, which is what people call a site.
        var host: String {
            URL(string: origin)?.host() ?? origin
        }
    }

    /// Holds the suspended request. A class, and emptied on the first answer: the window can be
    /// closed while its bar is still up, and a continuation resumed twice is a crash.
    fileprivate final class Pending {
        var continuation: CheckedContinuation<Bool, Never>?

        func resume(_ allowed: Bool) {
            continuation?.resume(returning: allowed)
            continuation = nil
        }
    }

    /// Every answer six is holding, remembered ones and this session's private ones together.
    private(set) var decisions: [Decision]
    /// Questions per window, oldest first; the bar shows the first and the rest wait their turn.
    private(set) var queues: [UUID: [Question]] = [:]
    /// Whether a profile's answers may be written down; wired at launch to `BrowserState.isPrivate`.
    @ObservationIgnored var isPrivate: (UUID) -> Bool = { _ in false }
    @ObservationIgnored private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        self.decisions = settings.sitePermissions
    }

    // MARK: Answering the page

    /// The page is asking. Answers from memory when this site has been answered before, and
    /// otherwise puts the question on the window and waits for it.
    ///
    /// This is the closure behind `WebPage.Configuration.deviceSensorAuthorization`, so the page's
    /// `getUserMedia()` is suspended for exactly as long as the bar is up.
    func decide(_ permission: WebPage.DeviceSensorAuthorization.Permission,
                origin: WKSecurityOrigin,
                in windowID: UUID,
                profileID: UUID) async -> WKPermissionDecision {
        let asked = Self.permissions(for: permission)
        let origin = Self.string(for: origin)
        // Nothing to file an answer under (an opaque origin, a `data:` page): the safe answer is no.
        guard !asked.isEmpty, !origin.isEmpty else { return .deny }

        let known = asked.compactMap { decision(for: $0, origin: origin, profileID: profileID) }
        if known.count == asked.count {
            // One "no" among them is a no: a page that asked for the camera *and* the microphone was
            // asking for a call, and half a call is not what either answer meant.
            return known.allSatisfy { $0 } ? .grant : .deny
        }

        let pending = Pending()
        queues[windowID, default: []].append(
            Question(profileID: profileID, origin: origin, permissions: asked, pending: pending))
        let allowed = await withCheckedContinuation { continuation in
            // Nothing suspends between appending the question and this line, so the bar can never
            // be answered before there is a continuation for the answer to land in.
            pending.continuation = continuation
        }
        return allowed ? .grant : .deny
    }

    /// The question this window is showing, if any.
    func question(for windowID: UUID) -> Question? {
        queues[windowID]?.first
    }

    /// The bar's two buttons. Remembers the answer and lets the page go.
    func answer(_ allowed: Bool, for windowID: UUID) {
        guard var queue = queues[windowID], !queue.isEmpty else { return }
        let question = queue.removeFirst()
        queues[windowID] = queue.isEmpty ? nil : queue
        for permission in question.permissions {
            set(allowed, permission, forOrigin: question.origin, profileID: question.profileID)
        }
        question.pending.resume(allowed)
    }

    /// The window is closing, or its page is being given back: a question nobody can answer any more
    /// is answered no. Denying rather than dropping it is deliberate — the page is suspended on this
    /// call, and a promise that never lands is a page that never finds out.
    func forget(_ windowID: UUID) {
        guard let queue = queues.removeValue(forKey: windowID) else { return }
        for question in queue { question.pending.resume(false) }
    }

    // MARK: What has been decided

    func decision(for permission: SitePermission, origin: String, profileID: UUID) -> Bool? {
        decisions.first {
            $0.profileID == profileID && $0.origin == origin && $0.permission == permission
        }?.isAllowed
    }

    /// Everything decided about one site, for the menu under the window's site icon.
    func decisions(forOrigin origin: String, profileID: UUID) -> [SitePermission: Bool] {
        var found: [SitePermission: Bool] = [:]
        for decision in decisions where decision.profileID == profileID && decision.origin == origin {
            found[decision.permission] = decision.isAllowed
        }
        return found
    }

    /// One site in one profile — a row of the panel. The same origin can appear twice, answered
    /// differently in two profiles, so the identity is the pair and never the origin alone.
    struct Site: Identifiable, Hashable {
        let profileID: UUID
        let origin: String
        var id: String { "\(profileID)\u{1}\(origin)" }
    }

    /// Every site with a remembered answer, in the order they were first answered.
    var sites: [Site] {
        var seen: Set<Site> = []
        var result: [Site] = []
        for decision in decisions {
            let site = Site(profileID: decision.profileID, origin: decision.origin)
            guard seen.insert(site).inserted else { continue }
            result.append(site)
        }
        return result
    }

    /// Writes one answer down. Used by the bar, and by the menu when someone changes their mind.
    func set(_ allowed: Bool, _ permission: SitePermission, forOrigin origin: String, profileID: UUID) {
        if let index = decisions.firstIndex(where: {
            $0.profileID == profileID && $0.origin == origin && $0.permission == permission
        }) {
            decisions[index].isAllowed = allowed
        } else {
            decisions.append(Decision(profileID: profileID, origin: origin,
                                      permission: permission, isAllowed: allowed))
        }
        save()
    }

    /// Take it back: the site asks again the next time it needs the device.
    func forget(origin: String, profileID: UUID) {
        decisions.removeAll { $0.profileID == profileID && $0.origin == origin }
        save()
    }

    func forgetAll() {
        decisions.removeAll()
        save()
    }

    /// A profile is gone; so are the answers given inside it.
    func forgetProfile(_ profileID: UUID) {
        decisions.removeAll { $0.profileID == profileID }
        save()
    }

    private func save() {
        settings.sitePermissions = decisions.filter { !isPrivate($0.profileID) }
    }

    // MARK: Origins

    /// The origin as WebKit writes it: scheme, host, and the port only when there is one worth
    /// naming (WebKit reports 0 for a scheme's default).
    ///
    /// A `file:` page has no host, because WebKit gives every local file the same opaque origin.
    /// Filing them together under `file://` is not a shortcut — it is what that origin *is*, and it
    /// beats the alternative of denying a local page with no question asked.
    private static func string(for origin: WKSecurityOrigin) -> String {
        let scheme = origin.`protocol`
        guard !scheme.isEmpty else { return "" }
        guard !origin.host.isEmpty else { return "\(scheme)://" }
        let base = "\(scheme)://\(origin.host)"
        return origin.port == 0 ? base : "\(base):\(origin.port)"
    }

    /// The same string built from an address, so the title bar can look up what a window was
    /// answered without asking its page. Kept beside `string(for:)` because the two must agree.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return "\(scheme)://" }
        let base = "\(scheme)://\(host)"
        let standard = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        guard let port = url.port, port != standard else { return base }
        return "\(base):\(port)"
    }

    private static func permissions(
        for permission: WebPage.DeviceSensorAuthorization.Permission
    ) -> [SitePermission] {
        switch permission {
        case .deviceOrientationAndMotion:
            return [.motion]
        case .mediaCapture(let type):
            switch type {
            case .camera: return [.camera]
            case .microphone: return [.microphone]
            case .cameraAndMicrophone: return [.camera, .microphone]
            @unknown default: return []
            }
        @unknown default:
            // A sensor six has never heard of is not one it can describe in a question.
            return []
        }
    }
}
