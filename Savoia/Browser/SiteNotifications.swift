#if os(macOS)
import AppKit
import UserNotifications
import WebKit

/// What `new Notification()` on a page becomes: WebKit hands it over and expects to hear how it went.
/// [permissions.md](../../docs/permissions.md#notifications) has the C API this stands on.
final class SiteNotifications: NSObject, UNUserNotificationCenterDelegate, _WKWebsiteDataStoreDelegate {
    static let shared = SiteNotifications()

    weak var browser: BrowserState?
    var permissions: SitePermissions?

    private struct Shown {
        /// Nil for a service worker's: it belongs to no page.
        var tab: UUID?
        var origin: String
        var tag: String
    }

    private var pools: [NSObject] = []
    private var managers: [OpaquePointer] = []
    private var shown: [UInt64: Shown] = [:]

    /// Idempotent per process pool; called for every configuration a tab is built on.
    func serve(_ configuration: WKWebViewConfiguration) {
        guard let pool = configuration.value(forKey: "processPool") as? NSObject,
              !pools.contains(where: { $0 === pool }) else { return }
        pools.append(pool)
        guard let manager = WKContextGetNotificationManager(OpaquePointer(Unmanaged.passUnretained(pool).toOpaque())) else { return }
        if pools.count == 1 {
            // A service worker's notifications go through a manager of their own, one for the process.
            install(on: WKNotificationManagerGetSharedServiceWorkerNotificationManager())
            if !TestDriver.isOn { UNUserNotificationCenter.current().delegate = self }
        }
        install(on: manager)
    }

    private func install(on manager: OpaquePointer?) {
        guard let manager, !managers.contains(manager) else { return }
        managers.append(manager)
        var provider = WKNotificationProviderV0(
            base: WKNotificationProviderBase(version: 0, clientInfo: nil),
            show: { page, notification, _ in
                MainActor.assumeIsolated { SiteNotifications.shared.show(notification, from: page) }
            },
            cancel: { notification, _ in
                MainActor.assumeIsolated { SiteNotifications.shared.cancel(notification) }
            },
            didDestroyNotification: { notification, _ in
                MainActor.assumeIsolated { SiteNotifications.shared.forget(notification) }
            },
            addNotificationManager: { manager, _ in
                MainActor.assumeIsolated { SiteNotifications.shared.add(manager) }
            },
            removeNotificationManager: { manager, _ in
                MainActor.assumeIsolated { SiteNotifications.shared.managers.removeAll { $0 == manager } }
            },
            notificationPermissions: { _ in
                // As an address: a pointer is not Sendable, and this one crosses an isolation line.
                OpaquePointer(bitPattern: MainActor.assumeIsolated { Int(bitPattern: SiteNotifications.shared.policies()) })
            },
            clearNotifications: { identifiers, _ in
                MainActor.assumeIsolated { SiteNotifications.shared.clear(identifiers) }
            })
        withUnsafePointer(to: &provider) {
            $0.withMemoryRebound(to: WKNotificationProviderBase.self, capacity: 1) {
                WKNotificationManagerSetProvider(manager, $0)
            }
        }
    }

    // MARK: What WebKit asks

