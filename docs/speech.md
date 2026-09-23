# Dictation — plan

*Not built yet. Tracked in [todo.md](todo.md).*

Goal: press a key in the agent panel or in the ⌘K bar, say the sentence, and read it back as text before it is sent.
Nothing leaves the machine, Russian works as well as English, and the browser does not become slower while it listens.

ACP has no audio channel and is not going to grow one: the agent is a process at the other end of a JSON-RPC pipe, and
what it takes is a prompt. So recognition is six's problem, entirely, and the agent never learns it was spoken to.

## What decides the engine

Three constraints, in the order they eliminate things.

**Russian.** Artem dictates in Russian, with English terms in the middle of it. Apple's new `SpeechTranscriber`
(macOS 26) covers Cantonese, Chinese, English, French, German, Italian, Japanese, Korean, Portuguese and Spanish, and
Russian is not on that list. Apple's Russian is only `DictationTranscriber` — the same engine behind the old
`SFSpeechRecognizer`, which is a decade old and sounds it. So the platform cannot be the whole answer here, the way
`Translation` could be for pages.

**The machine.** Eight gigabytes, usually already in macOS's `.warning` band, with WebKit and the E5 embedder on the
GPU. That is what rules against reaching for MLX first, even though it is the house ML stack: MLX runs on the GPU,
next to page rendering and next to the embedder. The **Neural Engine** is idle the rest of the time, and a Core ML
model is the one way to use a part of this Mac nothing else is using.

**One dependency, not three.** Recognition needs a voice detector in front of it, or the model spends the pauses
inventing words and the Neural Engine runs through silence.

## The stack

