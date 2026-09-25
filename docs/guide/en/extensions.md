# Extensions

VI can install browser extensions — from a folder, a `.zip`, a `.crx` or an
`.xpi`. **Configuration ▸ Extensions**

::: warning Read this before installing
It all comes down to one thing: WebKit could not map a page's frame back to a
tab, so a content script could neither message its own extension nor hear from
it. On the Mac that link exists now, but it has not been measured again — so the
honest word for such extensions here is "should work", not "works". On iPhone and
iPad there is no link at all.

An extension whose content script is self-contained (a stylesheet, a script
carrying its own data, anything that acts on the page and reports to nobody)
works either way.

The install dialog says this about the **particular** extension, before it runs,
and the verdict stays on its row afterwards.
:::

## What works

| | |
|---|---|
| the background page and service worker | start, `browser.*` present |
| `storage`, `alarms`, `cookies` | work |
| `tabs.query`, `tabs.onUpdated` | work: an extension sees VI's columns with their addresses and titles |
| content scripts from the manifest | **run**, the DOM is theirs |
| dynamically registered scripts | run |
| `declarativeNetRequest` | **blocks for real** — subresources and navigations alike |
| the action popup | works; its button lives in the top bar |
| an extension's settings page and its other pages | open **in a window of their own**, not as a column in the row |

## What has not been measured again

| | |
|---|---|
| `runtime.sendMessage` from a content script | should work on the Mac, not on iPhone or iPad |
| `tabs.sendMessage` to a content script | the same |
| `scripting.executeScript`, `scripting.insertCSS` | the same |

It is all one failure, and it is not about VI in general but about the way pages
are drawn here. It was measured once: "Tab not found" from a content script, and
nothing delivered back. Then WebKit got from VI what it had been missing — and
these four calls have not been measured since.

## What does not work

| | |
|---|---|
| `webRequest` | is not in WebKit at all |

## uBlock Origin Lite

The interesting case: it is the MV3 ad blocker, and it ships a build meant for
exactly this API. It installs, enables its rule sets, produces no errors — **and
blocks nothing**, because its logic decides per tab, and a tab is what it could
not see here. That was measured before the tab-to-frame link existed, and has not
been repeated since.

That is why [VI's own blocking is native](/en/blocking) and depends on no
extension. uBOL installs and shows its verdict like any other; it simply does not
block.

## The rules

- **An extension belongs to a profile**: its own storage, its own controller.
  Different profiles, different extensions.
- **Extensions do not run in a private window at all.** Private browsing is
  recorded nowhere, and an extension's storage is a record.
- **Permissions** are granted at install, where the dialog listed them; anything
  asked for later is asked separately.
- Installing or enabling an extension rebuilds the open pages: a page opened
  before it arrived would otherwise never see it.
- Extensions from the App Store cannot be adopted: they belong to their own host
  applications.
- Nothing verifies a `.crx` signature — as the install dialog says: that an
  extension was downloaded from somewhere implies nothing.
