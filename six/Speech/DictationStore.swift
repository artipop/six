#if os(macOS)
import AVFoundation
import FluidAudio
import Foundation
import Observation

/// Dictation into a text field: listen, show what is being heard, and hand the final text to the
/// field that asked. Nothing is ever sent from here.
@MainActor
@Observable
final class DictationStore {
    static let shared = DictationStore()

    enum State: Equatable {
        case idle
        case loading(Double)
        case listening
        case finishing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The field that is being dictated into.
    private(set) var owner: String?
    private(set) var draft = ""
    private(set) var level: Float = 0

    var isModelDownloaded: Bool { ParakeetTranscriber.isDownloaded }

    @ObservationIgnored private let transcriber = ParakeetTranscriber()
    @ObservationIgnored private var capture: (any SpeechAudioSource)?
    @ObservationIgnored private var source: (any SpeechAudioSource)?
    @ObservationIgnored private var deliver: ((String) -> Void)?
    @ObservationIgnored private var session: Task<Void, Never>?
    @ObservationIgnored private var samples: [Float] = []
    @ObservationIgnored private var draftTask: Task<Void, Never>?
    @ObservationIgnored private var draftedAt = 0
    @ObservationIgnored private var idleUnload: Task<Void, Never>?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?

    private static let silenceToEnd = 2.0
    private static let silenceBeforeSpeech = 8.0
    private static let longest = 300.0
    private static let idleBeforeUnload = Duration.seconds(300)
    private static let speechThreshold: Float = 0.5

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.unloadIfIdle(reason: "memory pressure") }
        }
        source.resume()
        memoryPressure = source
    }

    func isActive(_ owner: String) -> Bool {
        self.owner == owner && state != .idle
    }

    /// Starts listening for `owner`, or stops if it is already listening for it.
    /// `source` is for the self-test; nil is the microphone.
    func toggle(owner: String, source: (any SpeechAudioSource)? = nil, deliver: @escaping (String) -> Void) {
        if self.owner == owner, state == .listening {
            finish()
            return
        }
        guard session == nil else { return }
        self.owner = owner
        self.deliver = deliver
        self.source = source
        session = Task { await run() }
    }

    func cancel() {
        guard session != nil else { return }
        deliver = nil
        finish()
    }

    func dismissFailure() {
        if case .failed = state { reset() }
    }

    private func run() async {
        idleUnload?.cancel()
        let allowed = source != nil ? true : await microphoneAllowed()
        guard allowed else {
            fail(String(localized: "Microphone access is off in System Settings → Privacy & Security."))
            return
        }
        do {
            if await !transcriber.isLoaded {
                state = .loading(0)
                try await transcriber.load { fraction in
                    Task { @MainActor in
                        if case .loading = DictationStore.shared.state { DictationStore.shared.state = .loading(fraction) }
                    }
                }
            }
            await transcriber.resetSpeechDetector()
            try await listen()
        } catch is CancellationError {
            stopCapture()
            reset()
        } catch {
            stopCapture()
            Log.error(.speech, "dictation failed: \(error)")
            fail(error.localizedDescription)
        }
    }

    private func listen() async throws {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let capture = source ?? MicrophoneCapture()
        try capture.start { continuation.yield($0) }
        self.capture = capture
        samples = []
        draft = ""
        draftedAt = 0
        state = .listening
        Log.info(.speech, "listening")

        let rate = ParakeetTranscriber.sampleRate
        var pending: [Float] = []
        var heardSpeech = false
        var lastSpeech = 0
        for await chunk in stream {
            guard state == .listening else { break }
            samples += chunk
            pending += chunk
            level = min(1, rms(chunk) * 12)
            while pending.count >= VadManager.chunkSize {
                let window = Array(pending.prefix(VadManager.chunkSize))
                pending.removeFirst(VadManager.chunkSize)
                if try await transcriber.speechProbability(window) >= Self.speechThreshold {
                    heardSpeech = true
                    lastSpeech = samples.count
                }
            }
            let quiet = Double(samples.count - lastSpeech) / Double(rate)
            if heardSpeech, quiet >= Self.silenceToEnd { break }
            if !heardSpeech, quiet >= Self.silenceBeforeSpeech { break }
            if Double(samples.count) / Double(rate) >= Self.longest { break }
            if heardSpeech, draftTask == nil, samples.count - draftedAt >= rate { redraft() }
        }
        stopCapture()
        continuation.finish()

        draftTask?.cancel()
        draftTask = nil
        guard heardSpeech, let deliver else {
            reset()
            scheduleUnload()
            return
        }
        state = .finishing
        let seconds = Double(samples.count) / Double(rate)
        let started = Date()
        let text = try await transcriber.transcribe(samples)
        let elapsed = Date().timeIntervalSince(started)
        Log.info(.speech, "final pass: \(String(format: "%.1f", seconds))s of audio in \(String(format: "%.2f", elapsed))s")
        if !text.isEmpty { deliver(text) }
        reset()
        scheduleUnload()
    }

    /// The grey text: the whole utterance again, at most one pass in flight.
    private func redraft() {
        draftedAt = samples.count
        let audio = samples
        draftTask = Task {
            let text = try? await transcriber.transcribe(audio)
            draftTask = nil
            if state == .listening, let text { draft = text }
        }
    }

    private func finish() {
        guard state == .listening else {
            session?.cancel()
            stopCapture()
            reset()
            return
        }
        // The loop sees the change at the next chunk and runs the final pass.
        state = .finishing
    }

    private func reset() {
        state = .idle
        owner = nil
        deliver = nil
        draft = ""
        level = 0
        samples = []
        source = nil
        session = nil
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        level = 0
    }

    private func fail(_ message: String) {
        let failed = owner
        reset()
        owner = failed
        state = .failed(message)
    }

    private func scheduleUnload() {
        idleUnload?.cancel()
        idleUnload = Task {
            try? await Task.sleep(for: Self.idleBeforeUnload)
            guard !Task.isCancelled else { return }
            unloadIfIdle(reason: "idle")
        }
    }

    private func unloadIfIdle(reason: String) {
        guard session == nil else { return }
        Task {
            guard await transcriber.isLoaded else { return }
            Log.info(.speech, "unloading: \(reason)")
            await transcriber.unload()
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func rms(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        return (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
    }
}
#endif