[**FluidAudio**](https://github.com/FluidInference/FluidAudio) — Apache-2.0, ~2.8k★, active, Swift 6 tools — answers
all three at once. It carries **Parakeet TDT v3** (0.6B, 25 languages, a sliding-window streaming manager) and
**Silero VAD** (streaming, speech start/end events), both as Core ML on the Neural Engine, in one package with no
second runtime.

Beside it, **Apple `SpeechAnalyzer`** stays as the engine that downloads nothing: for the languages
`SpeechTranscriber.supportedLocales` names, the models are the system's, shared with every other app, and the work
happens in a system process rather than in ours. It is the default for those languages and the fallback everywhere
while Parakeet has not been downloaded.

### Why Silero, and not the other three

| | |
|---|---|
| Apple `SpeechDetector` | Cannot run alone. It is a module of a `SpeechAnalyzer` that must also hold a transcriber, so it gates Apple's engine and is no use in front of Parakeet. |
| WebRTC VAD | Cheapest, and noticeably worse on breathing, keyboard noise and a fan. |
| TEN VAD | Better numbers than Silero on paper, no maintained Swift or Core ML port. |
| **Silero v6** | ~309K parameters, ~2 MB, a streaming state, a probability per frame — and already in the package the recogniser comes from. |

### The MLX path, later

[`mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift) (MIT, ~780★) has the same Parakeet v3, plus
Whisper-large-v3-turbo, plus Silero, all on MLX — and on the same `mlx-swift` that `MLXEmbedders` already puts in the
graph. That is the tidier house answer and it brings Whisper as a one-setting fallback if Parakeet's Russian
disappoints. It waits for two things: a measurement that the GPU can take dictation next to rendering and the
embedder, and mlx-swift versions that line up with the pinned `mlx-swift-lm`. The protocol below is what makes it a
new implementation rather than a rewrite.

## What to verify before writing any of it

1. **That Parakeet v3 really has Russian.** NVIDIA's model card lists `ru` and `uk` among its 25 languages;
   FluidAudio's own README language list did not name it. One Russian WAV and one mixed RU/EN WAV through their CLI
   settles it. If Russian is not there, this plan stops and the choice is WhisperKit or the MLX path.
2. **That the dependency moves nothing.** FluidAudio goes into the **app's** graph only, in Xcode, and
   `six.xcodeproj/…/Package.resolved` is read afterwards: mlx-swift, swift-transformers, swift-huggingface, GRDB and
   sqlite-data must all stay where they are. Nothing goes into the root `Package.swift` or `SixCore`, so the Linux,
   Windows and root resolved files are untouched — see the dependency-graph section of [CLAUDE.md](../CLAUDE.md).
3. **Where the weights land.** FluidAudio downloads from Hugging Face on first use and caches under `~/.cache`. It has
   to be pointed at `AppSupport`'s `Models/` instead, beside E5 — the same arrangement `MLXEmbedder` makes with
   `HubCache(cacheDirectory:)`.

## The shape of it

A new `six/Speech/`, Apple-only, outside `SixCore` for the same reason `AppleTranslator` is.

- **`SpeechTranscribing`** — the seam, shaped like `PageTranslating`: `name`, `isAvailable(for:)`,
  `start(locale:)` handing back an `AsyncThrowingStream` of `.volatile(String)` / `.final(String)` / `.silenceTimeout`,
  `stop()`, `unload()`. Everything above it is engine-blind, which is what makes the MLX path a later afternoon
  rather than a rewrite.
- **`MicrophoneCapture`** — `AVAudioEngine`'s input tap through `AVAudioConverter` to 16 kHz mono Float32. The engine
  runs only while dictation is on: at rest this costs nothing, and the microphone light is off.
- **`SileroGate`** — FluidAudio's VAD, streaming. Opens and closes segments with about 200 ms of padding on each side,
  and ends the utterance after a silence the setting names (default two seconds).
- **`ParakeetTranscriber`** — volatile text from the sliding-window manager while a segment is open, a final pass when
  it closes. The model loads on the first press of the microphone and `unload()`s after five idle minutes and on
  `DispatchSource.makeMemoryPressureSource(.warning)` — which on this Mac is the ordinary state, not the emergency.
- **`AppleSpeechTranscriber`** — `SpeechAnalyzer` with `SpeechTranscriber` (`.volatileResults`) and its own
  `SpeechDetector`; assets through `AssetInventory`.
- **`DictationStore`** — `@MainActor @Observable`: the state (`idle` / `loadingModel(progress)` / `listening` /
  `failed`), the volatile text, and the engine choice (`auto` / `parakeet` / `apple`). Under `auto`: Parakeet if it is
  on disk, else Apple where Apple has the language, else a sentence saying a download is needed. **The 600 MB is never
  fetched without being asked for** — the rule `MLXEmbedder` already follows about a download nobody asked for.
- **`DictationButton`** — the microphone with a level indicator, in the agent panel's composer and in the ⌘K bar.
  Press to start, press again or fall silent to stop. Volatile text sits in grey, final text is appended to the field,
  and **nothing is ever sent by itself**: an agent that goes off and does something from a misheard sentence is worse
  than typing.

## What it touches

`six/Views/AgentPanel.swift` (the composer) and `six/Views/AssistantBar.swift` — the latter is on iOS too, so the
phone gets dictation for the price of the button. A row in the `KeyBindings` table with a case in `KeySelfTest`;
`speech.engine`, `speech.locale` and `speech.silenceSeconds` in `SettingsStore`, with a Dictation section in
`SettingsPageView` that owns the download, the size and the delete.

Two plist strings: `NSMicrophoneUsageDescription` has to be **reworded** — it currently says "A site you are
visiting…", which stops being true the moment six itself listens — and `NSSpeechRecognitionUsageDescription` has to be
added, both in Russian and English through `InfoPlist.xcstrings`. The sandbox is off, so no entitlement is involved;
if Release ever turns the hardened runtime on, `com.apple.security.device.audio-input` goes with it. On iOS the
`AVAudioSession` moves to `.record` for the length of the dictation and is handed back after.

Everything the run says goes through `Log` — engine, load time, real-time factor, segment count. Never the audio, and
never the text.

## How it gets checked

- `SIX_SPEECH_SELFTEST=<dir of wavs>` runs recorded phrases through every engine and prints the text, the real-time
  factor and the peak RSS. Recorded by hand, because the harness cannot speak: one Russian, one English, and one
  Russian sentence full of terms — "закомить в main, SwiftUI WebView" is the case that decides the default.
- A minute of dictation with pauses, watched in Activity Monitor: the work should be on the Neural Engine with the GPU
  quiet, memory should come back after `unload()`, and nothing should still be loaded five minutes later.
- Live in the dev build: dictate into the agent panel and into ⌘K, confirm that silence ends it, that the text lands
  in the field **and is not sent**, that the key survives `SIX_KEY_SELFTEST`, and that the permission prompt shows the
  new wording.

## The other fronts

Android has neither the agent panel nor the assistant yet, so there is nothing to attach a microphone to; when there
is, `SpeechRecognizer.createOnDeviceSpeechRecognizer` (API 31+) is offline, knows Russian through the system's
language packs, and needs no model of ours. Linux and Windows would go through sherpa-onnx — Parakeet as ONNX with
Silero in front — which is its own session.
