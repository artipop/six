import AppKit
import Foundation
import WebKit

/// The little picture a site draws itself with, kept by host: in the tab bar, and on a card or a
/// placeholder with no screenshot yet. WebKit names the page's icons and fetches them in the page's own
/// network session; a `URLSession` here would be a second visit from outside the profile.
@MainActor
@Observable
final class SiteIcons: NSObject {
    static let folder: URL = AppSupport.folder("SiteIcons")

    private var images: [String: PlatformImage] = [:]

    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var reading: Set<String> = []
    /// The score of the icon this run has fetched for a host; a host that has one is not fetched again.
    @ObservationIgnored private var fetched: [String: Int] = [:]
    @ObservationIgnored private var offers: [ObjectIdentifier: [Offer]] = [:]

    private struct Offer {
        let host: String
        let score: Int
        let answer: (((Data?) -> Void)?) -> Void
    }

    /// The icon for a host, if there is one to hand. Nil the first time it is asked about a host
    /// whose file has not been read back yet; the read starts here and arrives as an observation.
    func icon(for host: String?) -> PlatformImage? {
        guard let host = Self.key(host) else { return nil }
        if let image = images[host] { return image }
        guard !missing.contains(host), !reading.contains(host) else { return nil }
        reading.insert(host)
        let url = Self.url(for: host)
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let self else { return }
            self.reading.remove(host)
            if let data, let image = PlatformImage(data: data), image.size.width > 1 {
                self.images[host] = image
            } else {
                self.missing.insert(host)
            }
        }
        return nil
    }

    /// Forgets every host's icon file: an icon is a record of a site having been visited.
    func clear() {
        images.removeAll()
        missing.removeAll()
        fetched.removeAll()
        let folder = Self.folder
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Asking WebKit

    /// Takes the view's icon loads. A private window's view is never handed here, and with nobody
    /// to ask WebKit requests no icon at all.
    func watch(_ view: WKWebView) {
        guard view.responds(to: #selector(IconLoadingView.setIconLoadingDelegate(_:))) else { return }
        unsafeBitCast(view, to: IconLoadingView.self).setIconLoadingDelegate(self)
    }

    /// WebKit asks once for every icon a loaded page names, all in one turn, `/favicon.ico` when it
    /// names none. Every answer block has to be called, with nil for the ones not wanted.
    @objc(webView:shouldLoadIconWithParameters:completionHandler:)
    func webView(_ view: WKWebView, shouldLoadIconWith parameters: NSObject,
                 completionHandler: @escaping (((Data?) -> Void)?) -> Void) {
        guard view.configuration.websiteDataStore.isPersistent,
              let host = Self.key(view.url?.host()), fetched[host] == nil
        else { return completionHandler(nil) }
        let icon = unsafeBitCast(parameters, to: LinkIcon.self)
        let offer = Offer(host: host, score: Self.score(icon), answer: completionHandler)
        let id = ObjectIdentifier(view)
        guard offers[id] == nil else { offers[id]?.append(offer); return }
        offers[id] = [offer]
        Task { [weak self] in self?.choose(among: id) }
    }

    /// The best few are fetched rather than the best one: the first choice may be refused or not decode.
    private func choose(among id: ObjectIdentifier) {
        let ranked = (offers.removeValue(forKey: id) ?? []).sorted { $0.score > $1.score }
        for (place, offer) in ranked.enumerated() {
            guard place < 3 else { offer.answer(nil); continue }
            offer.answer { [weak self] data in self?.arrived(data, for: offer.host, score: offer.score) }
        }
    }

    private func arrived(_ data: Data?, for host: String, score: Int) {
        guard let data, data.count < 524_288, score > fetched[host] ?? .min,
              let png = Self.png(from: data), let image = PlatformImage(data: png) else { return }
        fetched[host] = score
        images[host] = image
        missing.remove(host)
        Self.write(png, for: host)
    }

    /// Closeness to 64 pixels; an SVG counts as exact, an icon that names no size as a small one.
    private static func score(_ icon: LinkIcon) -> Int {
        if icon.mimeType == "image/svg+xml" || icon.url.pathExtension.lowercased() == "svg" { return 128 }
        guard let side = icon.size?.intValue, side > 0 else { return 48 }
        return 128 - abs(64 - side)
    }

    /// Whatever arrived — PNG, ICO, SVG — drawn at 64 pixels, so a large icon is not kept large.
    private static func png(from data: Data) -> Data? {
        guard let image = PlatformImage(data: data), image.size.width > 1 else { return nil }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: The files

    /// One file per host, like the thumbnails. A PNG now; `.icon` because older files hold `.ico` bytes.
    private static func url(for host: String) -> URL {
        folder.appending(path: "\(host).icon")
    }

    private static func write(_ data: Data, for host: String) {
        let url = url(for: host)
        let folder = folder
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// `www.` dropped: a site that redirects between the two is one site with one icon.
    private static func key(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard !host.isEmpty, !host.contains("/") else { return nil }
        return host
    }
}

@objc private protocol IconLoadingView {
    @objc(_setIconLoadingDelegate:)
    func setIconLoadingDelegate(_ delegate: AnyObject?)
}

/// `_WKLinkIconParameters`, as far as it is read.
@objc private protocol LinkIcon {
    var url: URL { get }
    var mimeType: String? { get }
    var size: NSNumber? { get }
}
