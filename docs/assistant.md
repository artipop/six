# The assistant: three surfaces, one catalog

Six's assistant is not a chat. It is a **catalog of verbs** (`AssistantAction`) offered at the three
places a person is already pointing at something: a **selection** on the page, a **caret** in a
field, and the **⌘K line** at the bottom of the strip. A use case is a row in that catalog — a title,
what it says to the model, and where the answer lands — so adding one adds no interface at all.

The one chat left in six is the ACP agent panel behind ⌘⇧A ([agents.md](agents.md)), where a
transcript is the work being done rather than a way to ask a question.

## Why not a chat

The context of a browser question is on the screen: this paragraph, this comment box, this page. A
transcript adds six older contexts to a question that already has the right one, and it turns every
answer into a message that has to be read rather than a result that can be used. So `AssistantStore`
keeps exactly one `Answer` — replaced by the next one, dismissed with Escape, applied with Return
where it can be applied at all.

## What the page tells six

`PageFocus` is what the person is pointing at inside a page, and it is the fact the old assistant
never had. It is **pushed, not polled**: `PageFocusScript` installs a watcher in six's own content
world (`PageScripts.swift`), which posts on `selectionchange`, on focus moving in or out of a field,
and on scroll — debounced, deduplicated, main frame only. `PageFocusStore` receives it per window,
`BrowserTab` clears it on navigation, and `BrowserState` forgets it when the window closes.

| the focus says | where it comes from |
|---|---|
| `kind` — `selection`, `caret` or `none` | `window.getSelection()`, or a field's own `selectionStart`/`selectionEnd`, which the former never reports |
| `text`, `field`, `start`, `end` | the selected text, and the whole field when the caret is in one |
| `isEditable` | an `<input>`, a `<textarea>` or a `contenteditable` — the only places six may write |
| `label` | `aria-label`, `<label>`, `placeholder`, `title`: "Comment" and "Search" want different drafts |
| `rect` | viewport coordinates, which is exactly the box the overlay hangs in |

**Password fields are dropped in the page**, before anything is sent: `type="password"`, or an
autocomplete/name/id that looks like a secret or a card number, and the watcher returns `none`. The
cheapest place to drop a secret is before it leaves the frame it was typed in. An `<input>` of an
exotic type is ignored for the same reason — a colour picker has no text worth reading.

The world matters as much as the rule: the script runs in `WKContentWorld.six`, so a page cannot
redefine `getSelection` or an input's value getter and feed the model text the person never saw.
This is the arrangement the readable-page extractor and the highlighter already use.

## The catalog

`AssistantAction` (`six/Assistant/AssistantAction.swift`) is one list, read by all three surfaces:

| requirement | what is offered |
|---|---|
| `selection` | Explain, Summarize, What is this?, Check this claim |
| `editableSelection` | Fix Spelling and Grammar, Rewrite, Make It Shorter, Translate to English |
| `caret` | Continue Writing, Draft a Reply, Polish What Is Written |
| `page` | Summarize This Page |

Each row carries a `landing`: `show` (read it and move on), `replaceSelection`, `replaceField`, or
`insert`. A landing that writes is downgraded to `show` when the focus is not editable, so the same
row is safe to offer over an article.

`prompt` stays English while `title` is translated — it is a prompt and not an interface
([localization.md](localization.md)). The single set of instructions in `AssistantStore` says the
answer is in the person's language, and that a replacement comes back as the replacement and nothing
else: no quotes around it, no note about what changed.

## Writing back

Nothing is written to a page without a second gesture — Return on the line, or the **Insert** /
**Replace** button under the answer. The text goes in through `document.execCommand('insertText')`
(`PageFocusScript.insert`), which is deliberate on two counts: it fires the `input` events a
framework-driven field listens for, and it lands in the page's own undo stack, so ⌘Z takes it back.
Where the command is refused, the fallback sets the value through the native prototype setter and
dispatches `input` and `change` itself — what a React `onChange` is actually listening for.

