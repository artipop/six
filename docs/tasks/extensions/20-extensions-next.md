# 20. Extensions: after the measurement

Do [12-one-sitting.md](../measure/12-one-sitting.md) first — its three extension measurements decide what here is
still true.

Hosting is built ([extensions.md](../../extensions.md)): install from a folder or an archive, a controller per profile,
actions in the top bar, permission prompts, and a compatibility verdict shown before anything runs. The one gap
behind it — `WKWebExtensionTab.webView(for:)` needed the live `WKWebView` and `WebPage` hands its own out to
nobody — now answers on macOS, through `WebViewResponder`'s existing per-tab lookup (a view-tree walk for
`is WKWebView`, matched by frame containment — not reflection into `WebPage`'s own storage, which was tried,
works, and stays unused). What that closes — messaging between a content script and its extension,
`scripting.executeScript`/`insertCSS`, uBlock Origin Lite's per-tab logic — is confirmed at the API level
(`webView(for:)` now answers the right tab correctly) but **not yet re-measured end to end**: a fresh MV3 test
extension hit a content-script-injection snag unrelated to this method in the same session, so the "what works"
table in [extensions.md](../../extensions.md) still describes the state from before this fix. iOS has no view-tree walk
yet and still answers `nil`.

The move that would close it without a workaround is upstream: nothing on bugs.webkit.org mentions `WKWebExtension`
and `WebPage` together, so this wants a bug (and a Feedback) asking for the backing view — or for a way to associate
a `WebPage` with a tab — with the measurements from [extensions.md](../../extensions.md) as the case. `WebPage.isInspectable`
is the precedent: something that lives on `WKWebView`, lifted into the new API.

Smaller things that follow once the boundary moves (or that are worth doing anyway): a workspace per extension
window rather than one window per profile strip.

**Extension pages inside Savoia's own interface.** An extension's options page, its dashboard and the pages it opens
with `tabs.create` open today in a plain `NSWindow` of their own (`ExtensionStore.openExtensionPage`), because a
column is a `WebPage` and WebKit will not load an extension's page as a main frame into one
([extensions.md](../../extensions.md#extension-pages-get-a-window-not-a-column)). Try to fit them into the row anyway.
The options, cheapest first: a panel Savoia places and sizes over the focused column instead of a free-floating window
(still a `WKWebView` from `context.webViewConfiguration`); a column kind that hosts that `WKWebView` through
`NSViewRepresentable` — an exception to the `WebPage`-only rule, to be weighed against everything such a column would
not have (find, translation, highlights, DevTools capture, discarding); or, if `WebPage.Configuration` ever takes a
configuration or a `requiredWebExtensionBaseURL` ([api-watch.md](../../api-watch.md)), ordinary columns with nothing
special about them. The new-tab override is blocked on the same thing.

`commands` bound to real keys is no longer on this list — see [extensions.md](../../extensions.md#commands-an-extensions-own-shortcuts).

## Done when

The WebKit bug and the Feedback are filed and linked from [extensions.md](../../extensions.md), and extension pages
either sit in Savoia's interface by the cheapest option that works or the reason they cannot is written down.