    private func show(_ notification: OpaquePointer?, from page: OpaquePointer?) {
        guard let notification else { return }
        let id = WKNotificationGetID(notification)
        // On Apple's ports a WKSecurityOriginRef is the WKSecurityOrigin object.
        let origin = WKNotificationGetSecurityOrigin(notification).map {
            SitePermissions.string(for: Unmanaged<WKSecurityOrigin>.fromOpaque(UnsafeRawPointer($0)).takeUnretainedValue())
        } ?? ""
        // WebKit's own list of answers is per origin; Savoia's is per profile too, and is asked again here.
        // A service worker's comes with no page, and a tab with no page must not answer for it.
        let tab = page.flatMap { page in browser?.tabs.first(where: { Self.page(of: $0) == page }) }
        let profile = tab?.profileID ?? Self.profile(of: notification, in: browser)
        guard let profile, permissions?.decision(for: .notifications, origin: origin, profileID: profile) == true else {
            return closed([id])
        }
        let tag = Self.text(WKNotificationCopyTag(notification))
        if !tag.isEmpty {
            let replaced = shown.filter { $0.value.origin == origin && $0.value.tag == tag }.map(\.key)
            remove(replaced)
            closed(replaced)
        }
        shown[id] = Shown(tab: tab?.id, origin: origin, tag: tag)
        let icon = URL(string: Self.text(WKNotificationCopyIconURL(notification)))
        Log.info(.pages, "notification \(id) from \(origin)\(tab == nil ? ", a service worker's" : "")")
        // The test driver posts nothing to the system: a run would bury the desk.
        guard !TestDriver.isOn else { return each { WKNotificationManagerProviderDidShowNotification($0, id) } }

        let content = UNMutableNotificationContent()
        content.title = Self.text(WKNotificationCopyTitle(notification))
        content.body = Self.text(WKNotificationCopyBody(notification))
        content.subtitle = URL(string: origin)?.host() ?? origin
        content.threadIdentifier = origin
        content.userInfo = ["id": String(id), "tab": tab?.id.uuidString ?? "", "origin": origin,
                            "profile": profile.uuidString]
        Task {
            let center = UNUserNotificationCenter.current()
            let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if allowed, let icon, let file = await Self.download(icon),
               let attachment = try? UNNotificationAttachment(identifier: "icon", url: file) {
                content.attachments = [attachment]
            }
            let request = UNNotificationRequest(identifier: Self.identifier(id), content: content, trigger: nil)
            guard allowed, (try? await center.add(request)) != nil, self.shown[id] != nil else {
                self.shown[id] = nil
                return self.closed([id])
            }
            self.each { WKNotificationManagerProviderDidShowNotification($0, id) }
        }
    }

    private func cancel(_ notification: OpaquePointer?) {
        guard let notification else { return }
        let id = WKNotificationGetID(notification)
        remove([id])
        // A page's own `close()` is an event on its notification; a service worker hears only a person's.
        if !WKNotificationGetIsPersistent(notification) { closed([id]) }
    }

    /// The page is gone; its banner stays, and a click on it still finds the tab.
    private func forget(_ notification: OpaquePointer?) {
        guard let notification else { return }
        shown[WKNotificationGetID(notification)] = nil
    }

    private func clear(_ identifiers: OpaquePointer?) {
        guard let identifiers else { return }
        remove((0..<WKArrayGetSize(identifiers)).compactMap {
            WKArrayGetItemAtIndex(identifiers, $0).map { WKUInt64GetValue(OpaquePointer($0)) }
        })
    }

    private func add(_ manager: OpaquePointer?) {
        guard let manager, !managers.contains(manager) else { return }
        managers.append(manager)
    }

    /// Every origin answered in any profile, for `Notification.permission`. Handed over retained.
    private func policies() -> OpaquePointer? {
        let dictionary = WKMutableDictionaryCreate()
        for (origin, allowed) in answers() {
            let key = WKStringCreateWithUTF8CString(origin)
            let value = WKBooleanCreate(allowed)
            _ = WKDictionarySetItem(dictionary, key, UnsafeRawPointer(value))
            WKRelease(UnsafeRawPointer(key))
            WKRelease(UnsafeRawPointer(value))
        }
        return dictionary
    }

    // MARK: What it is told

    private func each(_ tell: (OpaquePointer) -> Void) {
        managers.forEach(tell)
    }

    private func closed(_ ids: [UInt64]) {
        guard !ids.isEmpty else { return }
        let array = WKMutableArrayCreate()
        for id in ids {
            let value = WKUInt64Create(id)
            WKArrayAppendItem(array, UnsafeRawPointer(value))
            WKRelease(UnsafeRawPointer(value))
        }
        each { WKNotificationManagerProviderDidCloseNotifications($0, array) }
        WKRelease(UnsafeRawPointer(array))
    }

    /// For the test driver: nothing a file showed is left for the next one.
    func closeAll() {
        let ids = Array(shown.keys)
        remove(ids)
        closed(ids)
    }

    private func remove(_ ids: [UInt64]) {
        for id in ids { shown[id] = nil }
        guard !TestDriver.isOn, !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids.map(Self.identifier))
    }

