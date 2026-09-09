#if os(iOS)
import SwiftUI
import WebKit

/// Which way the strip runs. The model is one-dimensional — columns follow one another *along* the
/// strip, workspaces stack *across* it — so a platform only has to say which screen direction the
/// strip's own axis points in. Everything else (widths, gaps, the scroll offset, centring) is the
/// arithmetic `NiriLayout` already does for the Mac.
enum StripAxis {
    /// Columns left to right, workspaces above and below: the Mac, and any device on its side.
    case horizontal
    /// Columns top to bottom, workspaces left and right: any device held upright.
    case vertical

    /// Which way up the device is, and nothing else. A strip of columns wants the long edge of the
    /// screen to run along it: upright that is the vertical one, on its side the horizontal one.
    /// Size classes would answer differently — an iPad is `.regular` whichever way it is held — and
    /// that is not the question.
    static func forViewport(_ size: CGSize) -> StripAxis {
        size.height > size.width ? .vertical : .horizontal
    }

    /// The viewport as the layout should see it — along the strip first, across it second.
    func stripSpace(_ size: CGSize) -> CGSize {
        switch self {
        case .horizontal: size
        case .vertical: CGSize(width: size.height, height: size.width)
        }
    }

    /// A point in strip space, put on the screen.
    func place(along: CGFloat, across: CGFloat) -> CGSize {
        switch self {
        case .horizontal: CGSize(width: along, height: across)
        case .vertical: CGSize(width: across, height: along)
        }
    }
}

/// The strip, on a touch screen.
///
/// The Mac drives this with ⌥ + scroll, because over a page a gesture belongs to the page. A phone
/// has no modifier to hold, so the strip is driven from its own chrome instead: the handle above
/// each window pans along the strip, and across it switches workspace. Inside the page, every
/// gesture is still the page's.
struct PhoneStripView: View {
    @Environment(BrowserState.self) private var browser
    /// The axis the viewport was last measured against, so turning the device can be told from
    /// merely resizing it — only the turn has to recentre every strip.
    @State private var measuredAxis: StripAxis?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let axis = StripAxis.forViewport(size)
            let layout = browser.layout

            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    let distance = index - layout.focusedWorkspaceIndex
                    // Only the focused workspace and the ones a gesture is dragging into are worth
                    // building; the rest of the stack is off screen with nothing to show.
                    if abs(distance) <= 1 {
                        WorkspaceView(workspace: workspace, axis: axis, isFocused: distance == 0)
                            .frame(width: size.width, height: size.height)
                            .offset(crossOffset(distance, axis: axis, in: size))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .contentShape(Rectangle())
            .overlay { PhoneEdgeButtons(axis: axis, size: size) }
            .onChange(of: size, initial: true) { _, new in
                // Turning the device turns the strip: the same columns, measured the other way.
                let turned = StripAxis.forViewport(new)
                browser.layout.updateViewport(turned.stripSpace(new))
                if measuredAxis != nil, measuredAxis != turned { browser.layout.recenterStrips() }
                measuredAxis = turned
            }
        }
    }

    /// Workspaces sit a screen apart across the strip, plus whatever a gesture in progress has
    /// dragged them — the same rubber band the Mac's scroll monitor feeds.
    private func crossOffset(_ distance: Int, axis: StripAxis, in size: CGSize) -> CGSize {
        let step = (axis == .vertical ? size.width : size.height) * 1.04
        let amount = CGFloat(distance) * step + browser.layout.verticalPreview
        return axis.place(along: 0, across: amount)
    }
}

/// One workspace: its columns laid along the strip at the offsets the layout worked out.
private struct WorkspaceView: View {
    let workspace: NiriWorkspace
    let axis: StripAxis
    let isFocused: Bool

    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        let scroll = layout.resolvedOffset(workspace) - (isFocused ? layout.horizontalPreview : 0)

