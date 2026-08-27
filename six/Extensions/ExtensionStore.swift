import AppKit
import Foundation
import Observation
import WebKit

/// Browser extensions, hosted on `WKWebExtension`.
///
/// **One controller per profile.** A profile is an isolated `WKWebsiteDataStore`; its extensions get
/// storage of their own the same way, through a persistent
/// `WKWebExtensionController.Configuration(identifier:)` keyed by the profile. A private profile has
/// no controller at all — private browsing is recorded nowhere, and an extension's storage is a
/// record.
///
/// **What works here and what does not is known, measured, and shown before installing** — see
/// [docs/extensions.md](../../docs/extensions.md). The short of it: a content script runs, but the
/// extension cannot talk to it, because `WKWebExtensionTab.webView(for:)` wants the live `WKWebView`
/// behind a page and `WebPage` does not hand its own out. Every install says what that costs *this*
/// extension (`ExtensionInstaller.compatibility`), rather than letting someone find out.
@MainActor
@Observable
final class ExtensionStore {
    /// The runtime of one profile: its controller, the window its strip stands for, and a context per
    /// enabled extension.
    @MainActor
    final class Runtime {
        let controller: WKWebExtensionController
        lazy var window = ExtensionWindowAdapter(store: store, profileID: profileID)
        var contexts: [String: WKWebExtensionContext] = [:]
        let profileID: Profile.ID
        unowned let store: ExtensionStore

        init(profileID: Profile.ID, storeIdentifier: UUID, delegate: ExtensionDelegate, store: ExtensionStore) {
            self.profileID = profileID
            self.store = store
            controller = WKWebExtensionController(configuration: .init(identifier: storeIdentifier))
            controller.delegate = delegate
        }
    }

    private let settings: SettingsStore
    @ObservationIgnored private let delegate = ExtensionDelegate()
    @ObservationIgnored weak var browser: BrowserState?

    private(set) var installed: [InstalledExtension]
    /// The verdict per extension, worked out when it is loaded (and at install, before it is).
    private(set) var compatibility: [String: ExtensionCompatibility] = [:]
    private(set) var errors: [String: String] = [:]
    /// Bumped whenever an action's icon, badge or enabled state changes, so the top bar redraws.
    private(set) var actionRevision = 0

    @ObservationIgnored private var runtimes: [Profile.ID: Runtime] = [:]
    @ObservationIgnored private var adapters: [UUID: ExtensionTabAdapter] = [:]
    /// Where the popup should point: the toolbar button's frame, in the window's coordinates.
    @ObservationIgnored var popupAnchor: NSRect?
    /// Holds a popup that WebKit did not wrap in a popover of its own (see the delegate).
    @ObservationIgnored var popupPanel: NSPanel?

    init(settings: SettingsStore) {
        self.settings = settings
        self.installed = settings.installedExtensions
        delegate.store = self
    }

    /// Brings up a runtime for every profile that should have one, at launch — an extension's
    /// background content runs whether or not a page has been built yet, which is what its alarms and
    /// its rules expect.
    func start() {
        guard let browser, !installed.filter(\.isEnabled).isEmpty else { return }
        for profile in browser.profiles where !profile.isPrivate {
            _ = runtime(for: profile)
        }
    }

    // MARK: What a window gets

    /// The controller a page of this profile is built with — and `nil` for a private profile, which
    /// deliberately runs no extensions.
    func controller(for profileID: Profile.ID) -> WKWebExtensionController? {
        guard !installed.filter(\.isEnabled).isEmpty else { return nil }
        guard let browser, let profile = browser.profiles.first(where: { $0.id == profileID }), !profile.isPrivate else { return nil }
        return runtime(for: profile).controller
    }

    private func runtime(for profile: Profile) -> Runtime {
        if let existing = runtimes[profile.id] { return existing }
        let runtime = Runtime(profileID: profile.id, storeIdentifier: profile.dataStoreID, delegate: delegate, store: self)
        runtimes[profile.id] = runtime
        runtime.controller.didOpenWindow(runtime.window)
        runtime.controller.didFocusWindow(runtime.window)
        for extensionRecord in installed where extensionRecord.isEnabled {
            Task { await load(extensionRecord, in: runtime) }
        }
        return runtime
    }

    func adapter(for tab: BrowserTab) -> ExtensionTabAdapter {
        if let existing = adapters[tab.id] { return existing }
        let adapter = ExtensionTabAdapter(tab: tab, store: self)
        adapters[tab.id] = adapter
        return adapter
    }

    func tabs(in profileID: Profile.ID) -> [ExtensionTabAdapter] {
        guard let browser else { return [] }
        return browser.tabs(in: profileID).map { adapter(for: $0) }
    }

    func activeTab(in profileID: Profile.ID) -> ExtensionTabAdapter? {
        guard let browser, let tab = browser.selectedTab, tab.profileID == profileID else { return nil }
        return adapter(for: tab)
    }

