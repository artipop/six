# Extensions

VI can install browser extensions — from a folder, a `.zip`, a `.crx` or an
`.xpi`. **Extensions ▸ Manage Extensions…**

::: warning Read this before installing
Extensions here have a **measured boundary**: a content script runs in the page,
but it cannot message its own extension, and the extension cannot reach it. An
extension whose content script is self-contained (a stylesheet, a script carrying
its own data, anything that acts on the page and reports to nobody) works. An
extension whose content script is a client of its background — which is most of
them — does not.

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

## What does not

| | |
|---|---|
| `runtime.sendMessage` from a content script | "Tab not found" |
| `tabs.sendMessage` to a content script | silently delivers nothing |
| `scripting.executeScript`, `scripting.insertCSS` | do not run |
| `webRequest` | is not in WebKit at all |

Every failure but the last is the same failure, and it is not about VI in general
but about the way pages are drawn here.

## uBlock Origin Lite

The interesting case: it is the MV3 ad blocker, and it ships a build meant for
exactly this API. It installs, enables its rule sets, produces no errors — **and
blocks nothing**, because its logic decides per tab, and a tab is what it cannot
see here.

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