        ZStack(alignment: .topLeading) {
            Color.clear
            if workspace.columns.isEmpty {
                PhoneEmptyWorkspaceHint()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // By window, like the Mac's strip and for the same reason (`NiriWindowPlace`). A column
            // split on the Mac arrives here as two windows sharing one screen's worth of strip, and
            // is drawn that way rather than half-hidden: the strip runs down the phone, so the halves
            // are the top and the bottom of the screen. Nothing here makes one — there is no ⌥S on a
            // phone — but a rail restored from a session that has one must not hold a window nobody
            // can reach.
            ForEach(layout.placements(workspace.columns)) { place in
                if let tab = browser.tab(place.tabID) {
                    // `minX` and `width` are the window's place *along* the strip; which way that
                    // runs on screen is this view's business, not the layout's.
                    let frame = place.frame
                    PhoneColumn(tab: tab, axis: axis,
                                isFocused: isFocused && place.tabID == workspace.focusedColumn?.focusedTabID)
                        .frame(width: axis == .vertical ? frame.height : frame.width,
                               height: axis == .vertical ? frame.width : frame.height)
                        .offset(axis.place(along: frame.minX - scroll, across: layout.outerGap))
                }
            }
        }
        .animation(NiriLayout.switchAnimation, value: workspace.focus)
    }
}

/// A row with nothing on it: the offer the Mac makes in the same place, minus the keystroke — there
/// is no ⌘T to name on a phone, and the `+` in the toolbar is the other way to the same window.
private struct PhoneEmptyWorkspaceHint: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Button { browser.newTab() } label: {
                Label("New Window", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One window in the strip: the page, and the handle that moves the strip.
private struct PhoneColumn: View {
    let tab: BrowserTab
    let axis: StripAxis
    let isFocused: Bool

    @Environment(BrowserState.self) private var browser
    @State private var editingAddress = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    private var accent: Color { browser.selectedProfile.color }

    var body: some View {
        VStack(spacing: 0) {
            handle
            page
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isFocused ? accent : Color.primary.opacity(0.12),
                              lineWidth: isFocused ? 2 : 1)
        }
        .shadow(color: .black.opacity(isFocused ? 0.22 : 0.10), radius: isFocused ? 14 : 8, y: 4)
        .opacity(isFocused ? 1 : 0.92)
    }

    /// The one part of a window whose gestures do not belong to the page: the title — which is also
    /// where the address is typed, since the phone has no ⌘L and no room for a bar of its own — a
    /// close button, and enough room to put a thumb on.
    private var handle: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accent.opacity(tab.isLoading ? 0.4 : 1))
                .frame(width: 8, height: 8)
            if editingAddress {
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        tab.navigate(to: address)
                        editingAddress = false
                    }
            } else {
                Text(tab.title.isEmpty ? (tab.currentURL?.host() ?? String(localized: "New Window")) : tab.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                if editingAddress { editingAddress = false } else { browser.closeTab(tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 46)
        .contentShape(Rectangle())
        // One tap brings the window to focus; a tap on the window that already has it is the ⌘L a
        // phone does not have. A stray tap while walking the strip never opens the keyboard.
        .onTapGesture {
            if isFocused {
                address = tab.currentURL?.absoluteString ?? ""
                editingAddress = true
                addressFocused = true
            } else {
                browser.selectTab(tab.id)
            }
        }
        .onChange(of: isFocused) { _, focused in if !focused { editingAddress = false } }
        .gesture(stripDrag)
    }

    /// Along the strip, one window per gesture; across it, one workspace. A phone has no Mod key to
    /// tell the two apart, so the dominant direction decides — and, as on the Mac, nothing is left
    /// resting half-way: the drag is a preview, and letting go either commits or springs back.
    private var stripDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let layout = browser.layout
                let along = axis == .vertical ? value.translation.height : value.translation.width
                let across = axis == .vertical ? value.translation.width : value.translation.height
                if abs(along) > abs(across) {
                    layout.verticalPreview = 0
                    layout.horizontalPreview = along
                } else {
                    layout.horizontalPreview = 0
                    layout.verticalPreview = across
                }
            }
            .onEnded { value in
                let layout = browser.layout
                let along = axis == .vertical ? value.translation.height : value.translation.width
                let across = axis == .vertical ? value.translation.width : value.translation.height
                // A finger's worth of travel along the strip, so a tap that slipped moves nothing.
                // `viewport` is in strip space, so `width` is the along-strip extent either way.
                let threshold = layout.viewport.width * 0.12
                withAnimation(NiriLayout.switchAnimation) {
                    layout.horizontalPreview = 0
                    layout.verticalPreview = 0
                }
                if abs(along) > abs(across) {
                    if abs(along) > threshold { browser.focusColumn(along < 0 ? 1 : -1) }
                } else if abs(across) > threshold {
                    browser.focusWorkspace(across < 0 ? 1 : -1)
                }
            }
    }

    @ViewBuilder
    private var page: some View {
        if tab.showsStartPage {
            StartPage(tab: tab, isActive: isFocused)
        } else if let document = tab.document, tab.hasLivePage {
            DocumentView(tab: tab, document: document, isActive: isFocused)
        } else if let live = tab.livePage {
            WebView(live)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewElementFullscreenBehavior(.enabled)
                .id(tab.generation)
                .onAppear(perform: tab.resumeIfNeeded)
                .overlay {
                    if let failure = tab.loadFailure {
                        PageFailureView(tab: tab, failure: failure)
                    }
                }
        } else {
            PhonePlaceholder(tab: tab, accent: accent)
                .contentShape(Rectangle())
                .onTapGesture { browser.selectTab(tab.id) }
        }
    }
}

