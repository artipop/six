# The assistant: one line, one catalog

Six's assistant is not a chat. It is a **catalog of verbs** (`AssistantAction`) behind one line,
**⌘E**, which stands where the person is already pointing: under a **selection** or beside a
**caret** in a field when the page has one, and at the bottom of the strip when it does not. A use
case is a row in that catalog — a title, what it says to the model, and where the answer lands — so
adding one adds no interface at all.

The one chat left in six is the ACP agent panel (currently hidden from the UI) ([agents.md](agents.md)), where a
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

`AssistantAction` (`six/Assistant/AssistantAction.swift`) is one list, read by the line wherever it stands:

| requirement | what is offered |
|---|---|
| `selection` | Explain, What is this? — in text and in a field alike |
| `readingSelection` | Summarize, Check this claim — only in text being read, not in your own draft |
| `editableSelection` | Fix Spelling and Grammar, Rewrite, Make It Shorter, Translate to English — listed first in a field |
| `caret` | Continue Writing, Draft a Reply, Polish What Is Written |
| `page` | Summarize This Page — only with nothing pointed at |

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

## The line

**Nothing comes up by itself.** There used to be a bar over every selection, with the primary verbs
named, and a bar beside every `<textarea>` with Continue Writing and Draft a Reply. Both went. A
bar at a caret is an assistant that does not wait to be asked — clicking into a field is how
writing starts — and a bar at a selection sits exactly where the page's own selection toolbar
(Notion, Medium, Docs) and the system's Look Up already are. What they offered is behind `/`.

**⌘E** (`AssistantStore.toggleLine(in:)`) decides where the line goes from the selected window's
`PageFocus`: a live web page with a caret or a selection gets the line hung on it
(`LinePlace.page`), anything else gets it at the bottom (`LinePlace.bottom`). Pressed again, or Esc,
puts it away — from wherever it is, without deciding the place a second time, because the page has
usually redrawn what it reports by then and the second press once came out as "open at the bottom".
⌘E rather than ⌘K because it is Dia's, and ⌘K is every web app's command palette. The menu item
calls the store directly rather than a `@FocusedValue`: a focused value exists only while something
in the scene has focus, so after Esc the item was greyed out, and a disabled item eats its key.

**Two views, one state.** `AssistantBar` is the line; it is mounted at the bottom by `ContentView`
and, while `line == .page(id)`, inside that column by `AnchoredAssistantLine`. The store holds
where the line is (`line`), and each view shows itself only for its own place. The anchored one is a
`HostedOverlay` — SwiftUI drawn over a `WKWebView` never sees the mouse, and the answer has buttons —
placed from `PageFocus.rect`: below the field or selection when an answer's height fits under it,
above otherwise, never off the sides, 420–640 pt wide. Its frame follows the content's measured
height (`onGeometryChange`), because a hosting view that sizes itself feeds constraints back into the
window, and a fixed tall frame would leave a clear box over the page that swallows clicks. Below, the
answer opens under the line; above, over it.

**The subject is snapshotted.** A selection in page text is gone the moment the web view hands the
keyboard to the line — measured at the bottom as well as beside the text, so it was never kept — so
the store keeps the `PageFocus` it saw when the line was asked for, and `subject(in:)` answers with
the live focus while the page still reports one (a caret survives in its field and follows
scrolling) and with the snapshot once it does not. The question, the verbs offered and the line's
position all read it. Put away by a key, a line that stood on a page gives the keyboard back to that
page's web view, so Esc over a comment box goes back to writing.

**The verbs are up already, beside a page.** The anchored line carries a `ChipRow` above (or below)
its field with every verb that applies, named, one of them filled in the profile's colour: ←/→ walk
it, Return runs the one they are on, a click runs any of them. The field under it is focused the
whole time, so the first character typed is the person asking something of their own — the row goes
and the question is in the field already. The arrows and Return reach the row through an
`.onKeyPress` on the field that only answers while the field is empty and the row is up; typed into,
the field keeps its own arrows.

This is the second shape. The first put the row *instead* of the field and moved focus between them,
and the focus never arrived: a `@FocusState` set while the view that had it is being removed is a
request that goes nowhere inside a nested hosting view, so the letters after the first went to the
address bar. Two `@FocusState`s, then one `@FocusState<Half?>`, then a retry loop — none of them
made the hand-off land. A field that never loses the keyboard has nothing to hand over.

**A model that could not answer is said so before it is asked.** `AssistantSettings.trouble` reads
the chosen model's own answer — `SystemLanguageModel.availability`, an empty API key, an endpoint
that is not a URL — and the line puts that sentence where the verbs would be, with **Set Up…** to
`six://configuration/assistant` for the half a person can put right and nothing but the sentence for the half
they cannot (a model still downloading, a Mac that is not eligible, the SDK/OS mismatch). Return
over that row opens the same page rather than running a verb that is going to fail. `makeSession`
throws the same sentences, as `AssistantError.notConfigured` or `.unavailable`, so a failure that
arrives mid-answer reads like the notice and carries the same button — where it used to read
`unavailable(FoundationModels.SystemLanguageModel.Availability.UnavailableReason.modelNotReady)`.

**At the bottom there are no chips**, because with nothing pointed at there is one verb and the line
is for asking. `/` still works everywhere: it lists what applies and narrows by title or id, so
`/sum` works on any layout, and Return runs the first one left. Return with nothing typed applies the
answer that is already there.

