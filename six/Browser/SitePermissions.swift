import Foundation
import Observation
#if canImport(WebKit)
import WebKit
#endif

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
        #if os(Linux)
        // `String(localized:)` and the strings catalog behind it are Apple Foundation's; a GTK front
        // localises through gettext, so these are the keys and it translates them itself.
        switch self {
        case .camera: "camera"
        case .microphone: "microphone"
        case .motion: "motion sensors"
        }
        #else
        switch self {
        case .camera: String(localized: "camera")
        case .microphone: String(localized: "microphone")
        case .motion: String(localized: "motion sensors")
        }
        #endif
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

    /// How the answer gets back to the page. A class, and emptied on the first answer: the window
    /// can be closed while its bar is still up, and a continuation resumed twice is a crash.
    ///
    /// A closure rather than the continuation itself, because there are two ways back. Apple's front
    /// suspends the page inside `deviceSensorAuthorization` and wants the continuation resumed;
    /// WebKitGTK keeps the request object and wants a call later. Both are "hand this answer over
    /// once", so both are this.
    fileprivate final class Pending {
        var answer: ((Bool) -> Void)?

        func resume(_ allowed: Bool) {
            let answer = self.answer
            self.answer = nil
            answer?(allowed)
        }
    }

    /// Every answer six is holding, remembered ones and this session's private ones together.
    private(set) var decisions: [Decision]
    /// Questions per window, oldest first; the bar shows the first and the rest wait their turn.
    private(set) var queues: [UUID: [Question]] = [:]
    /// Whether a profile's answers may be written down; wired at launch to `BrowserState.isPrivate`.
    @ObservationIgnored var isPrivate: (UUID) -> Bool = { _ in false }
    /// Told when a question is asked or answered, for a front that does not watch this object.
    ///
    /// SwiftUI does watch it — `@Observable` is exactly this, and on Apple nothing sets this and
    /// nothing calls back. Adwaita has no equivalent: it re-renders when a view's own state is
    /// assigned, and a question arriving from a C signal assigns nothing. So the one thing the Mac
    /// gets for free is said out loud here.
    @ObservationIgnored var onQuestionsChanged: (() -> Void)?
    @ObservationIgnored private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        self.decisions = settings.sitePermissions
    }

    // MARK: Answering the page

    #if canImport(WebKit)
    /// The page is asking, in WebKit's own vocabulary. Everything past the translation is
    /// `decide(_:origin:in:profileID:)`, which is the same on both platforms.
    ///
    /// This is the closure behind `WebPage.Configuration.deviceSensorAuthorization`, so the page's
    /// `getUserMedia()` is suspended for exactly as long as the bar is up.
    func decide(_ permission: WebPage.DeviceSensorAuthorization.Permission,
                origin: WKSecurityOrigin,
                in windowID: UUID,
                profileID: UUID) async -> WKPermissionDecision {
        let allowed = await decide(Self.permissions(for: permission),
                                   origin: Self.string(for: origin),
                                   in: windowID, profileID: profileID)
        return allowed ? .grant : .deny
    }
    #endif

    /// The page is asking, and the caller would rather be suspended than called back.
    func decide(_ asked: [SitePermission], origin: String,
                in windowID: UUID, profileID: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            decide(asked, origin: origin, in: windowID, profileID: profileID) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// The page is asking. Answers from memory when this site has been answered before, and
    /// otherwise puts the question on the window and calls back when it has been answered.
    ///
    /// Says nothing about *who* asked. WebKit on Apple and WebKitGTK on Linux describe a request in
    /// different types, but by the time either reaches here it has said only what was asked for and
    /// by which origin — and an answer depends on nothing else. So the memory and the queue are
    /// written once, and each platform brings its own translation.
    ///
    /// A callback and not `async`, with the suspending version layered on top rather than under.
    /// That is not a preference: under GTK the thread belongs to `g_main_loop_run`, nothing drains
    /// Swift's main-actor executor, and a `Task` created from a signal handler never runs at all —
    /// measured, after the bar failed to appear for a page that was visibly suspended. WebKitGTK
    /// does not want suspension anyway; it wants its request kept and answered later.
    func decide(_ asked: [SitePermission], origin: String,
                in windowID: UUID, profileID: UUID,
                then answer: @escaping (Bool) -> Void) {
        // Nothing to file an answer under (an opaque origin, a `data:` page): the safe answer is no.
        guard !asked.isEmpty, !origin.isEmpty else { return answer(false) }

        let known = asked.compactMap { decision(for: $0, origin: origin, profileID: profileID) }
        if known.count == asked.count {
            // One "no" among them is a no: a page that asked for the camera *and* the microphone was
            // asking for a call, and half a call is not what either answer meant.
            return answer(known.allSatisfy { $0 })
        }

        let pending = Pending()
        pending.answer = answer
        queues[windowID, default: []].append(
            Question(profileID: profileID, origin: origin, permissions: asked, pending: pending))
        onQuestionsChanged?()
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
        onQuestionsChanged?()
    }

    /// The window is closing, or its page is being given back: a question nobody can answer any more
    /// is answered no. Denying rather than dropping it is deliberate — the page is suspended on this
    /// call, and a promise that never lands is a page that never finds out.
    func forget(_ windowID: UUID) {
        guard let queue = queues.removeValue(forKey: windowID) else { return }
        for question in queue { question.pending.resume(false) }
        onQuestionsChanged?()
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
    #if canImport(WebKit)
    private static func string(for origin: WKSecurityOrigin) -> String {
        let scheme = origin.`protocol`
        guard !scheme.isEmpty else { return "" }
        guard !origin.host.isEmpty else { return "\(scheme)://" }
        let base = "\(scheme)://\(origin.host)"
        return origin.port == 0 ? base : "\(base):\(origin.port)"
    }

    #endif

    /// The same string built from an address, so the title bar can look up what a window was
    /// answered without asking its page. Kept beside `string(for:)` because the two must agree —
    /// and it is what Linux files answers under, since WebKitGTK does not hand out an origin at all.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return "\(scheme)://" }
        let base = "\(scheme)://\(host)"
        let standard = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        guard let port = url.port, port != standard else { return base }
        return "\(base):\(port)"
    }

    #if canImport(WebKit)
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
    #endif
}

// MARK: - Settings

/// The setting lives in the settings table; the knowledge of what its string means lives here,
/// beside the type it means it as. `SettingsStore` itself keeps only keys and strings.
extension SettingsStore {
    /// What sites were allowed — or refused — the camera, the microphone and the motion sensors.
    /// A private profile's answers never reach here; see `SitePermissions`.
    var sitePermissions: [SitePermissions.Decision] {
        get { decode(.sitePermissions) ?? [] }
        set { encode(.sitePermissions, newValue, keepingEmpty: false) }
    }
}
