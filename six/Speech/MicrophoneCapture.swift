#if os(macOS)
import AVFoundation
import FluidAudio

/// Where dictation hears from: 16 kHz mono Float32, in chunks, until stopped.
nonisolated protocol SpeechAudioSource: AnyObject, Sendable {
    func start(_ deliver: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

/// The microphone, only while dictation is on.
nonisolated final class MicrophoneCapture: SpeechAudioSource, @unchecked Sendable {
    enum Failure: Error { case noInput }

    private let engine = AVAudioEngine()
    private let converter = AudioConverter()

    func start(_ deliver: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        // The deprecated tap's replacement has no Swift overlay yet: it imports as throwing, with `()` for its error.
        try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: ()) { [converter] buffer, _ in
            guard let samples = try? converter.resampleBuffer(buffer), !samples.isEmpty else { return }
            deliver(samples)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
#endif
