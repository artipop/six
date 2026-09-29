#if os(macOS)
import AppKit
import SwiftUI

/// The downloads button in the top bar: there only when there is something to say, a ring while a
/// file is coming in, and the list behind it.
///
/// It is not always visible on purpose. A browser that has never downloaded anything has nothing to
/// show, and a permanent tray icon in a 38-point bar is a button that is wrong most of the time.
struct DownloadsButton: View {
    @Environment(BrowserState.self) private var browser
    @State private var showsList = false

    var body: some View {
        let downloads = browser.downloads
        if !downloads.items.isEmpty {
            Button {
                showsList.toggle()
                downloads.markSeen()
            } label: {
                ZStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(downloads.hasUnseen ? AnyShapeStyle(browser.selectedProfile.color) : AnyShapeStyle(.secondary))
                        // Every arrival lands here; the bounce is the button saying it caught it.
                        .symbolEffect(.bounce, value: browser.flights.landings)
                    if let fraction = downloads.progress {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(browser.selectedProfile.color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 17, height: 17)
                            .animation(.linear(duration: 0.2), value: fraction)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help(downloads.isRunning ? "Downloading…" : "Downloads")
            .popover(isPresented: $showsList, arrowEdge: .bottom) {
                DownloadsList()
                    .environment(browser)
            }
            // Where a download's flight lands. Said on every layout pass; the store keeps the last
            // one and reads it when a mark is made (`FlightStore.note`).
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { browser.flights.note(buttonCentre: $0) }
        }
    }
}

private struct DownloadsList: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let downloads = browser.downloads
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .buttonStyle(.borderless)
                    .disabled(downloads.items.allSatisfy { $0.state == .running })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(downloads.items) { item in
                        DownloadRow(item: item)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 380)
    }
}

private struct DownloadRow: View {
    let item: DownloadStore.Item
    @Environment(BrowserState.self) private var browser
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(item.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .running, let fraction = item.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if item.state == .running {
                Button { browser.downloads.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop")
            } else if item.canResume {
                // Two different acts behind one button, and the tooltip says which: a transfer with
                // resume data asks for the rest of the bytes, one without asks for the file again.
                Button { browser.resumeDownload(item.id) } label: {
                    Image(systemName: item.resumesInPlace ? "arrow.clockwise.circle" : "arrow.trianglehead.clockwise")
                }
                .buttonStyle(.borderless)
                .help(item.resumesInPlace ? "Resume" : "Try Again")
            } else if let destination = item.destination {
                Button { NSWorkspace.shared.activateFileViewerSelecting([destination]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        // A finished download opens; an unfinished one has nothing to open yet.
        .onTapGesture(count: 2) {
            guard let destination = item.destination else { return }
            NSWorkspace.shared.open(destination)
        }
        .contextMenu {
            if let destination = item.destination {
                Button("Open") { NSWorkspace.shared.open(destination) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                Divider()
            }
            if item.canResume {
                Button(item.resumesInPlace ? "Resume" : "Try Again") { browser.resumeDownload(item.id) }
                Divider()
            }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
            }
            Button("Remove from List") { browser.downloads.forget(item.id) }
        }
    }

    private var icon: String {
        switch item.state {
        case .running: "arrow.down.circle"
        case .finished: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "slash.circle"
        case .interrupted: "exclamationmark.arrow.circlepath"
        }
    }

    private var subtitle: String {
        switch item.state {
        case .running:
            let received = item.received.formatted(.byteCount(style: .file))
            guard item.expected > 0 else { return received }
            return "\(received) / \(item.expected.formatted(.byteCount(style: .file)))"
        case .finished:
            return "\(item.received.formatted(.byteCount(style: .file))) · \(item.url.host() ?? "")"
        case .failed:
            return item.error ?? String(localized: "Download failed")
        case .cancelled:
            guard item.received > 0, item.resumesInPlace else { return String(localized: "Stopped") }
            return String(localized: "Stopped at \(item.received.formatted(.byteCount(style: .file)))")
        case .interrupted:
            // How big it was, never how far it got: the bytes went with the session, and a number
            // for those would be a promise the button cannot keep.
            let where_ = item.url.host() ?? ""
            guard item.expected > 0 else {
                return where_.isEmpty ? String(localized: "Interrupted") : String(localized: "Interrupted · \(where_)")
            }
            return String(localized: "Interrupted · \(item.expected.formatted(.byteCount(style: .file))) · \(where_)")
        }
    }

}
#endif
