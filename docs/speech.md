# Dictation

A microphone beside the agent panel's composer and beside the ⌘E line: press it, say the sentence, and read it back
as text before it is sent. Nothing leaves the machine, Russian works as well as English, and **nothing is ever sent
by itself** — an agent that goes off and does something from a misheard sentence is worse than typing.

macOS only for now. The code is `six/Speech/`, all of it under `#if os(macOS)`, and FluidAudio is linked into the
`six` target alone.

ACP has no audio channel and is not going to grow one: the agent is a process at the other end of a JSON-RPC pipe, and
what it takes is a prompt. So recognition is six's problem, entirely, and the agent never learns it was spoken to.

## What decides the engine

**Russian.** Artem dictates in Russian, with English terms in the middle of it. Apple's `SpeechTranscriber`
(macOS 26) covers Cantonese, Chinese, English, French, German, Italian, Japanese, Korean, Portuguese and Spanish, and
Russian is not on that list. Apple's Russian is only `DictationTranscriber` — the engine behind the old
`SFSpeechRecognizer`. So the platform cannot be the answer here, the way `Translation` could be for pages.

**The machine.** Eight gigabytes, usually already in macOS's `.warning` band, with WebKit and the E5 embedder on the
GPU. That is what rules against MLX first, even though it is the house ML stack. The **Neural Engine** is idle the
rest of the time, and a Core ML model is the one way to use a part of this Mac nothing else is using.

**One dependency, not three.** Recognition needs a voice detector in front of it, or the model spends the pauses
inventing words and the utterance never ends by itself.

## The stack

