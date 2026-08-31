// Does WebKit grant cross-origin isolation — and therefore SharedArrayBuffer and Atomics.wait in
// a worker — to a document served from a custom scheme handler with COOP/COEP headers? That is
// the one fact docs/mcp-sandbox.md's fourth tier stands on, so it is asked directly.
//
//   swiftc -framework WebKit -o coi Tests/Spikes/CrossOriginIsolation.swift && ./coi
//   swiftc -framework WebKit -o coi Tests/Spikes/CrossOriginIsolation.swift && ./coi http://127.0.0.1:8977/
//
// The second form loads the same page from a URL you serve yourself with the same two headers.
// Measured on macOS 27: the custom scheme reports crossOriginIsolated=true and no
// SharedArrayBuffer at all; loopback HTTP reports both, and Atomics.wait really blocks.
import Foundation
import WebKit

final class Handler: NSObject, WKURLSchemeHandler {
    let page = """
    <!doctype html><meta charset="utf-8"><script>
    (async () => {
      const out = { crossOriginIsolated: self.crossOriginIsolated, sab: false, worker: "n/a", waitAsync: typeof Atomics.waitAsync };
      try { new SharedArrayBuffer(8); out.sab = true; } catch (e) { out.sabError = String(e); }
      try {
        const src = `self.onmessage = e => { const a = new Int32Array(e.data); const r = Atomics.wait(a, 0, 0, 50); postMessage("wait:" + r + " sabInWorker:" + (typeof SharedArrayBuffer)); };`;
        const w = new Worker(URL.createObjectURL(new Blob([src], { type: "text/javascript" })));
        const sab = new SharedArrayBuffer(4);
        out.worker = await new Promise((res, rej) => { w.onmessage = e => res(e.data); w.onerror = e => rej(e.message); w.postMessage(sab); setTimeout(() => rej("timeout"), 3000); });
      } catch (e) { out.worker = "error: " + String(e); }
      document.title = JSON.stringify(out);
    })();
    </script>
    """

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let data = Data(page.utf8)
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(data.count),
            "Cross-Origin-Opener-Policy": "same-origin",
            "Cross-Origin-Embedder-Policy": "require-corp",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

let handler = Handler()
let configuration = WKWebViewConfiguration()
configuration.setURLSchemeHandler(handler, forURLScheme: "six-spike")
let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
let target = CommandLine.arguments.dropFirst().first ?? "six-spike://server/"
webView.load(URLRequest(url: URL(string: target)!))

var polls = 0
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
    polls += 1
    webView.evaluateJavaScript("document.title") { value, _ in
        if let title = value as? String, title.hasPrefix("{") {
            print("\(target) + COOP/COEP → \(title)")
            timer.invalidate()
            exit(0)
        } else if polls > 40 {
            print("no answer from the page")
            exit(1)
        }
    }
}
RunLoop.main.run()