## The surfaces

**The bar at a selection** (`PageFocusBar`) is a `HostedOverlay` — SwiftUI hosted in AppKit beside
the `WKWebView`, because SwiftUI drawn over a web view never sees the mouse, the same reason a
column's close badge is one. It is positioned from `PageFocus.rect`: above the selection where there
is room, below it where there is not, never off the sides. It carries the primary verbs as icons and
a `…` menu with the rest and **Ask…**, which puts the caret in the ⌘K line with the selection
already the subject (`AssistantStore.focusLine()`).

It is offered for a selection of more than one character, and for a caret only in a `<textarea>` or
a rich editor: a bar over every search box on the web is noise, and a single-line field still has
the same verbs on the ⌘K line.

**The ⌘K line** (`AssistantBar`) is the same catalog for the keyboard: while it is focused, the
verbs that apply appear as chips above it, and the placeholder says what the question will be about.
Return sends the question; Return with nothing typed applies the answer that is already there.
Escape dismisses. The model menu, the bookmark scope and the provider settings are unchanged.

**The caret** has no surface of its own on purpose. Nothing is sent while a person types — the field
is read only when a verb is pressed or ⌘K is asked for, which is the difference between an assistant
and a keylogger.

## Models and agents

Unchanged, and still the reason everything runs through Foundation Models' `LanguageModelSession`:

| | |
|---|---|
| On-Device | `SystemLanguageModel.default` |
| Private Cloud Compute | `PrivateCloudComputeLanguageModel` |
| Claude Sonnet 5 / Opus 5 | `ClaudeLanguageModel` from [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) |
| OpenAI-compatible | `ChatCompletionsLanguageModel` from Apple's [foundation-models-utilities](https://github.com/apple/foundation-models-utilities) |

The ⌘K line can still be answered by an ACP agent (the menu's second section), and `research: …`
still starts a deep-research run ([deep-research.md](deep-research.md)). Both stream into the same
one-answer strip; an agent's permission request appears inside it, as it does in the panel. Verbs
are not offered while an agent is the chosen model: a verb is a prompt to a language model, and an
agent has a session, a working directory and a transcript of its own.

## Tools

The language models get the browser tools: `BrowserToolCatalog` (`six/Tools/`) describes each tool
once, `BrowserModelTool` wraps it as a Foundation Models `Tool`, and the same catalog is what MCP
serves to agents ([mcp.md](mcp.md)). Bookmarks are searchable from here too; the model menu's
**Bookmarks** picker sets whether they see this profile or all.

## OpenAI-compatible

**OpenAI-compatible** is one menu entry rather than a list of models, because what it points at is a
setting: `six://settings` ▸ Assistant holds an endpoint, a model name and a key. Anything speaking
the OpenAI `/chat/completions` wire format answers there — OpenAI itself, a gateway, or llama.cpp
and Ollama on this machine, which want no key at all, so an empty one sends no `Authorization`
header rather than an empty one. `OPENAI_BASE_URL`, `OPENAI_MODEL` and `OPENAI_API_KEY` name any of
the three for a single run.

The provider is Apple's own `ChatCompletionsLanguageModel`, vendored into
`six/Vendor/FoundationModelsUtilities/` for the reason the Claude bridge is (see
[build.md](build.md)). `AssistantSettings` persists the model choice in `UserDefaults`; the
Anthropic key is read from the settings field or `ANTHROPIC_API_KEY` and stored in `UserDefaults` —
**development only**. `FoundationModelsCompatibility` probes the executor ABI at launch and disables
both remote options with an explanation if the runtime and the SDK diverge.

## Watching it work

`SIX_UI_DEBUG=1` prints a line whenever the focus changes — the kind, whether it is editable, where
it is and what it says. That is the only way to see this from a terminal: the bar is AppKit drawn
over a web view, `screencapture` writes black on this machine, and `take_screenshot` over MCP
renders the *page* and not the window (CLAUDE.md).
