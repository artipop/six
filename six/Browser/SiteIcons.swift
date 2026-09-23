#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Foundation
import WebKit

/// The little picture a site draws itself with, kept by host. six had favicons on no front
/// ([todo.md](../../docs/todo.md)), and the overview is where that showed: a card with no
/// screenshot yet was a globe and a line of text.
///
/// **The page fetches it, not six.** A `URLSession` asking `https://host/favicon.ico` is a second
/// visit to that site from outside the profile it belongs to — no cookies of its own, none of the
/// blocking that was applied to the page, and one a private window would make as readily as any
/// other. The page is already there and already allowed, so it does the asking and leaves a `data:`
/// URL on its window for six to pick up. `callJavaScript` is not `callAsyncJavaScript` (AGENTS.md),
/// so the script starts the work and the answer is polled for.
@MainActor
@Observable
final class SiteIcons {
    static let folder: URL = AppSupport.folder("SiteIcons")

    /// What the views read; `missing` is what stops a host with none being looked for on disk again
    /// on every frame of the overview.
    private var images: [String: PlatformImage] = [:]

    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var reading: Set<String> = []
    /// Hosts this run has already asked a page about, so a reload is not another fetch.
    @ObservationIgnored private var asked: Set<String> = []

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

    /// A page has finished loading: ask it for its own icon, once per host per run. A private
    /// window never reaches here — `BrowserState` gives a private profile no `SiteIcons` at all.
    func refresh(_ page: WebPage) {
        guard let host = Self.key(page.url?.host()), !asked.contains(host) else { return }
        asked.insert(host)
        guard images[host] == nil else { return }
        Task { [weak self] in
            guard let data = await Self.ask(page) else { return }
            guard let self, let image = PlatformImage(data: data), image.size.width > 1 else { return }
            self.images[host] = image
            self.missing.remove(host)
            Self.write(data, for: host)
        }
    }

    /// Forgets every host's icon file: an icon is a record of a site having been visited.
    func clear() {
        images.removeAll()
        missing.removeAll()
        asked.removeAll()
        let folder = Self.folder
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Asking the page

    /// Starts the script and waits for the window property it fills in. A page may answer at once
    /// or never — a request refused by CORS, a site with no icon — so the wait is short and the
    /// failure silent.
    private static func ask(_ page: WebPage) async -> Data? {
        guard (try? await page.callJavaScript(script)) != nil else { return nil }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            guard let answer = (try? await page.callJavaScript("return window.__sixIcon || null")) as? String
            else { continue }
            guard answer != "none" else { return nil }
            guard let comma = answer.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(answer[answer.index(after: comma)...]))
            else { return nil }
            return data
        }
        return nil
    }

    /// Reads the page's own `<link rel="icon">` tags, best first, falls back to `/favicon.ico` and
    /// draws whichever arrives into a 64-point canvas — which is what makes an SVG usable, since
    /// `PlatformImage` cannot decode one. Promises rather than `await`: the body of a
    /// `callJavaScript` call is parsed as a plain function body.
    private static let script = """
    if (window.__sixIconFor !== location.origin) {
      window.__sixIconFor = location.origin;
      window.__sixIcon = null;
      var links = Array.prototype.slice.call(document.querySelectorAll('link[rel]'))
        .filter(function (l) { return /(^|\\s)(shortcut\\s+)?icon(\\s|$)/i.test(l.rel) || /apple-touch-icon/i.test(l.rel); })
        .map(function (l) {
          var side = parseInt((l.sizes && l.sizes.value || '').split('x')[0], 10) || 0;
          return { href: l.href, score: side === 0 ? 48 : 128 - Math.abs(64 - side) };
        })
        .sort(function (a, b) { return b.score - a.score; })
        .map(function (l) { return l.href; });
      links.push(location.origin + '/favicon.ico');
      var draw = function (url) {
        return new Promise(function (resolve, reject) {
          var image = new Image();
          image.onload = function () {
            try {
              var canvas = document.createElement('canvas');
              canvas.width = 64; canvas.height = 64;
              canvas.getContext('2d').drawImage(image, 0, 0, 64, 64);
              resolve(canvas.toDataURL('image/png'));
            } catch (e) { reject(e); }
          };
          image.onerror = reject;
          image.src = url;
        });
      };
      var next = function (i) {
        if (i >= links.length) { window.__sixIcon = 'none'; return; }
        fetch(links[i], { credentials: 'include' })
          .then(function (r) { return r.ok ? r.blob() : Promise.reject(); })
          .then(function (b) { return b.size > 0 && b.size < 524288 ? b : Promise.reject(); })
          .then(function (b) {
            return new Promise(function (resolve, reject) {
              var reader = new FileReader();
              reader.onload = function () { resolve(reader.result); };
              reader.onerror = reject;
              reader.readAsDataURL(b);
            });
          })
          .then(function (d) {
            return draw(d).catch(function () {
              // WebKit's <img> refuses a data: URL that says image/x-icon — measured — and a .ico
              // is what half the web serves; ImageIO takes it, so those bytes go back as they came.
              return /^data:image\\/(x-icon|vnd\\.microsoft\\.icon)/.test(d) ? d : Promise.reject();
            });
          })
          .then(function (d) { window.__sixIcon = d; })
          .catch(function () { next(i + 1); });
      };
      next(0);
    }
    return 1;
    """

    // MARK: The files

    /// One file per host, like the thumbnails, and named `.icon` rather than `.png` because what is
    /// kept is whatever the page handed back — a canvas PNG usually, the original `.ico` bytes for
    /// the sites the page could not draw itself.
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
