# Welcome

On the very first launch Savoia opens a **Welcome** tab and asks one question: whether to use language models.

## Use language models?

Models power the ⌘E line, actions over selected text, the agent panel, deep research and the MCP server.

| answer | what happens |
|---|---|
| **Yes, use them** | the on-device model keeps everything on this Mac; others need your own key. A second step follows |
| **No, don't use them** | nothing is loaded or added to pages. Bookmark search and translation still work. The tab closes |

## Which model should answer?

Four cards; the chosen one is outlined in the profile's colour:

| card | what it is |
|---|---|
| **On-Device** | Apple's model. Nothing leaves this Mac |
| **Claude Code** | your Claude subscription, through the claude CLI |
| **Codex** | your ChatGPT subscription, through the codex CLI |
| **API Key** | Anthropic or any OpenAI-compatible server; pick the specific one in **Model**, then enter the address and key below |

Under Claude Code and Codex you see whether the tool is installed, and can install it there.
If the **API Key** card is unavailable, it says "Remote models unavailable: SDK/OS Foundation Models mismatch".

**Back** returns to the question; **Done** saves the choice and closes the tab. The chosen model answers both ⌘E and the agent panel.

If you quit Savoia before **Done**, the question is asked again on the next launch.

You can change the answer at any time: **Configuration ▸ Assistant**. More in [Configuration](configuration.md), [Assistant](assistant.md) and [Agents](agents.md).