    func window(for profileID: Profile.ID) -> ExtensionWindowAdapter? {
        runtimes[profileID]?.window
    }

    // MARK: What the browser tells the extensions

    func noteOpened(_ tab: BrowserTab) {
        guard let runtime = runtimes[tab.profileID], !runtime.contexts.isEmpty else { return }
        runtime.controller.didOpenTab(adapter(for: tab))
    }

    func noteClosed(_ tab: BrowserTab) {
        guard let adapter = adapters.removeValue(forKey: tab.id) else { return }
        runtimes[tab.profileID]?.controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func noteActivated(_ tab: BrowserTab) {
        guard let runtime = runtimes[tab.profileID], !runtime.contexts.isEmpty else { return }
        runtime.controller.didActivateTab(adapter(for: tab))
    }

    /// A window navigated, finished loading or changed its title. Without this an extension's
    /// `tabs.onUpdated` never fires: WebKit does not watch the app's model, the app tells it.
    func noteChanged(_ tab: BrowserTab, _ properties: WKWebExtension.TabChangedProperties) {
        guard let runtime = runtimes[tab.profileID], !runtime.contexts.isEmpty else { return }
        runtime.controller.didChangeTabProperties(properties, for: adapter(for: tab))
        actionRevision &+= 1
    }

    // MARK: Installing

    /// Reads an extension without installing it, for the confirmation dialog: what it is, what it
    /// asks for, and what will not work.
    func inspect(_ source: URL) async throws -> (extension: WKWebExtension, compatibility: ExtensionCompatibility, staged: (folder: URL, id: String)) {
        let staged = try ExtensionInstaller.stage(source)
        let ext = try await WKWebExtension(resourceBaseURL: staged.folder)
        return (ext, ExtensionInstaller.compatibility(of: ext), staged)
    }

    /// Remembers a staged extension and loads it into every profile that is running one.
    func adopt(_ ext: WKWebExtension, staged: (folder: URL, id: String), origin: String) {
        let record = InstalledExtension(
            id: staged.id,
            name: ext.displayName ?? staged.id,
            version: ext.displayVersion ?? "",
            isEnabled: true,
            origin: origin,
            installedAt: .now)
        installed.removeAll { $0.id == record.id }
        installed.append(record)
        compatibility[record.id] = ExtensionInstaller.compatibility(of: ext)
        settings.installedExtensions = installed
        for runtime in runtimes.values {
            Task { await load(record, in: runtime) }
        }
        // A page built before this one arrived has no extension controller in its configuration, so
        // the extension would not see it — every window builds its page again.
        start()
        browser?.rebuildLivePages()
        log("installed \(record.name) \(record.version)")
    }

    /// `SIX_EXTENSION=/path/to/unpacked` — installs at launch with no dialog, for development.
    func installFromEnvironment(_ path: String) async {
        let source = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let (ext, _, staged) = try await inspect(source)
            adopt(ext, staged: staged, origin: source.lastPathComponent)
        } catch {
            log("SIX_EXTENSION install failed: \(error.localizedDescription)")
        }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), installed[index].isEnabled != enabled else { return }
        installed[index].isEnabled = enabled
        settings.installedExtensions = installed
        let record = installed[index]
        for runtime in runtimes.values {
            if enabled {
                Task { await load(record, in: runtime) }
            } else {
                unload(record.id, from: runtime)
            }
        }
        if enabled { start() }
        browser?.rebuildLivePages()
    }

    func remove(_ id: String) {
        guard let record = installed.first(where: { $0.id == id }) else { return }
        for runtime in runtimes.values { unload(id, from: runtime) }
        installed.removeAll { $0.id == id }
        compatibility[id] = nil
        errors[id] = nil
        settings.installedExtensions = installed
        try? FileManager.default.removeItem(at: record.folder)
        browser?.rebuildLivePages()
        log("removed \(record.name)")
    }

    private func load(_ record: InstalledExtension, in runtime: Runtime) async {
        guard runtime.contexts[record.id] == nil else { return }
        do {
            let ext = try await WKWebExtension(resourceBaseURL: record.folder)
            compatibility[record.id] = ExtensionInstaller.compatibility(of: ext)
            let context = WKWebExtensionContext(for: ext)
            // The identifier is what ties an extension to its storage across launches; without it a
            // persistent controller would hand it a fresh, empty world every time.
            context.uniqueIdentifier = record.id
            // Granted at install, when the dialog listed them. Optional permissions asked for later
            // go through the delegate, which asks.
            for permission in ext.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in ext.requestedPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            context.hasAccessToPrivateData = false
            try runtime.controller.load(context)
            runtime.contexts[record.id] = context
            errors[record.id] = nil
            for tab in tabs(in: runtime.profileID) { runtime.controller.didOpenTab(tab) }
            if ext.hasBackgroundContent {
                try? await context.loadBackgroundContent()
            }
            actionRevision &+= 1
            log("loaded \(record.name) in profile \(runtime.profileID)")
        } catch {
            errors[record.id] = error.localizedDescription
            log("\(record.name) failed to load: \(error.localizedDescription)")
        }
    }

    private func unload(_ id: String, from runtime: Runtime) {
        guard let context = runtime.contexts.removeValue(forKey: id) else { return }
        try? runtime.controller.unload(context)
        actionRevision &+= 1
    }

    // MARK: Toolbar actions

    /// The buttons this window should show: one per enabled extension that has an action.
    func actions(for tab: BrowserTab) -> [(record: InstalledExtension, action: WKWebExtension.Action)] {
        guard let runtime = runtimes[tab.profileID] else { return [] }
        let adapter = adapter(for: tab)
        return installed.filter(\.isEnabled).compactMap { record in
            guard let context = runtime.contexts[record.id], let action = context.action(for: adapter) else { return nil }
            return (record, action)
        }
    }

    /// A click on one of those buttons: the extension decides what it means — a popup, or a message
    /// to its background.
    func performAction(_ record: InstalledExtension, for tab: BrowserTab, anchor: NSRect?) {
        guard let runtime = runtimes[tab.profileID], let context = runtime.contexts[record.id] else { return }
        popupAnchor = anchor
        context.userGesturePerformed(in: adapter(for: tab))
        context.performAction(for: adapter(for: tab))
    }

    func optionsPageURL(for record: InstalledExtension) -> URL? {
        guard let profileID = browser?.selectedProfileID, let context = runtimes[profileID]?.contexts[record.id] else { return nil }
        return context.optionsPageURL
    }

    /// Which profile a context belongs to — the delegate is shared by every profile's controller,
    /// so "which strip is this extension talking about" is a lookup, not the selected profile.
    func profileID(of context: WKWebExtensionContext) -> Profile.ID? {
        runtimes.first { $0.value.contexts.values.contains(where: { $0 === context }) }?.key
    }

    func noteActionsChanged() {
        actionRevision &+= 1
    }

    nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("[six] extensions: \(message)\n".utf8))
    }
}