    /// Allowed in any profile is allowed here; `show` asks about the profile.
    private func answers() -> [String: Bool] {
        var found: [String: Bool] = [:]
        for decision in permissions?.decisions ?? [] where decision.permission == .notifications {
            found[decision.origin] = found[decision.origin] == true || decision.isAllowed
        }
        return found
    }

    /// An answer about notifications was written or taken back.
    func policyChanged(for origin: String) {
        let text = WKStringCreateWithUTF8CString(origin)
        let site = WKSecurityOriginCreateFromString(text)
        if let allowed = answers()[origin] {
            each { WKNotificationManagerProviderDidUpdateNotificationPolicy($0, site, allowed) }
        } else {
            let array = WKMutableArrayCreate()
            WKArrayAppendItem(array, UnsafeRawPointer(site))
            each { WKNotificationManagerProviderDidRemoveNotificationPolicies($0, array) }
            WKRelease(UnsafeRawPointer(array))
        }
        WKRelease(UnsafeRawPointer(site))
        WKRelease(UnsafeRawPointer(text))
    }

    // MARK: The banner

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = (info["id"] as? String).flatMap(UInt64.init)
        let tab = (info["tab"] as? String).flatMap(UUID.init(uuidString:))
        let origin = info["origin"] as? String
        let profile = (info["profile"] as? String).flatMap(UUID.init(uuidString:))
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run {
            NSApp.activate()
            // The tab that showed it, or for a service worker's any tab of its site.
            if let browser = SiteNotifications.shared.browser,
               let found = tab.flatMap(browser.tab) ?? browser.tabs.first(where: {
                   $0.profileID == profile && SitePermissions.origin(of: $0.currentURL) == origin
               }) {
                browser.selectTab(found.id)
                found.livePage?.window?.makeKeyAndOrderFront(nil)
            }
            guard let id else { return }
            SiteNotifications.shared.each { WKNotificationManagerProviderDidClickNotification($0, id) }
            SiteNotifications.shared.shown[id] = nil
            SiteNotifications.shared.closed([id])
        }
    }

    // MARK: A service worker's window

    /// `clients.openWindow`, which a worker calls from `notificationclick`: a tab in the store's profile.
    func websiteDataStore(_ dataStore: WKWebsiteDataStore, openWindow url: URL,
                          fromServiceWorkerOrigin serviceWorkerOrigin: WKSecurityOrigin,
                          completionHandler: @escaping (WKWebView?) -> Void) {
        guard let browser, let identifier = dataStore.identifier,
              let profile = browser.profiles.first(where: { $0.dataStoreID == identifier }) else {
            return completionHandler(nil)
        }
        completionHandler(browser.newTab(url: url, in: profile.id).page)
    }

    /// A profile's store, with the worker's window answered.
    static func store(for identifier: UUID) -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        store._delegate = shared
        return store
    }

    // MARK: Reading WebKit's values

    private static func profile(of notification: OpaquePointer, in browser: BrowserState?) -> UUID? {
        guard WKNotificationGetIsPersistent(notification),
              let store = UUID(uuidString: text(WKNotificationCopyDataStoreIdentifier(notification))) else { return nil }
        return browser?.profiles.first(where: { $0.dataStoreID == store })?.id
    }

    /// The icon as a file, which is the only form a banner takes one in.
    private nonisolated static func download(_ url: URL) async -> URL? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let kind = response.mimeType.flatMap({ ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif"][$0] }) else {
            return nil
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(kind)")
        return (try? data.write(to: file)) != nil ? file : nil
    }

    private nonisolated static func identifier(_ id: UInt64) -> String { "site.\(id)" }

    /// Takes the +1 a `Copy` function hands over.
    private static func text(_ string: OpaquePointer?) -> String {
        guard let string else { return "" }
        defer { WKRelease(UnsafeRawPointer(string)) }
        return WKStringCopyCFString(nil, string) as String
    }

    private static func page(of tab: BrowserTab) -> OpaquePointer? {
        guard let view = tab.livePage, view.responds(to: #selector(PageRefs.pageRef)) else { return nil }
        return unsafeBitCast(view, to: PageRefs.self).pageRef().map { OpaquePointer($0) }
    }
}

@objc private protocol PageRefs {
    @objc(_pageRefForTransitionToWKWebView)
    func pageRef() -> UnsafeRawPointer?
}
#endif