/// The two step buttons, one at each end of the focused window, and a `+` where the strip runs out.
///
/// The Mac keeps these out of sight until the pointer comes looking and answers by leaning the whole
/// strip aside (`StripEdgeButton`, docs/layout.md). That is a pointer idea: a peek is asked for by
/// *resting* somewhere, and a finger has nowhere to rest — it is touching or it is not. So here they
/// simply stand where they are, which is what `SettingsStore.peeksAtEdges` being off looks like and
/// why it defaults off away from macOS. Touch does not read the flag: honouring an "on" would leave
/// the strip with no button anything could reach.
private struct PhoneEdgeButtons: View {
    let axis: StripAxis
    let size: CGSize

    @Environment(BrowserState.self) private var browser

    var body: some View {
        let layout = browser.layout
        if !layout.isOverview, let frame = layout.focusedColumnFrame {
            PhoneEdgeButton(direction: -1, axis: axis, along: frame.minX - layout.gap / 2, size: size)
            PhoneEdgeButton(direction: 1, axis: axis, along: frame.maxX + layout.gap / 2, size: size)
        }
    }
}

/// One of them. It stands in the gap beside the focused window, at the middle of the way across, and
/// steps one window — or, where there is no window that way, opens one there.
private struct PhoneEdgeButton: View {
    let direction: Int
    let axis: StripAxis
    /// Where it goes *along* the strip, in the same space `focusedColumnFrame` is measured in.
    let along: CGFloat
    let size: CGSize

    @Environment(BrowserState.self) private var browser

    /// A finger, not a pointer: the gap the glyph sits in is a tenth of this, so the target has to
    /// reach out of it and over the corners it stands between. Apple's minimum, and the same order as
    /// the handle's own close button.
    private static let touch: CGFloat = 44

    var body: some View {
        let layout = browser.layout
        if let step = step(layout: layout) {
            Button(action: step.action) {
                Image(systemName: step.symbol)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(browser.selectedProfile.color.opacity(0.8))
                    .frame(width: Self.touch, height: Self.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(point(in: size))
            .animation(NiriLayout.switchAnimation, value: along)
        }
    }

    /// The gap, put on the screen — and never off it: a window as wide as the viewport leaves nowhere
    /// to stand but the edge itself, and half a target is what fits there.
    private func point(in size: CGSize) -> CGPoint {
        let extent = axis == .vertical ? size.height : size.width
        let inset = Self.touch / 2
        let placed = min(max(inset, along), extent - inset)
        return axis == .vertical
            ? CGPoint(x: size.width / 2, y: placed)
            : CGPoint(x: placed, y: size.height / 2)
    }

    /// The same two answers the Mac gives, with the arrow turned to face along the strip: upright it
    /// runs down the screen, on its side across it.
    private func step(layout: NiriLayout) -> (symbol: String, action: () -> Void)? {
        if layout.canFocusColumn(direction) {
            let symbol: String
            switch axis {
            case .horizontal: symbol = direction < 0 ? "chevron.left" : "chevron.right"
            case .vertical: symbol = direction < 0 ? "chevron.up" : "chevron.down"
            }
            return (symbol, { browser.focusColumn(direction) })
        }
        // Nothing that way, so the button offers the only other thing that can be there: a window.
        // An empty workspace is left alone — it says the same thing in the middle of the screen.
        if layout.focusedWorkspace?.isEmpty == false {
            let side: NiriPlacement = direction < 0 ? .left : .right
            return ("plus", { browser.newTab(on: side) })
        }
        return nil
    }
}

/// A window whose page is not built: its last picture, or its colour.
private struct PhonePlaceholder: View {
    let tab: BrowserTab
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = tab.thumbnail {
                Image(platform: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "globe")
                    .font(.largeTitle)
                    .foregroundStyle(accent.opacity(0.5))
            }
        }
        .onAppear(perform: tab.loadPictureIfNeeded)
    }
}
#endif
