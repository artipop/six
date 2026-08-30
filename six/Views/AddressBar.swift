#if os(macOS)
import SwiftUI
import Translation
import WebKit

/// The address field, in the top bar — one of them, for the window you are reading.
///
/// Every column used to carry its own, under a title bar of its own: a strip of a dozen windows is a
/// dozen address fields, eleven of them for a page nobody is looking at, each one too narrow to show
/// more than a host. All of it — the lock, the shield, the camera, the title — is here now, and a
/// window is a page from edge to edge with nothing drawn on it. There is only ever one window you are
/// reading, and this describes that one.
struct AddressBar: View {
    let tab: BrowserTab
    var addressFocus: FocusState<UUID?>.Binding

    @Environment(BrowserState.self) private var browser
    @Environment(ContentBlocker.self) private var blocker
    @Environment(SitePermissions.self) private var permissions
    @FocusedValue(\.showFilterLists) private var showFilterLists
    @FocusedValue(\.showSitePermissions) private var showSitePermissions
    @State private var text = ""

    private var isEditing: Bool { addressFocus.wrappedValue == tab.id }
    private var isWebPage: Bool { tab.currentURL?.scheme?.hasPrefix("http") == true }
    /// Is this site being left alone — either because the switch is off, or because the user said so?
    private var isAllowed: Bool { blocker.allows(tab.currentURL) }

