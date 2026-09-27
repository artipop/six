#if os(macOS)
import Foundation

/// The browser's side of `six --ax-read`: starts the reader on the first request, keeps it while
/// reads keep coming, and lets it go after a quiet spell.
///
/// Launched by six itself, from six's own executable — the one shape of second process macOS counts
/// as six for Privacy & Security ▸ Accessibility, besides an XPC service ([accessibility.md]).
nonisolated final class AXReadProcess: @unchecked Sendable {
    static let shared = AXReadProcess()

    /// A walk is cut at five seconds by the child; past this the child is taken to be stuck.
    private static let answerTimeout: TimeInterval = 8
    private static let idleTimeout: TimeInterval = 30

    // Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "org.deffun.six.accessibility", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var idle: DispatchWorkItem?

    func snapshot(at point: CGPoint, visible: CGRect, limit: Int) async -> AXPageSnapshot {
        let request = AXReadRequest(point: point, visible: visible, limit: limit)
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.exchange(request)) }
        }
    }

    private func exchange(_ request: AXReadRequest) -> AXPageSnapshot {
        let reused = process?.isRunning == true
        let snapshot = ask(request)
        // A process keeps the answer to "am I trusted" it was started with, so one started before the
        // grant stays refused after it.
        guard reused, snapshot.failure == .notTrusted else { return snapshot }
        stop()
        return ask(request)
    }

    private func ask(_ request: AXReadRequest) -> AXPageSnapshot {
        idle?.cancel()
        let started = Date()
        defer {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 1 { Log.info(.pages, "six --ax-read took \(Int(elapsed * 1000)) ms") }
        }
        var failed = AXPageSnapshot()
        failed.failure = .noAnswer
        guard let process = running(), let input, var line = try? JSONEncoder().encode(request) else { return failed }
        line.append(0x0A)
        do { try input.write(contentsOf: line) } catch {
            stop()
            return failed
        }

        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.answerTimeout, execute: watchdog)
        let answer = readLine()
        watchdog.cancel()
        guard let answer, let snapshot = try? JSONDecoder().decode(AXPageSnapshot.self, from: answer) else {
            Log.error(.pages, "six --ax-read gave no answer; stopping it")
            stop()
            return failed
        }

        let quiet = DispatchWorkItem { [weak self] in self?.stop() }
        idle = quiet
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: quiet)
        return snapshot
    }

    private func running() -> Process? {
        if let process, process.isRunning { return process }
        stop()
        guard let executable = Bundle.main.executableURL else { return nil }
        let child = Process()
        child.executableURL = executable
        child.arguments = [PageAccessibilityReader.flag, String(getpid())]
        let toChild = Pipe()
        let fromChild = Pipe()
        child.standardInput = toChild
        child.standardOutput = fromChild
        do { try child.run() } catch {
            Log.error(.pages, "six --ax-read could not start: \(error.localizedDescription)")
            return nil
        }
        process = child
        input = toChild.fileHandleForWriting
        output = fromChild.fileHandleForReading
        buffer = Data()
        return child
    }

    /// Blocks until a whole line has arrived; nil once the child has gone.
    private func readLine() -> Data? {
        guard let output else { return nil }
        while true {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                return Data(line)
            }
            // Not `read(upToCount:)`, which waits for the whole count or the end of the pipe.
            let chunk = output.availableData
            guard !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }

    private func stop() {
        idle?.cancel()
        idle = nil
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
        buffer = Data()
    }
}
#endif
