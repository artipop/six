#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The window as every other browser draws it: a tab bar along the top, a toolbar under it, and
/// the one page in front filling the rest.
///
/// It is a second way of looking at the same strip, and nothing more — that is the whole of the
/// design. A tab is a window in the row, a tab group is a named workspace (an unnamed one is
/// ungrouped tabs), and the tab in front is the focused column. So switching between the two faces
/// loses nothing and converts nothing: the row comes back exactly as it was left, with whatever
/// was opened, closed, dragged or renamed in the meantime already in it. The one thing the row of
/// tabs has that the row does not is a group folded up to its name, and that is kept on the
/// workspace too (`TilingWorkspace.collapsed`), where the row ignores it.
///
/// A split column is two tabs here, side by side in the row, and whichever of them is in front is
/// the page shown. The row's keys are off (`KeyAction.answersInTabs`): with no row on screen,
/// `⌥←` goes back to being word movement and `⌥W` to typing «∑».
struct TabbedWindowView: View {
    var addressFocus: FocusState<UUID?>.Binding

    @Environment(BrowserState.self) private var browser

    /// What is under the tab bar: the tab in front, or the two halves of its split, left first.
    private var shown: [UUID] {
        guard let id = browser.selectedTabID else { return [] }
        let mates = browser.layout.columnMates(of: id)
        return mates.count > 1 ? mates : [id]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
                // In front of the page for the reason the row's top bar is: siblings in a stack are
                // hit-tested in order, and a web view's reach does not stop at its frame.
                .zIndex(2)
            TabToolbar(addressFocus: addressFocus)
                .zIndex(1)
            GeometryReader { proxy in
                Group {
                    if browser.selectedTab != nil {
                        // The tab in front, or both halves of the split it is in. One `ForEach` by tab
                        // either way, so a tab joining or leaving a split keeps its view — the page
                        // under it is a `WebPage`, and two views over one of those trap in WebKit.
                        HStack(spacing: 1) {
                            ForEach(shown, id: \.self) { id in
                                if let tab = browser.tab(id) {
                                    let isFocused = id == browser.selectedTabID
                                    ColumnView(tab: tab, isFocused: isFocused, isCurrentWorkspace: true,
                                               side: shown.count > 1 ? (id == shown.first ? .left : .right) : .whole,
                                               isLive: true, chromeless: true)
                                        // Which half has the keyboard, when there are two.
                                        .overlay(alignment: .top) {
                                            if shown.count > 1, isFocused {
                                                Rectangle().fill(Color.accentColor).frame(height: 2)
                                            }
                                        }
                                }
                            }
                        }
                        .background(Color(nsColor: .separatorColor))
                    } else {
                        NoTabs()
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                // The layout's viewport is the page's size either way, so what is measured off it —
                // the pictures a window keeps of itself, the address field's share of the bar — is
                // the size the page is actually drawn at.
                .onChange(of: proxy.size, initial: true) { browser.layout.updateViewport(proxy.size) }
            }
        }
    }
}

// MARK: - The tab bar

/// The groups and their tabs, left to right, in the band the row's top bar uses.
///
/// Tabs share the width the way Chrome's do — each as wide as the row allows up to a ceiling, and
/// narrower as there are more of them, down to a floor where the row starts to scroll instead. The
/// two numbers are control metrics, not layout: a tab is a label with an icon in it, and a label has
/// a readable width whatever the display.
private struct TabStrip: View {
    @Environment(BrowserState.self) private var browser
    /// The group whose name is being typed, if any — from its menu, or straight after "New Group".
    @State private var renaming: UUID?

    static let height: CGFloat = 38
    private static let tabRange: ClosedRange<CGFloat> = 56...220
    /// What a group's label takes of the row, for sharing out the rest; its real width is its own.
    private static let chipAllowance: CGFloat = 84

