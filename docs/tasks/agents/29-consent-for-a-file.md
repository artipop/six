# 29. A file leaves the disk only when a person said so, this time

Close two ways `upload_file` can hand a file to a site with nobody asked.

## What is there

`upload_file` gives a file from the disk to a page's file input in place of the system's panel
([agent-actions.md](../../agent-actions.md#dialogs-and-files-the-delegates-door)). The tool itself asks nothing: it
checks that the path is absolute and the file exists (`BrowserToolCatalog.files`) and hands it over.

Consent is the agent's, not Savoia's. An ACP agent sends `session/request_permission` before it calls a tool;
Savoia draws that as a card with the call's arguments — `path` and `ref` — and the person answers
([agents.md](../../agents.md#permission-prompts)). That much works, and the guide describes it.

## The two holes — read from the code, neither was tried

1. **"Always" is remembered for the tool, not for the file.** `AgentSessionStore.requestPermission` looks a
   standing answer up by the call's title. For an agent's own tools the title carries the argument — a `Bash`
   command — so the answer is that narrow. For Savoia's tools it is the bare name, `mcp__savoia__upload_file`.
   Answer "always" once, and from then on any file goes to any site with no card.
2. **Outside Savoia there is no card at all.** A client that reaches `Savoia --mcp` from elsewhere — Claude Code in
   a terminal, any MCP client — asks or does not ask by its own rules. Savoia hands the file over in silence.

The same is true of `click`, `handle_dialog` and the other acting tools. `upload_file` is the one that carries
data off the disk, which is why it is first; say at the end which of the others deserve the same and why.

**Reproduce each before fixing it**: an agent on the ⌘E line answered "always" for one upload and then asked to
upload a second, different file; and a bare MCP client calling `upload_file` through `Savoia --mcp`. In a throwaway
home, with a throwaway file, against the wpt stand or a local page.

## What to build

1. **No standing answer for `upload_file`.** Either the "always" options are not offered for it, or a stored one is
   not honoured — whichever leaves the card honest about what its buttons do. A rule in one place, keyed by a
   property of the tool rather than its name spelled in `AgentSessionStore`, so the next tool of this kind gets it
   by declaration.
2. **Savoia's own question, for a call that came with none.** `SitePermissions` already has the shape: a question
   in the tab's bar that is about one call and is never remembered (`Ask.pageToolCall`,
   `confirmPageToolCall`, built for WebMCP). The same for a file: which file, to which site, allow or not. Asked when
   the call arrives over `Savoia --mcp` from outside an agent session of Savoia's; not asked a second time when
   Savoia's own card has just been answered for the same call — one question per upload, never two.

   Decide with Artem before building: whether a file's name is enough in the bar or the whole path is needed, and
   whether a call from outside should be refusable for good ("never let outside clients upload").

The bar's sentence goes through the String Catalog in English and Russian and names the thing, not the browser
(AGENTS.md: the interface never narrates what Savoia does). The tool's description stays English: it is a prompt.

## Done when

- Both reproductions fail to upload without a fresh answer.
- The guide's paragraph on files ([guide/agents.md](../../guide/agents.md), both languages) says what is true:
  asked every time, and from an outside client asked in the tab.
- [agent-actions.md](../../agent-actions.md) and [mcp.md](../../mcp.md) say who asks, and when.
