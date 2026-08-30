`ChatCompletionsLanguageModel.swift` from https://github.com/apple/foundation-models-utilities (main @ 2aa1293,
Apache-2.0) — Apple's own `LanguageModel` over the OpenAI `/chat/completions` wire format, and so the OpenAI-side
counterpart to `ClaudeForFoundationModels` next door. It is the whole provider: one file, no dependencies beyond
Foundation and FoundationModels.

Vendored rather than added as a SwiftPM dependency for the reason the Claude bridge is: it touches the Foundation
Models *executor* ABI, and a package target ignores the project's `SDKROOT` override, so it has to compile against the
same Command Line Tools SDK the app does. See docs/build.md. Replace with the SPM package once Xcode's bundled SDK
matches the OS beta.

Local edits: the access level was dropped from every `import` (`public import Foundation`, `private import CoreImage`
and the rest). Upstream builds in Swift 6 language mode where `AccessLevelOnImport` is on; the app target is Swift 5,
where the modifier is a hard error. Nothing else is changed — the file is otherwise byte-identical to upstream, and
should stay that way so the next sync is a copy.

Known gaps, none of which six hits today, all of them upstream's to close:

- `GenerationSchema` is encoded straight into `tools[].function.parameters` and `response_format`, framework extension
  keys and all (`title`, `x-order`; `additionalProperties: false` and `required` it already gets right). Servers that
  validate strictly may object. six sends tools without `strict`, and asks for no structured output at all, so
  nothing has objected yet.
- `ContextOptions.reasoningLevel` is not mapped to `reasoning_effort`. six never sets it.
- Errors surface as `RequestError.httpError`/`APIError` rather than the framework's `LanguageModelError` cases, so a
  rate limit and a bad key read the same to a caller matching on the framework's errors.
