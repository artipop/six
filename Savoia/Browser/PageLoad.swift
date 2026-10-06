import Foundation
import WebKit

extension WKWebView {
    /// Loads a request and waits for that navigation to end, or for the ceiling. For a view that is
    /// no tab's: the wait takes the navigation delegate for as long as it lasts.
    func loadAndSettle(_ request: URLRequest, timeout: TimeInterval) async {
        let watcher = LoadWatcher()
        navigationDelegate = watcher
        load(request)
        let ceiling = Task {
            try? await Task.sleep(for: .seconds(timeout))
            watcher.settle()
        }
        await withCheckedContinuation { watcher.waiting = $0 }
        ceiling.cancel()
        navigationDelegate = nil
    }
}

private final class LoadWatcher: NSObject, WKNavigationDelegate {
    var waiting: CheckedContinuation<Void, Never>?

    func settle() {
        waiting?.resume()
        waiting = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settle() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { settle() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { settle() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { settle() }
}