    var body: some View {
        HStack(spacing: 6) {
            if let document = tab.document {
                documentControls(document)
            } else {
                Button(action: tab.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!tab.canGoBack)
                    .help("Back")
                Button(action: tab.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!tab.canGoForward)
                    .help("Forward")
                Button(action: tab.reloadOrStop) {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help(tab.isLoading ? "Stop" : "Reload")
                field
                if let note = tab.highlightNote {
                    // Moved up here with everything else that described the page: the window itself
                    // is a page now, edge to edge, with nothing drawn on it.
                    Image(systemName: "highlighter")
                        .foregroundStyle(.orange)
                        .help(note)
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    // MARK: The field

    private var field: some View {
        HStack(spacing: 5) {
            siteIcon
            if isWebPage { shield }
            captureIndicator
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .focused(addressFocus, equals: tab.id)
                .onSubmit {
                    tab.navigate(to: text)
                    addressFocus.wrappedValue = nil
                }
            translate
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(height: 24)
        .background(.quaternary.opacity(isEditing ? 0.85 : 0.5),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
        }
        // The field belongs to whichever window is focused, so it has to be repointed when the focus
        // moves as well as when the page navigates — `tab` itself changes under it.
        .onChange(of: tab.currentURL, initial: true) { _, url in
            if !isEditing { text = displayString(for: url) }
        }
        .onChange(of: tab.id, initial: true) { _, _ in
            if !isEditing { text = displayString(for: tab.currentURL) }
        }
        .onChange(of: isEditing) { _, editing in
            guard editing, let url = tab.currentURL else {
                text = displayString(for: tab.currentURL)
                return
            }
            text = IDN.displayURL(url)
        }
    }

    /// The whole address once you are typing in it; the host and path at rest, because a query string
    /// the length of a paragraph is not what the field is for.
    ///
    /// Both halves are shown as they were written rather than as they travel. A host goes over the
    /// wire in ASCII, so WebKit hands back `xn--j1ail.xn--p1ai` for a site whose name is `кто.рф`,
    /// and a path goes over it percent-encoded, so a Russian Wikipedia article arrives as a line of
    /// `%D0%` and nothing else. `IDN` decides when the name behind the ACE form is safe to show —
    /// that decision is the whole of `IDN`, and a homograph is exactly what it is refusing.
    private func displayString(for url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host(percentEncoded: false) else { return url.absoluteString }
        let name = IDN.displayHost(host)
        let path = readable(url.path(percentEncoded: false))
        return path.isEmpty || path == "/" ? name : name + path
    }

    /// Percent-decoding puts back whatever was encoded, and some of what can be encoded does not
    /// belong in a line of text: a direction override in a path rewrites the address around it, and
    /// a newline hides everything after it.
    private func readable(_ path: String) -> String {
        String(String.UnicodeScalarView(path.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }))
    }

    // MARK: Translation

    /// Translating this page, in four states.
    ///
    /// The trailing end of the field, where Safari puts it — the lock and the shield sit at the
    /// leading end and talk about safety, which is the other half of the field's job.
    ///
    /// **Downloading gets a spinner and an indeterminate one.** `Translation.framework` has no
    /// progress to offer: `status(from:to:)`, `isReady` and `canRequestDownloads`, and no byte
    /// count anywhere. A determinate bar would have to invent its number, and a bar stuck at zero
    /// while a gigabyte arrives is exactly the thing that makes a person think it has hung. So the
    /// spinner turns, the tooltip says what it is waiting for, and the system's own sheet — which
    /// is up at that moment — carries the rest.
    @ViewBuilder
    private var translate: some View {
        if isWebPage {
            // Shown on every page, not only on one detected as foreign. Detection runs after the
            // page settles and can decline to answer at all — a short page, a page that hydrates
            // late — and a button that comes and goes on its own is worse than one that is always
            // where you left it. What it does when the page needs nothing is say so.
            let state = browser.translation[tab.id]
                ?? TabTranslation(source: nil, target: browser.translationTarget)
            switch state.phase {
            case .downloading:
                // Indeterminate, and that is not laziness. `Translation.framework` offers
                // `status(from:to:)`, `isReady` and `canRequestDownloads`, and no byte count
                // anywhere, so a determinate bar would have to invent its number — and one sitting
                // at zero while a gigabyte arrives is exactly what reads as hung.
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("Downloading a language — it continues in the background")
            case .working(let done, let total):
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("Translating…")
            default:
                menu(state)
            }
        }
    }

    /// The menu behind the button. Its first item is the whole answer to "into what?" — it names
    /// the language rather than leaving the reader to find out by pressing it.
    private func menu(_ state: TabTranslation) -> some View {
        let target = browser.translationTarget
        let translated = { if case .done = state.phase { return true } else { return false } }()

        return Menu {
            if translated {
                Button(state.showsOriginal ? "Show Translation" : "Show Original") {
                    browser.toggleTranslation(of: tab)
                }
            } else {
                // Named, not implied. One or two, from the reader's own preferred languages, with
                // the page's own language left out of them.
                ForEach(browser.suggestedTargets(excluding: state.source), id: \.maximalIdentifier) { language in
                    Button("Translate to \(AppleTranslator.name(of: language))") {
                        browser.translate(tab, to: language)
                    }
                }
            }

            // Every language this Mac can translate into. Names come from Foundation in the
            // reader's own language, so none of them reaches the string catalogue.
            Menu("Translate to…") {
                ForEach(browser.appleTranslator.languages, id: \.maximalIdentifier) { language in
                    // Greyed rather than hidden. A language missing from the list looks like six
                    // forgot it; a language greyed out with a reason is Apple not having that
                    // direction, which is a fact about the machine and worth saying.
                    let unavailable = state.source.map {
                        browser.appleTranslator.cannotTranslate(from: $0, to: language)
                    } ?? false
                    Button {
                        browser.translate(tab, to: language)
                    } label: {
                        if language.languageCode == target.languageCode {
                            Label(AppleTranslator.name(of: language), systemImage: "checkmark")
                        } else {
                            Text(AppleTranslator.name(of: language))
                        }
                    }
                    .disabled(unavailable)
                    .help(unavailable && state.source != nil
                          ? String(localized: "There is no translation from \(AppleTranslator.name(of: state.source!)) to \(AppleTranslator.name(of: language))")
                          : "")
                }
            }
            .disabled(browser.appleTranslator.languages.isEmpty)

            if let host = tab.currentURL?.host() {
                Divider()
                Toggle("Always Translate \(host)", isOn: Binding(
                    get: { browser.alwaysTranslates(host) },
                    set: { browser.setAlwaysTranslates(host, $0) }
                ))
            }

            if case .failed(let why) = state.phase {
                Divider()
                Text(why)
            }
        } label: {
            Image(systemName: "translate").font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(tint(for: state))
        .help(helpText(for: state, target: target))
        // The system's own translation panel: its languages, its downloads, its layout. Six owns
        // the text and nothing else. `replacementAction` is passed only where putting the
        // translation back means something — offering "replace" on an article would be a lie.
        //
        // **It is not the same privacy posture as the page translation**, and that is worth knowing
        // rather than discovering. A page is translated by a `TranslationSession` on this machine
        // and nothing leaves it. This panel says, in Apple's own words, that the selected content
        // is sent to Apple unless the reader has turned on offline translation in System Settings.
        // Apple asks before the first one, which is why six does not ask again — but it is the one
        // place in this feature where text can leave the Mac.
        .translationPresentation(
            isPresented: Binding(
                get: { browser.translation.showsSelection },
                set: { browser.translation.showsSelection = $0 }
            ),
            text: browser.translation.selection,
            replacementAction: browser.translation.selectionIsEditable
                ? { browser.replaceSelection(in: tab, with: $0) }
                : nil
        )
        .task(id: state.source?.maximalIdentifier) {
            await browser.appleTranslator.loadLanguages()
            if let source = state.source { await browser.appleTranslator.loadStatuses(from: source) }
        }
    }

    private func tint(for state: TabTranslation) -> AnyShapeStyle {
        switch state.phase {
        case .done: state.showsOriginal ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint)
        case .failed: AnyShapeStyle(.orange)
        default: AnyShapeStyle(.tertiary)
        }
    }

    private func helpText(for state: TabTranslation, target: Locale.Language) -> String {
        switch state.phase {
        case .done:
            state.showsOriginal
                ? String(localized: "Showing the original")
                : String(localized: "Translated into \(AppleTranslator.name(of: target))")
        case .failed(let why):
            why
        default:
            if let first = browser.suggestedTargets(excluding: state.source).first {
                String(localized: "Translate this page into \(AppleTranslator.name(of: first))")
            } else {
                String(localized: "Translate this page")
            }
        }
    }

    // MARK: Blocking

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
                .font(.system(size: 10))
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
                    .font(.system(size: 10))
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
                    .font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("What \(URL(string: origin)?.host() ?? origin) is allowed to use")
        } else {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
        }
    }

    // MARK: Documents

    /// A document window has no address; what it has instead is the two ways of looking at it, and —
    /// while a research run writes into it — what the agent is up to.
    @ViewBuilder
    private func documentControls(_ document: TextDocument) -> some View {
        @Bindable var document = document
        Picker("View", selection: $document.showsPreview) {
            Image(systemName: "pencil").tag(false).help("Edit the Markdown")
            Image(systemName: "doc.richtext").tag(true).help("Preview")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        HStack(spacing: 5) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
            Text(document.title)
                .lineLimit(1)
                .truncationMode(.tail)
            if let run = browser.run(forDocument: tab.id) {
                if run.isRunning {
                    ProgressView().controlSize(.mini)
                    Text(run.status.isEmpty ? String(localized: "researching…") : run.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !run.status.isEmpty {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                        .help(run.status)
                }
            }
            Spacer(minLength: 0)
            if let url = document.fileURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(url.path(percentEncoded: false))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
#endif
