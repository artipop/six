import SwiftUI
import WebKit

/// Per-column title bar. Every window in the strip carries its own navigation and address field,
/// the way a tiled window carries its own decorations.
struct WindowChrome: View {
    let tab: BrowserTab
    let isFocused: Bool
    var addressFocus: FocusState<UUID?>.Binding

    @Environment(BrowserState.self) private var browser
    @State private var text = ""
    @State private var hovering = false

    private var isEditing: Bool { addressFocus.wrappedValue == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            Button { _ = tab.page.load(tab.page.backForwardList.backList.last) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(tab.page.backForwardList.backList.isEmpty)
            .help("Back")

            Button { _ = tab.page.load(tab.page.backForwardList.forwardList.first) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(tab.page.backForwardList.forwardList.isEmpty)
            .help("Forward")

            Button {
                if tab.page.isLoading { tab.page.stopLoading() } else { _ = tab.page.reload() }
            } label: {
                Image(systemName: tab.page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(tab.page.isLoading ? "Stop" : "Reload")

            address

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
            if tab.page.isLoading {
                LoadingLine(progress: tab.page.estimatedProgress, accent: accent)
            }
        }
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
            Image(systemName: tab.page.url?.scheme == "https" ? "lock.fill" : "globe")
                .foregroundStyle(.secondary)
                .font(.system(size: 9))
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