/// six's answers to the extension world.
@MainActor
final class ExtensionDelegate: NSObject, WKWebExtensionControllerDelegate {
    weak var store: ExtensionStore?

    private func profileID(of context: WKWebExtensionContext) -> Profile.ID? {
        store?.profileID(of: context) ?? store?.browser?.selectedProfileID
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let store, let profileID = profileID(of: context), let window = store.window(for: profileID) else { return [] }
        return [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let store, let profileID = profileID(of: context) else { return nil }
        return store.window(for: profileID)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let store, let browser = store.browser else { return nil }
        let tab = browser.newTab(url: configuration.url)
        return store.adapter(for: tab)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext) async throws {
        guard let store, let browser = store.browser, let url = context.optionsPageURL else { return }
        browser.newTab(url: url)
    }

    /// WebKit builds the popover itself; six only has to say where it points — the toolbar button
    /// that was clicked.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        guard let store else { return }
        let anchor = { (content: NSView) in
            store.popupAnchor ?? NSRect(x: content.bounds.midX, y: content.bounds.maxY - 40, width: 1, height: 1)
        }
        if let popover = action.popupPopover, let content = NSApp.mainWindow?.contentView {
            popover.show(relativeTo: anchor(content), of: content, preferredEdge: .minY)
            return
        }
        // WebKit usually hands over a popover of its own; when it only hands over the web view, six
        // puts it in a panel rather than dropping the click on the floor.
        guard let webView = action.popupWebView else {
            store.log("popup for \(action.label ?? "an extension") could not be presented")
            return
        }
        let frame = NSRect(x: 0, y: 0, width: 380, height: 460)
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = action.label ?? context.webExtension.displayName ?? "Extension"
        webView.frame = frame
        webView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(webView)
        panel.level = .floating
        panel.center()
        panel.orderFrontRegardless()
        store.popupPanel = panel
    }

    /// Anything the extension did not ask for at install time is asked for now.
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let names = permissions.map(\.rawValue).sorted().joined(separator: ", ")
        let allowed = Self.ask(
            title: "\(context.webExtension.displayName ?? "An extension") wants more access",
            body: "It is asking for: \(names).",
            allow: "Allow")
        return (allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let hosts = patterns.map(\.description).sorted().joined(separator: ", ")
        let allowed = Self.ask(
            title: "\(context.webExtension.displayName ?? "An extension") wants access to sites",
            body: "It is asking to read and change: \(hosts).",
            allow: "Allow")
        return (allowed ? patterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        store?.noteActionsChanged()
    }

    private static func ask(title: String, body: String, allow: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: allow)
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