**Away means out of the key-view loop.** The bottom line stays mounted while it is away and was
only transparent, so Tab on a start page landed in it and showed it. Its controls are disabled while
it is away, and a summons focuses on the next pass of the main queue, once there is something enabled
to take the caret.

`SIX_KEY_SELFTEST=assistant` checks all of it without a screenshot: the line summoned at the bottom
of a start page, the ⌘E menu item as a switch, `/sum` ⏎ starting `summarize-page`, Tab walking past
the line, then a `<textarea>` — the line hung under it (the hosting view's frame is printed), `/con`
⏎ starting `continue`, Esc handing the keyboard back to the page — and a selection that the line
still knows after the page has dropped it.

**The caret** is read only when ⌘E is pressed or a verb runs. Nothing is sent while a person types,
which is the difference between an assistant and a keylogger.

## Switching all of it off

`Configuration ▸ Assistant ▸ Use Language Models and Agents` (`ConfigurationStore.isAIEnabled`) is one switch
over everything in this document, and over the agent panel, deep research and six's own MCP server.
Off is not a greyed-out button:

- `AssistantBar` is not in the view hierarchy, so `focusAssistant` is nil and ⌘E's menu item is
  disabled with it; the agent inspector is not presented either;
- `PageFocusStore.isEnabled` goes false, which pulls the watcher **out of the pages**: the message
  handler is removed at once and the user script is dropped from every window's controller, so a
  page loaded after that has nothing of six's watching what is selected in it;
- `MCPHost.stop()` closes the socket and unlinks it, so `six --mcp` fails to connect rather than
  hanging on a door nobody answers.

What is deliberately outside the switch: the on-device bookmark index and page translation. Neither
is a model talking to a person — one is how search finds a page you read in another language, the
other is what every browser has had for a decade — and taking them away with the assistant would
remove search and the translate button for a reason nobody asked for.

The switch is asked about once, on the first launch, in a window on the rail: `six://welcome`
(`WelcomePage`, `BuiltInPage.welcome`). A page rather than a sheet, for the reason written on
`BuiltInPage` — and answering it closes the window, which is the first thing a new person does with
a column. `ConfigurationStore.hasAnsweredWelcome` is what keeps it to once; until it is answered the
assistant is on, because six is a browser built around these models and a switch nobody has seen
yet is not consent to have taken them away either.

## Models and agents

Unchanged, and still the reason everything runs through Foundation Models' `LanguageModelSession`:

| | |
|---|---|
| On-Device | `SystemLanguageModel.default` |
| Private Cloud Compute | `PrivateCloudComputeLanguageModel` |
| Claude Sonnet 5 / Opus 5 | `ClaudeLanguageModel` from [ClaudeForFoundationModels](https://github.com/anthropics/ClaudeForFoundationModels) |
| OpenAI-compatible | `ChatCompletionsLanguageModel` from Apple's [foundation-models-utilities](https://github.com/apple/foundation-models-utilities) |

The ⌘E line can still be answered by an ACP agent (the menu's second section), and `research: …`
still starts a deep-research run ([deep-research.md](deep-research.md)). Both stream into the same
one-answer strip; an agent's permission request appears inside it, as it does in the panel.

**A verb goes wherever the line goes, the agent included**, and that took three tries to get right.
Verbs were first hidden whenever the line was set to an agent, on the argument that a verb is a
prompt to a language model and an agent is a process with a working directory; what that produced
on a Mac with Claude Code chosen was a capsule containing one `…`, hovering over a selected
paragraph — a bar that had lost its buttons. The second try fell back to the on-device model, which
on a Mac whose Apple Intelligence assets are still downloading answers `modelNotReady` — a fallback
onto a floor that is not there, so every verb failed. What is left has no surprise in it: one model
answers everything the assistant is asked, and it is the one that was chosen. The agent is given the
whole composed prompt rather than a link to the page, because a verb is about the text in front of
the person and the agent should not have to go and find it.

## Tools

The language models get the browser tools: `BrowserToolCatalog` (`six/Tools/`) describes each tool
once, `BrowserModelTool` wraps it as a Foundation Models `Tool`, and the same catalog is what MCP
serves to agents ([mcp.md](mcp.md)). Bookmarks are searchable from here too; the model menu's
**Bookmarks** picker sets whether they see this profile or all.

## OpenAI-compatible

**OpenAI-compatible** is one menu entry rather than a list of models, because what it points at is a
setting: `six://configuration` ▸ Assistant holds an endpoint, a model name and a key. Anything speaking
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
it is and what it says — and a second line saying where the bar was placed for it, which is how the
bar's coordinates were checked against the page's own (`getBoundingClientRect` against the view's
box: 1412×737 reported by the page, 1412×738 measured by the overlay).

`SIX_VERB_SELFTEST=explain` presses a verb. It waits for something to be selected — over MCP, from
outside — then runs that catalog entry on it and logs the answer, the landing and whether it can be
applied. Nothing on this machine can click the bar, so this is the only way to see a verb run end to
end; `fix` on «это текст с ашипками» coming back as «это текст с ошибками», `replaceSelection`,
applicable, is what it looks like when it works. That is the only way to see this from a terminal: the bar is AppKit drawn
over a web view, `screencapture` writes black on this machine, and `take_screenshot` over MCP
renders the *page* and not the window (CLAUDE.md).