[**FluidAudio**](https://github.com/FluidInference/FluidAudio) 0.17.4 — Apache-2.0, ~2.9k★, active — answers all
three. It carries **Parakeet TDT v3** (0.6B, 25 languages including `ru` and `uk`; NVIDIA reports 5.5% WER on
Fleurs Russian) and **Silero VAD**, both as Core ML, in one package with **no package dependencies at all**: adding it
put exactly one pin into the app's `Package.resolved` and moved nothing else. It does bring a prebuilt binary,
`NemoTextProcessing.xcframework` (text normalisation, Rust), which is always linked through Xcode.

Nothing goes into the root `Package.swift` or `SixCore`, so the Linux, Windows and root resolved files are untouched.

### Why Silero, and not the other three

| | |
|---|---|
| Apple `SpeechDetector` | Cannot run alone. It is a module of a `SpeechAnalyzer` that must also hold a transcriber, so it gates Apple's engine and is no use in front of Parakeet. |
| WebRTC VAD | Cheapest, and noticeably worse on breathing, keyboard noise and a fan. |
| TEN VAD | Better numbers than Silero on paper, no maintained Swift or Core ML port. |
| **Silero v6** | ~2 MB, a streaming state, a probability per 256 ms — and already in the package the recogniser comes from. |

## How it works

- **`MicrophoneCapture`** — `AVAudioEngine`'s input tap, resampled by FluidAudio's `AudioConverter` to 16 kHz mono
  Float32. The engine runs only while dictation is on, so the microphone light is off at rest. It sits behind
  `SpeechAudioSource`, which the self-test fills from a file instead.
- **`ParakeetTranscriber`** — an actor holding `AsrManager` and `VadManager`. Transcription is the **batch** call over
  the whole utterance, not FluidAudio's `SlidingWindowAsrManager`: dictation is seconds long, the batch pass sees the
  whole sentence, and it costs 0.07–0.2 s on the Neural Engine for 4–20 s of audio. The sliding window only confirms
  text after ten seconds of context, which is longer than most things said to an agent.
- **No language hint.** Parakeet v3 takes one, and it drops every token in another script: with `ru` set,
  "SwiftUI WebView" came back as «свифт уив вью». Without it the same recording gives «свифт UIWebView» and «в main».
- **`DictationStore`** — `@MainActor @Observable`, one per app (`DictationStore.shared`), because there is one
  microphone. The state (`idle` / `loading(progress)` / `listening` / `finishing` / `failed`), the grey draft, the
  level, and which field (`owner`) is being dictated into. While listening it re-transcribes the whole utterance about
  once a second, one pass in flight at a time, for the draft. The utterance ends on **two seconds of silence after
  speech**, eight seconds of silence before any, five minutes in all, or a second press; then one final pass, and the
  text is appended to the field.
- **`DictationButton`** / **`DictationDraft`** — the microphone (red and pulsing with the level while listening) and
  the grey draft under the agent composer. The ⌘E line is one line high, so its draft stands in the placeholder.

### The model

**The 470 MB are never fetched without being asked for.** The first press, with nothing on disk, asks; the download
goes to `Application Support/<bundle id>/Models/parakeet-tdt-0.6b-v3`, beside E5, and Silero to `Models/silero-vad`.
FluidAudio files a model under the *parent* of the folder it is handed, named after its own repository, which is why
`ParakeetTranscriber.directory` looks one level too deep.

The first load after a download compiles the model for the Neural Engine: **21 s**, once. After that a load is
**0.1 s**, so the model is unloaded freely: five minutes after the last dictation, and on any memory-pressure event
while nothing is being dictated — on this Mac that is the ordinary state, not the emergency.

### Logging

Engine load time, the length of each utterance and the time of its final pass go to `Log` under `speech`. **Never the
audio, and never the text.** FluidAudio's own debug lines contain the transcript, so `AppLogger.minimumLevel` is set
to `.warning` with the console mirror off before the model loads.

### The permission

`NSMicrophoneUsageDescription` was "A site you are visiting…", which stopped being true the moment six itself listened;
it is now worded for both. No `NSSpeechRecognitionUsageDescription` — the Speech framework is not used. The sandbox
and the hardened runtime are both off, so no entitlement is involved; if Release ever turns the hardened runtime on,
`com.apple.security.device.audio-input` goes with it.

## How it gets checked

`SIX_SPEECH_SELFTEST=<folder of recordings>` plays each `.wav`/`.m4a`/`.aiff`/`.caf`/`.mp3` in the folder, in name
order, through the same path as the microphone — Silero, drafts, the silence that ends it, the final pass — at the
pace of speech, then silence, and logs the text, the number of drafts and the process's peak RSS. It is the one place
the text is logged, because the recordings are the tester's own. Recordings made with `say -v Milena -o x.wav
--data-format=LEI16@16000 "…"` do for the pipeline; the accuracy on English terms wants a real voice.

Measured on the dev Mac at `0.17.4`, five recordings:

| recording | result |
|---|---|
| Russian, 6 s | word for word |
| Russian with English terms, 4 s | «Закон медь в main и проверь, что свифт UIВV не падает» — `say` reads the terms with a Russian accent too |
| English, 4 s | "Commit to main and check that the Swift 2i web view does not crash" |
| a sentence, 3 s of silence, a sentence | the first sentence only, ended by the silence |
| 17 s | four sentences, 19 drafts on the way, final pass 0.21 s |

Live, what still needs a person: the permission prompt's new wording, dictation into both fields, that the text lands
**and is not sent**, and a minute of pauses watched in Activity Monitor.

## Not done yet

- **Apple's `SpeechAnalyzer`** as the engine that downloads nothing, for the languages `SpeechTranscriber` has — the
  fallback while Parakeet is not on disk. Today the only answer without the download is "download it".
- **Settings**: engine, silence length, and a Dictation section with the model's size and a Delete.
- **A key** for it in the `KeyBindings` table, with a case in `KeySelfTest`.
- **iOS**: `AssistantBar` is on the phone, so the button costs little there — plus an `AVAudioSession` moved to
  `.record` for the length of the dictation.
- **Vocabulary boosting** exists in FluidAudio (a CTC model and a list of terms). Tried with `SwiftUI`, `WebView`,
  `main` on the mixed recording, it put `main` and `WebView` where they were not said; not switched on.

### The MLX path, later

[`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift) (MIT) has the same Parakeet v3, plus
Whisper-large-v3-turbo, plus Silero, all on MLX — and on the same `mlx-swift` that `MLXEmbedders` already puts in the
graph. It waits for a measurement that the GPU can take dictation next to rendering and the embedder, and for
mlx-swift versions that line up with the pinned `mlx-swift-lm`. `SpeechAudioSource` and the transcriber's three calls
(`load`, `transcribe`, `speechProbability`) are the seam it would slot into.

## The other fronts

Android has neither the agent panel nor the assistant yet; when it does,
`SpeechRecognizer.createOnDeviceSpeechRecognizer` (API 31+) is offline, knows Russian through the system's language
packs, and needs no model of ours. Linux and Windows would go through sherpa-onnx — Parakeet as ONNX with Silero in
front — which is its own session.
