# Extensions

Savoia can install browser extensions — from a folder, a `.zip`, a `.crx` or an
`.xpi`. **Configuration ▸ Extensions**

The install dialog says what will and will not work for the **particular**
extension, before it runs, and the verdict stays on its row afterwards.

## What works

| | |
|---|---|
| the background page and service worker | start, `browser.*` present |
| `storage`, `alarms`, `cookies` | work |
| `tabs.query`, `tabs.onUpdated` | work: an extension sees Savoia's tabs with their addresses and titles |
| content scripts from the manifest | **run**, the DOM is theirs |
| dynamically registered scripts | run |
| `runtime.sendMessage` from a content script, `tabs.sendMessage` to one | work, in both directions |
| `scripting.executeScript`, `scripting.insertCSS` | work |
| `declarativeNetRequest` | **blocks for real** — subresources and navigations alike |
| the action popup | works; its button lives in the top bar |
| an extension's settings page, its other pages, its new-tab page | open as tabs |

## What does not work

| | |
|---|---|
| `webRequest` | is not in WebKit at all |

## uBlock Origin Lite

The MV3 ad blocker, with a build meant for exactly this API. It installs and
**blocks**: on adblock-tester.com a profile with nothing switched on scores 43–48
of 100, and the same profile with uBOL scores 91. The count on its button is
per tab, a site switched off in it stays off after a reload, and in its complete
mode ad blocks disappear from the page.

[Savoia's own blocking](/en/blocking) scores 92 on the same page and depends on
no extension.

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
