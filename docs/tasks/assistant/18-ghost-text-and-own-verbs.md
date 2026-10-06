# 18. The assistant: an answer in place, and a verb of one's own

Built: the catalog of verbs, the bar at a selection, the caret in a field, and the one-answer ⌘E
line ([assistant.md](../../assistant.md)). What was deliberately left for later, in the order it is
missed:

1. **Ghost text in the field itself.** A rewrite arrives in the strip at the bottom of the window
   and goes into the page on Return; the thing to build is the answer shown *in place* — grey text
   after the caret, Tab to take it — which needs an overlay positioned on a caret rectangle that
   moves with every keystroke, inside a page whose scrolling Savoia does not own. The strip is the
   honest version until that is measured.
2. **A verb of your own.** The catalog is a Swift array; the row that would make it a setting — a
   title, a prompt, where it applies — is the smallest useful next feature, and the reason the type
   is shaped the way it is.
3. **Every model from the welcome.** Any ACP agent can be added by path and arguments now (Configuration ▸
   Assistant ▸ Agents, `ModelChoice.customAgent`), but the welcome's provider step still knows only its own four
   doors: a custom agent and Private Cloud Compute are not offered there.

## Order

The verb of one's own first: it is a settings row over a type that was shaped for it, and needs nothing measured.
Ghost text second, and only after measuring that an overlay can follow a caret in a page whose scrolling Savoia does
not own — `PageFocusStore` no longer watches the page ([page-scripts.md](../../page-scripts.md)), so a caret that
moves with every keystroke means either reading it on each key or a watcher that exists only while the line is up.
The welcome's missing doors are in [13-small-things.md](../browser/13-small-things.md).