    var body: some View {
        let groups = TabGroup.all(in: browser)
        HStack(spacing: 0) {
            Color.clear.frame(width: 78, height: 1) // room for the window buttons
            GeometryReader { proxy in
                let width = tabWidth(groups, available: proxy.size.width - 36)
                ScrollViewReader { scroller in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(groups) { group in
                                let chip = group.isGroup || renaming == group.id
                                if chip {
                                    GroupChip(group: group, renaming: $renaming)
                                        .id(group.id)
                                }
                                if !group.isCollapsed || group.holdsSelection(browser) {
                                    ForEach(group.tabIDs, id: \.self) { id in
                                        if let tab = browser.tab(id) {
                                            TabItem(tab: tab, group: group, width: width,
                                                    tint: chip ? group.color : nil,
                                                    rename: { renaming = $0 })
                                                .id(id)
                                        }
                                    }
                                }
                            }
                            // Not on an empty bar: the window's own "New Tab" is right under it,
                            // and a lone + in the corner is a second button for the same thing.
                            if !groups.isEmpty { NewTabButton() }
                        }
                        .padding(.horizontal, 4)
                        .frame(height: proxy.size.height, alignment: .bottom)
                        .frame(minWidth: proxy.size.width, alignment: .leading)
                        .background { WindowMover() }
                    }
                    .onChange(of: browser.selectedTabID, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
                    }
                }
            }
        }
        .frame(height: Self.height)
        .background {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                WindowMover()
            }
        }
        // Dropped on the bare bar: out of its group, to the end.
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            browser.moveTabToEnd(id)
            return true
        }
        .animation(.easeOut(duration: 0.15), value: groups.map(\.isCollapsed))
    }

    private func tabWidth(_ groups: [TabGroup], available: CGFloat) -> CGFloat {
        let shown = groups.filter { !$0.isCollapsed || $0.holdsSelection(browser) }
        let count = CGFloat(max(1, shown.reduce(0) { $0 + $1.tabIDs.count }))
        let labels = CGFloat(groups.filter(\.isGroup).count) * Self.chipAllowance
        let share = ((available - labels) / count).rounded(.down)
        return min(Self.tabRange.upperBound, max(Self.tabRange.lowerBound, share))
    }
}

/// A workspace as the tab bar sees it.
struct TabGroup: Identifiable {
    var id: UUID
    var index: Int
    var name: String
    var title: String
    var tabIDs: [UUID]
    var columns: [TilingColumn]
    var isCollapsed: Bool

    /// Every row with a window in it, in the strip's order. The spare empty row the row keeps at the
    /// bottom is not a group, and neither is a named row that has just emptied — the question it is
    /// asking (`WorkspaceRemovalDialog`) is on screen either way.
    @MainActor
    static func all(in browser: BrowserState) -> [TabGroup] {
        let layout = browser.layout
        return layout.workspaces.enumerated().compactMap { index, workspace in
            guard !workspace.isEmpty else { return nil }
            return TabGroup(id: workspace.id, index: index, name: workspace.name,
                            title: layout.title(at: index), tabIDs: workspace.columns.flatMap(\.tabIDs),
                            columns: workspace.columns, isCollapsed: workspace.isFolded)
        }
    }

    var isGroup: Bool { !name.isEmpty }

    @MainActor
    func holdsSelection(_ browser: BrowserState) -> Bool {
        browser.selectedTabID.map(tabIDs.contains) ?? false
    }

    /// Where a window stands in the row, as the column index `TilingLayout.placeTab` wants.
    func columnIndex(of tabID: UUID) -> Int? {
        columns.firstIndex { $0.holds(tabID) }
    }

    /// The group's colour, which is the workspace's own and stays put: read off its id rather than
    /// its place, so a group does not change colour when another one is closed before it.
    var color: Color {
        Self.palette[Int(id.uuid.0) % Self.palette.count]
    }

    private static let palette: [Color] = [.blue, .red, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
}

// MARK: - A group's label

/// The coloured label in front of a group's tabs. A click folds the group up to it, or opens it
/// again; its menu names, folds, adds to and closes the group.
private struct GroupChip: View {
    let group: TabGroup
    @Binding var renaming: UUID?

