#if os(macOS)
import Darwin
import FluidAudio
import Foundation

/// A recording played at the pace of speech, then silence until dictation stops listening.
nonisolated final class RecordedAudio: SpeechAudioSource, @unchecked Sendable {
    let seconds: Double
    private let samples: [Float]
    private var task: Task<Void, Never>?

    init(_ url: URL) throws {
        samples = try AudioConverter().resampleAudioFile(url)
        seconds = Double(samples.count) / Double(ParakeetTranscriber.sampleRate)
    }

    func start(_ deliver: @escaping @Sendable ([Float]) -> Void) throws {
        let samples = samples
        task = Task.detached {
            let chunk = ParakeetTranscriber.sampleRate / 10
            var offset = 0
            while !Task.isCancelled {
                let end = min(offset + chunk, samples.count)
                deliver(offset < end ? Array(samples[offset..<end]) : [Float](repeating: 0, count: chunk))
                offset += chunk
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        task?.cancel()
    }
}

/// `SAVOIA_SPEECH_SELFTEST=<folder of recordings>`: each one through dictation as if it were spoken.
@MainActor
enum SpeechSelfTest {
    static func run(directory: URL) async {
        let kinds: Set = ["wav", "m4a", "aiff", "caf", "mp3"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { kinds.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        Log.info(.speech, "selftest: \(files.count) recordings, model on disk: \(ParakeetTranscriber.isDownloaded)")
        let store = DictationStore.shared
        for file in files {
            let source: RecordedAudio
            do { source = try RecordedAudio(file) } catch {
                Log.error(.speech, "selftest: \(file.lastPathComponent) unreadable: \(error)")
                continue
            }
            var text = ""
            var drafts = 0
            var lastDraft = ""
            let started = Date()
            store.toggle(owner: "selftest", source: source) { text = $0 }
            while store.owner == "selftest" {
                if case .failed(let message) = store.state {
                    Log.error(.speech, "selftest: \(file.lastPathComponent) failed: \(message)")
                    store.dismissFailure()
                    break
                }
                if store.draft != lastDraft { lastDraft = store.draft; drafts += 1 }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let elapsed = Date().timeIntervalSince(started)
            Log.info(.speech, """
                selftest: \(file.lastPathComponent) — \(String(format: "%.1f", source.seconds))s of audio, \
                done after \(String(format: "%.1f", elapsed))s, \(drafts) drafts, peak RSS \(peakMegabytes()) MB
                  \(text.isEmpty ? "(nothing)" : text)
                """)
        }
        Log.info(.speech, "selftest: done")
    }

    private static func peakMegabytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) / 1_048_576
    }
}
#endif
