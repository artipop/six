import Foundation
import WebKit

extension WebPage {
    /// Loads a request and waits for that navigation to end, or for the ceiling.
    func loadAndSettle(_ request: URLRequest, timeout: TimeInterval) async {
        let navigation = load(request)
        let watch = Task {
            do {
                for try await event in navigation {
                    if case .finished = event { return }
                }
            } catch {}
        }
        let ceiling = Task {
            try? await Task.sleep(for: .seconds(timeout))
            watch.cancel()
        }
        await watch.value
        ceiling.cancel()
    }
}