    @Environment(BrowserState.self) private var browser
    @State private var draft = ""
    @State private var isTargeted = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if renaming == group.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 120)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { renaming = nil }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .onAppear {
                        draft = group.name
                        focused = true
                    }
            } else {
                HStack(spacing: 5) {
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if group.isCollapsed {
                        Text(group.tabIDs.count, format: .number)
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .onTapGesture { browser.toggleGroup(group.id) }
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(group.color.opacity(isTargeted ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(maxWidth: 180)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 3)
        .padding(.bottom, 4)
        .help(group.isCollapsed ? String(localized: "Expand Group") : String(localized: "Collapse Group"))
        .contextMenu { menu }
        // A tab dropped on the label goes to the end of the group.
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            browser.placeTab(id, inGroup: group.id, at: group.columns.count)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder
    private var menu: some View {
        Button("New Tab in Group") { browser.newTab(inGroup: group.id) }
        Button("Rename Group…") { renaming = group.id }
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") { browser.toggleGroup(group.id) }
        Button("Ungroup") { browser.ungroup(group.id) }
        Divider()
        Button("Close Group", role: .destructive) { browser.closeGroup(group.id) }
    }

    /// A new group left unnamed keeps "Workspace N", or it would stop being a group.
    private func commit() {
        guard renaming == group.id else { return }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        browser.layout.rename(workspaceAt: group.index,
                              to: typed.isEmpty && group.name.isEmpty ? group.title : typed)
        renaming = nil
    }
}

// MARK: - One tab

private struct TabItem: View {
    let tab: BrowserTab
    let group: TabGroup
    let width: CGFloat
    /// The group's colour along the tab's foot, while the row is showing groups at all.
    let tint: Color?
    let rename: (UUID) -> Void

    @Environment(BrowserState.self) private var browser
    @State private var hovering = false
    /// Which side of this tab a dragged one would land on, while one is over it.
    @State private var dropSide: Int?

    private var isSelected: Bool { browser.selectedTabID == tab.id }
    /// Picked with ⌘ or ⇧ along with others, and not the one in front (`BrowserState.clickTab`).
    private var isPicked: Bool { !isSelected && browser.pickedTabs.contains(tab.id) }
    private var showsClose: Bool { (hovering || isSelected) && width > 80 }

    private func dragPreview() -> NSImage? {
        let icon = tab.isWebPage ? browser.siteIcons.icon(for: tab.currentURL?.host()) : nil
        let plate = HStack(spacing: 6) {
            if let icon {
                Image(platform: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
            } else {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(tab.showsStartPage || tab.title.isEmpty ? String(localized: "New Tab") : tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 30, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor),
                    in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous))
        .opacity(0.9)
        let renderer = ImageRenderer(content: plate)
        renderer.scale = NSApp.keyWindow?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    var body: some View {
        HStack(spacing: 6) {
            TabMark(tab: tab)
            if browser.layout.columnMates(of: tab.id).count > 1 {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("Shown Side by Side")
            }
            // A start page's title is the row's "New Window"; here it is a tab.
            Text(tab.showsStartPage || tab.title.isEmpty ? String(localized: "New Tab") : tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            if showsClose {
                Button { browser.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 30)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                      : isPicked ? AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.26 : 0.18))
                      : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0)))
        }
        .overlay(alignment: .bottom) {
            if let tint {
                Capsule().fill(tint).frame(height: 2).padding(.horizontal, 6)
            }
        }
        .overlay(alignment: dropSide == -1 ? .leading : .trailing) {
            if dropSide != nil {
                Capsule().fill(Color.accentColor).frame(width: 2).padding(.vertical, 5)
            }
        }
        .contentShape(Rectangle())
        // ⌘ picks one tab, ⇧ a run. Not ⌃: that is the secondary click.
        .overlay {
            TabDragSource(tabID: tab.id, title: tab.title, passThrough: showsClose ? 28 : 0,
                          preview: dragPreview,
                          click: { held in
                              browser.clickTab(tab.id, adding: held.contains(.command), extending: held.contains(.shift))
                          },
                          hover: { hovering = $0 })
        }
        .contextMenu { TabMenu(tab: tab, group: group, rename: rename) }
        .onDrop(of: [.plainText], delegate: TabDrop(width: width, side: $dropSide) { id, side in
            guard id != tab.id, let here = group.columnIndex(of: tab.id) else { return }
            browser.placeTab(id, inGroup: group.id, at: side < 0 ? here : here + 1)
        })
    }
}

/// A tab dragged over another: which half it is over, for the mark, and where it lands. A delegate
/// rather than `dropDestination`, which says where the pointer is only once it is let go.
private struct TabDrop: DropDelegate {
    let width: CGFloat
    @Binding var side: Int?
    let land: (UUID, Int) -> Void

    private func half(_ info: DropInfo) -> Int { info.location.x < width / 2 ? -1 : 1 }

    func dropEntered(info: DropInfo) { side = half(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        side = half(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { side = nil }

    func performDrop(info: DropInfo) -> Bool {
        let landing = half(info)
        side = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? NSString, let id = UUID(uuidString: text as String) else { return }
            Task { @MainActor in land(id, landing) }
        }
        return true
    }
}

/// The tab's icon: a spinner while it loads, the site's own mark, or the glyph for what kind of
/// window it is.
private struct TabMark: View {
    let tab: BrowserTab
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Group {
            if !tab.isDocument, tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if tab.isWebPage, let icon = browser.siteIcons.icon(for: tab.currentURL?.host()) {
                Image(platform: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: tab.isDocument ? "doc.text" : tab.builtIn != nil ? "gearshape" : "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 14, height: 14)
    }
}

private struct TabMenu: View {
    let tab: BrowserTab
    let group: TabGroup
    let rename: (UUID) -> Void

    @Environment(BrowserState.self) private var browser

    var body: some View {
        // Opened on one of several picked tabs, the menu is about all of them — Chrome's rule. On a
        // tab outside the pick it is about that tab alone.
        let picked = browser.pickedTabsInOrder
        if picked.count > 1, picked.contains(tab.id) {
            many(picked)
        } else {
            one
        }
    }

    @ViewBuilder
    private func many(_ ids: [UUID]) -> some View {
        if ids.count == 2 {
            Button("Show Side by Side") { browser.showSideBySide(ids[0], ids[1]) }
            Divider()
        }
        Button("Add \(ids.count) Tabs to New Group") {
            if let created = browser.moveTabsToNewGroup(ids) { rename(created) }
        }
        let groups = TabGroup.all(in: browser).filter(\.isGroup)
        if !groups.isEmpty {
            Menu("Move \(ids.count) Tabs to Group") {
                ForEach(groups) { other in
                    Button(other.title) { browser.moveTabs(ids, toGroup: other.id) }
                }
            }
        }
        Divider()
        Button("Close \(ids.count) Tabs") { browser.closeTabs(ids) }
    }

    @ViewBuilder
    private var one: some View {
        Button("New Tab to the Right") {
            browser.selectTab(tab.id)
            browser.newTab()
        }
        Button("Reload") { tab.reload() }
        if browser.layout.columnMates(of: tab.id).count > 1 {
            Button("Stop Showing Side by Side") { browser.separate(tab.id) }
        }
        Divider()
        Button("Add Tab to New Group") {
            if let created = browser.moveTabToNewGroup(tab.id) { rename(created) }
        }
        let others = TabGroup.all(in: browser).filter { $0.isGroup && $0.id != group.id }
        if !others.isEmpty {
            Menu("Move Tab to Group") {
                ForEach(others) { other in
                    Button(other.title) { browser.placeTab(tab.id, inGroup: other.id, at: other.columns.count) }
                }
            }
        }
        if group.isGroup {
            Button("Remove from Group") { browser.removeFromGroup(tab.id) }
        }
        if browser.profiles.count > 1 {
            Menu("Move to Profile") { MoveToProfileItems(tab: tab) }
        }
        Divider()
        Button("Close Tab") { browser.closeTab(tab.id) }
        Button("Close Other Tabs") { browser.closeOtherTabs(besides: tab.id) }
            .disabled(group.tabIDs.count < 2)
    }
}

private struct NewTabButton: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Button { browser.newTabAtEnd() } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.bottom, 2)
        .help("New Tab (⌘T)")
    }
}

// MARK: - The toolbar

/// What the row's top bar carries about the page, and nothing about the row: the address with its
/// own back, forward and reload, the star and the share sheet, then downloads, extensions and the
/// profile.
private struct TabToolbar: View {
    var addressFocus: FocusState<UUID?>.Binding
    @Environment(BrowserState.self) private var browser

    var body: some View {
        HStack(spacing: 8) {
            if let tab = browser.selectedTab {
                AddressBar(tab: tab, addressFocus: addressFocus)
                BookmarkButton(tab: tab)
                ShareButton(tab: tab)
            } else {
                Spacer()
            }
            DownloadsButton()
            ExtensionActionBar()
            ProfileMenuButton()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let tab = browser.selectedTab, !tab.isDocument, tab.isLoading {
                LoadingLine(progress: tab.estimatedProgress, accent: accent(of: tab))
            } else {
                Divider()
            }
        }
        .animation(.easeOut(duration: 0.2), value: browser.selectedTab?.isLoading)
    }

    private func accent(of tab: BrowserTab) -> Color {
        browser.profiles.first { $0.id == tab.profileID }?.color ?? .accentColor
    }
}

/// Every tab closed: the one thing left to do, and its key.
private struct NoTabs: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        VStack(spacing: 10) {
            Button { browser.newTab() } label: {
                Label("New Tab", systemImage: "plus").padding(.horizontal, 6)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            Text("or ⌘T")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
#endif

