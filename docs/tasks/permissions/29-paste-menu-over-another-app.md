# 29. The Paste menu comes up over another app

A page that reads the clipboard — `navigator.clipboard.read()`, `readText()`, `execCommand('paste')` — when what is
on it was not put there by the same origin, is answered by WebKit with a one-item menu, **Paste**, at the element.
It is an `NSMenu` popped up modally (`WebViewImpl::requestDOMPasteAccess`, `WKDOMPasteMenuDelegate`), so it shows
above every app, and Savoia's main thread waits in it until somebody chooses or dismisses.

For a person clicking in the front browser that is Safari's behaviour and right. It is wrong when the gesture was
not theirs: an agent's `click`, or the wpt stand's, in a Savoia that is behind another app. Seen 7 October 2026: a
full `permissions-wpt.py` run stopped for ten minutes on a clipboard file with the menu over Terminal, and Artem
had to press it. In the dev build's log there is nothing; a sample of the main thread shows the frame.

## What WebKit offers, checked against the binary

- `-[WKWebView _requestDOMPasteAccessForCategory:requiresInteraction:frameID:elementRect:originIdentifier:completionHandler:]`
  — the request itself, on the view. A subclass that overrides it decides what is shown.
- `-[WKWebView _handleDOMPasteRequestWithResult:]` — answers a pending request; WebKit's own tests use it.
- `-[WKPreferences _setDOMPasteAllowed:]` — every page may read the clipboard unasked. Not that.

None of the three has been called from Savoia; the names are from the binary and the signatures from WebKit's
source, so check with `responds(to:)` first.

## To do

1. **Decide the answer when the gesture was not a person's.** The candidates: refuse without showing anything
   (what a page gets today when the menu is dismissed); or ask in the tab, as a row of the permission bar that
   names the site, which waits without stopping the app and is seen when the person comes back. The second is the
   one that fits `SitePermissions`; ask Artem before building it.
2. **Tell an agent's gesture from a person's.** `PageActions.click` and `testdriver_click` both go through
   `WKWebView.mouse(_:atViewport:)`, so a tab knows when a click was made for it; whether Savoia is the active app
   is the other half.
3. **Leave the person's own click alone**: in front, the menu at the pointer stays.
4. **The stand**: once a request can be answered without the menu, `permissions-wpt.py` should not stop on it; run
   `clipboard-apis` and compare with the baseline, and say in permissions.md what moved.

## Done when

An agent's click on a page that reads the clipboard, with Savoia behind another app, puts nothing over that app;
a full wpt run needs nobody at the keyboard; and permissions.md and the guide (both languages) say what a person
sees.
