#if os(macOS)
import AppKit
#endif
import Foundation

/// What six tells the web it is.
///
/// `WKWebView`'s default user agent stops at the application name:
/// `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Six/1.0`.
/// There is no `Version/… Safari/…` in it, and that is the token every browser-sniffing script looks
/// for. Without it the sniffers fall through to their "unknown, probably ancient" branch — which is
/// how a browser built on the current WebKit gets told to update itself.
///
/// So six presents the engine it actually runs on: the application name is set to Safari's own tail,
/// which makes the whole string identical to the Safari installed on this machine. Not a disguise —
/// the rendering, the JavaScript and the quirks really are that Safari's. Naming ourselves in the
/// same string is what broke it, so we don't.
enum UserAgent {
    /// Goes into `WebPage.Configuration.applicationNameForUserAgent`, which WebKit appends to its
    /// default string — so this tail is the whole difference from Safari's user agent.
    static let applicationName = "Version/\(safariVersion) Safari/\(webKitBuild)"

    /// The whole string, for the requests six makes itself rather than through a page — a download
    /// (`DownloadStore`), where a URLSession has no user agent of WebKit's to inherit and a site that
    /// checks would see `six/1.0 CFNetwork/…` instead of the browser that asked for the file.
    static let full: String = {
        #if os(macOS)
        let platform = "Macintosh; Intel Mac OS X 10_15_7"
        #elseif os(iOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let platform = "iPhone; CPU iPhone OS \(version.majorVersion)_\(version.minorVersion) like Mac OS X"
        #endif
        return "Mozilla/5.0 (\(platform)) AppleWebKit/\(webKitBuild) (KHTML, like Gecko) \(applicationName)"
    }()

    /// The build token WebKit freezes into every Safari user agent; kept in step with the default one.
    private static let webKitBuild = "605.1.15"

    /// Safari's marketing version, read from the copy on this machine, so the claim ages with the OS
    /// instead of with this file. Safari's major version has tracked macOS's since 26, which is what
    /// the fallback leans on when Safari can't be found or answers with something odd.
    private static let safariVersion: String = {
        #if os(macOS)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
              let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil
        else { return "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0" }
        return version
        #elseif os(iOS)
        // iOS has no readable Safari bundle; its major version is the system's own.
        return "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
        #endif
    }()
}
