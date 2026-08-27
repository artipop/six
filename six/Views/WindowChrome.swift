import SwiftUI
import WebKit

/// Per-column title bar. Every window in the strip carries its own navigation and address field,
/// the way a tiled window carries its own decorations.
struct WindowChrome: View {
    let tab: BrowserTab
    let isFocused: Bool
    var addressFocus: FocusState<UUID?>.Binding

    @Environment(BrowserState.self) private var browser
    @Environment(ContentBlocker.self) private var blocker
    @Environment(SitePermissions.self) private var permissions
    @FocusedValue(\.showFilterLists) private var showFilterLists
    @FocusedValue(\.showSitePermissions) private var showSitePermissions
    @State private var text = ""
    @State private var hovering = false

    private var isEditing: Bool { addressFocus.wrappedValue == tab.id }

    private var isWebPage: Bool { tab.currentURL?.scheme?.hasPrefix("http") == true }
    /// Is this site being left alone — either because the switch is off, or because the user said so?
    private var isAllowed: Bool { blocker.allows(tab.currentURL) }

    /// The state of blocking on this page, and the two things to do about it. Filled shield: the
    /// rules are on this page. Crossed out: they are not.
    private var shield: some View {
        Menu {
            Button(isAllowed ? "Block Ads on This Site" : "Allow Ads on This Site") {
                browser.setBlockingAllowed(!isAllowed, for: tab)
            }
            .disabled(!blocker.isEnabled)
            Button("Filter Lists…") { showFilterLists?.perform() }
                .disabled(showFilterLists == nil)
        } label: {
            Image(systemName: isAllowed ? "shield.slash" : "shield.lefthalf.filled")
                .font(.system(size: 9))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(isAllowed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        .help(blocker.isEnabled
              ? (isAllowed ? "Ads are allowed on this site" : "Ads and trackers are blocked here")
              : "Blocking is off")
    }

    // MARK: The camera and the microphone

    /// The site this window's answers are filed under. Nil off the web — a document window and the
    /// start page have no origin and nothing to remember.
    private var origin: String? { SitePermissions.origin(of: tab.currentURL) }

    /// What this site has already been told, if anything.
    private var decided: [SitePermission: Bool] {
        guard let origin else { return [:] }
        return permissions.decisions(forOrigin: origin, profileID: tab.profileID)
    }

    /// Only there while a device is actually in use, and red while it is live: the point of an
    /// indicator is that you never have to go looking for it. One click mutes, another lets the page
    /// hear and see again — muting rather than stopping, because a call that was cut off is not what
    /// the button in a call's own toolbar does.
    @ViewBuilder
    private var captureIndicator: some View {
        if tab.isCapturing {
            let muted = tab.isCaptureMuted
            Button { tab.setCaptureMuted(!muted) } label: {
                Image(systemName: captureSymbol(muted: muted))
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.red))
            .help(muted ? "Muted — click to let this page see and hear again"
                        : "This page is using the camera or microphone — click to mute")
        }
    }

    /// The camera wins the icon when both are on: it is the one people want to know about.
    private func captureSymbol(muted: Bool) -> String {
        if tab.cameraCapture != .none { return muted ? "video.slash.fill" : "video.fill" }
        return muted ? "mic.slash.fill" : "mic.fill"
    }

    /// The lock (or the globe) turns into a menu once this site has been answered about something —
    /// which is where a browser has always kept a site's own settings, and saves the address field an
    /// icon it would only need sometimes.
    @ViewBuilder
    private var siteIcon: some View {
        let symbol = tab.currentURL?.scheme == "https" ? "lock.fill" : "globe"
        if let origin, !decided.isEmpty {
            Menu {
                ForEach(SitePermission.allCases) { permission in
                    if let allowed = decided[permission] {
                        Button(allowed ? "Block \(permission.label) on This Site"
                                       : "Allow \(permission.label) on This Site") {
                            permissions.set(!allowed, permission, forOrigin: origin, profileID: tab.profileID)
                            // Taking the camera back has to take it back now, not next time.
                            if allowed { tab.stopCapture(permission) }
                        }
                    }
                }
                Divider()
                Button("Forget This Site's Choices") {
                    permissions.forget(origin: origin, profileID: tab.profileID)
                }
                Button("Site Permissions…") { showSitePermissions?.perform() }
                    .disabled(showSitePermissions == nil)
            } label: {
                Image(systemName: symbol)
                    .font(.system(size: 9))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("What \(URL(string: origin)?.host() ?? origin) is allowed to use")
        } else {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .font(.system(size: 9))
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let document = tab.document {
                documentControls(document)
            } else {
                // Everything here goes through the window, not through its page: a title bar is drawn
                // for every column in the strip, and reaching for `tab.page` would build a page for
                // each of them just to ask whether its back list is empty (see `BrowserTab.page`).
                Button(action: tab.goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!tab.canGoBack)
                .help("Back")

                Button(action: tab.goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!tab.canGoForward)
                .help("Forward")

                Button(action: tab.reloadOrStop) {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(tab.isLoading ? "Stop" : "Reload")

                address

                if let note = tab.highlightNote {
                    Image(systemName: "highlighter")
                        .foregroundStyle(.orange)
                        .help(note)
                }
            }

            Button { browser.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering || isFocused ? .secondary : .tertiary)
            .help("Close Window")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: 32)
        .background(isFocused ? AnyShapeStyle(.bar) : AnyShapeStyle(.quaternary.opacity(0.4)))
        .contentShape(Rectangle())
        .onTapGesture {
            browser.selectTab(tab.id)
            browser.exitOverview()
        }
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) {
            if !tab.isDocument, tab.isLoading {
                LoadingLine(progress: tab.estimatedProgress, accent: accent)
            }
        }
    }

    /// A document's bar: edit/preview, the title, and — while a research run writes into it — what
    /// the agent is up to.
    @ViewBuilder
    private func documentControls(_ document: TextDocument) -> some View {
        @Bindable var document = document
        Picker("View", selection: $document.showsPreview) {
            Image(systemName: "pencil").tag(false).help("Edit the Markdown")
            Image(systemName: "doc.richtext").tag(true).help("Preview")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.system(size: 9))
            Text(document.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            if let run = browser.run(forDocument: tab.id) {
                if run.isRunning {
                    ProgressView().controlSize(.mini)
                    Text(run.status.isEmpty ? String(localized: "researching…") : run.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !run.status.isEmpty {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 9))
                        .help(run.status)
                }
            }
            Spacer(minLength: 0)
            if let url = document.fileURL {
                Text(url.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(url.path(percentEncoded: false))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }

    private var accent: Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }

    /// The loading line, drawn by hand: a linear `ProgressView` brings a track and a thickness of its
    /// own, and a browser wants a hairline the page seems to push along, not a control.
    private struct LoadingLine: View {
        let progress: Double
        let accent: Color

        var body: some View {
            GeometryReader { proxy in
                Capsule()
                    .fill(accent)
                    .frame(width: max(3, proxy.size.width * min(max(progress, 0.03), 1)))
                    .animation(.easeOut(duration: 0.25), value: progress)
            }
            .frame(height: 1.5)
            .transition(.opacity)
        }
    }

    private var address: some View {
        HStack(spacing: 5) {
            siteIcon
            if isWebPage { shield }
            captureIndicator
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1)
                .focused(addressFocus, equals: tab.id)
                .onSubmit {
                    tab.navigate(to: text)
                    addressFocus.wrappedValue = nil
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(isEditing ? 0.8 : 0.45), in: RoundedRectangle(cornerRadius: 7))
        .onChange(of: tab.currentURL, initial: true) { _, url in
            if !isEditing { text = displayString(for: url) }
        }
        .onChange(of: isEditing) { _, editing in
            text = editing ? (tab.currentURL?.absoluteString ?? "") : displayString(for: tab.currentURL)
        }
    }

    /// Collapsed columns are narrow, so the resting state shows the host, not the whole URL.
    private func displayString(for url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host() else { return url.absoluteString }
        let path = url.path()
        return path.isEmpty || path == "/" ? host : host + path
    }
}

extension WebPage {
    @discardableResult
    func load(_ item: WebPage.BackForwardList.Item?) -> Bool {
        guard let item else { return false }
        _ = load(item)
        return true
    }
}
