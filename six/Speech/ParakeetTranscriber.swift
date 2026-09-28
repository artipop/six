#if os(macOS)
import CoreML
import FluidAudio
import Foundation

/// Parakeet TDT v3 with Silero in front of it, both Core ML on the Neural Engine.
actor ParakeetTranscriber {
    enum Failure: Error { case notLoaded }

    static let sampleRate = 16_000

    /// `Models/parakeet-tdt-0.6b-v3-coreml` beside E5: FluidAudio files a model under the parent of
    /// the folder it is handed, named after its own repository.
    nonisolated static let directory = AppSupport.folder("Models")
        .appending(path: AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, directoryHint: .isDirectory)

    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: directory, version: .v3)
    }

    private var asr: AsrManager?
    private var vad: VadManager?
    private var vadState = VadStreamState.initial()

    var isLoaded: Bool { asr != nil }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard asr == nil else { return }
        // FluidAudio's debug lines carry the transcript, and nothing that was said goes into a log.
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        let start = Date()
        let models = try await AsrModels.downloadAndLoad(to: Self.directory, version: .v3) { progress($0.fractionCompleted) }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        // `modelDirectory/Models/<repo>` — the root, so that Silero lands in the same `Models/`.
        vad = try await VadManager(config: .default, modelDirectory: AppSupport.root)
        asr = manager
        Log.info(.speech, "parakeet loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }

    /// No language hint: the hint drops tokens in any other script, which turns the English terms
    /// of a Russian sentence into Cyrillic.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let asr else { throw Failure.notLoaded }
        var padded = samples
        if padded.count < Self.sampleRate { padded += [Float](repeating: 0, count: Self.sampleRate - padded.count) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(padded, decoderState: &state).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resetSpeechDetector() {
        vadState = .initial()
    }

    /// Takes `VadManager.chunkSize` samples.
    func speechProbability(_ chunk: [Float]) async throws -> Float {
        guard let vad else { throw Failure.notLoaded }
        let result = try await vad.processStreamingChunk(chunk, state: vadState)
        vadState = result.state
        return result.probability
    }

    func unload() async {
        await asr?.cleanup()
        asr = nil
        vad = nil
        vadState = .initial()
        Log.info(.speech, "parakeet unloaded")
    }
}
#endif
