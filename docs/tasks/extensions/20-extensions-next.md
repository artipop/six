# 20. Extensions: after the measurement

Do [12-one-sitting.md](../measure/12-one-sitting.md) first — its three extension measurements decide what here is
still true.

Hosting is built ([extensions.md](../../extensions.md)): install from a folder or an archive, a controller per profile,
actions in the top bar, permission prompts, and a compatibility verdict shown before anything runs.

Two things this file used to ask for are done by a tab being a `WKWebView` of Savoia's own
([architecture.md](../../architecture.md#from-webpage-to-wkwebview)):

- **`WKWebExtensionTab.webView(for:)` answers with the tab's own view**, whether or not a pane has shown it — no
  search of the window. What that closes — messaging between a content script and its extension,
  `scripting.executeScript`/`insertCSS`, uBlock Origin Lite's per-tab logic — is still **not measured end to end**;
  that is [12](../measure/12-one-sitting.md), and the "what works" table in [extensions.md](../../extensions.md)
  waits for it. The bug asking WebKit for `WebPage`'s backing view is no longer Savoia's to file.
- **An extension's own pages are tabs** — options, a dashboard, a page opened with `tabs.create`, the new-tab
  override — built on `WKWebExtensionContext.webViewConfiguration`
  ([extensions.md](../../extensions.md#extension-pages-are-tabs)). Seen with a throwaway extension for `tabs.create`;
  the options page and the new-tab override have not been opened by hand.

What is left: a workspace per extension window rather than one window per profile strip.

`commands` bound to real keys is no longer on this list — see [extensions.md](../../extensions.md#commands-an-extensions-own-shortcuts).

## Done when

The measurements of [12](../measure/12-one-sitting.md) are in [extensions.md](../../extensions.md), the options page and
the new-tab override have been opened by hand, and the workspace question is built or dropped with a reason.
