# Content blocking

Ads and trackers are dropped by WebKit's own network layer, before a request leaves the content process. No
extension, no proxy, no script in the page: filter lists are compiled once into a `WKContentRuleList` and handed to
a page through `WebPage.Configuration.userContentController` before it loads. A blocked request never happens, and
the site's own scripts cannot see that anything did.

The whole of it is `six/Blocking/` — four files — plus a shield in every window's address field and a **Privacy**
menu.

```
FilterList          the catalogue: id, title, address, on/off
FilterListStore     an actor: fetch, cache, ETags, the converted JSON, index.json
RuleConversion      AdGuard/EasyList syntax → WebKit's JSON (SafariConverterLib)
ContentBlocker      compiles, attaches, and decides what each window gets
```

## From a filter list to a blocked request

A filter list is written in the syntax the ad-blocking world shares (`||ads.example^$third-party`,
`site.com##.banner`). WebKit does not read it; WebKit takes a JSON array of trigger/action pairs. The translation is
[SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) — AdGuard's own converter, the one behind
AdGuard for Safari — rather than a parser of six's, because the interesting part of that job is the hundred edge
cases in `$modifiers` and regular expressions, all of which someone has already met.

The catalogue points at AdGuard's **Safari** builds of its filters (`filters.adtidy.org/extension/safari/`): the
same lists with the modifiers WebKit cannot express already removed, so conversion drops far less on the floor.

| list | what it is | default |
|---|---|---|
| AdGuard Base | ads on most of the web | on |
| AdGuard Tracking Protection | trackers, analytics, beacons | on |
| AdGuard Annoyances | cookie notices, overlays, widgets | off |
| AdGuard Russian | ads on Russian-language sites | on when the system prefers Russian |

Any other list can be added by address — EasyList, a regional list, one written by hand and served from a file. The
panel is `six://settings` ▸ **Privacy** ▸ Blocking (⌘,), which the shield in the address field also opens.

What it costs, measured on this machine (M-series, 8 GB):

| | rules in | Safari rules out | convert | compile |
|---|---|---|---|---|
| AdGuard Base | 137 023 | 97 307 | 3.4 s | 5.2 s |
| AdGuard Tracking Protection | 101 339 | 101 255 | 1.6 s | 3.6 s |
| AdGuard Russian | 18 998 | 11 696 | 0.5 s | 1.0 s |

That is the *first* launch, in the background, while the browser is already usable. Afterwards WebKit keeps the
compiled rule lists in its own store and a launch is three lookups — a fraction of a millisecond each, no
conversion, no compilation, nothing read but `index.json`. A list is fetched again when it is more than
`blocking.refreshDays` old (3 by default) and on a six-hour timer while the app is up; an ETag or an unchanged hash
means nothing is recompiled. Peak memory during a compile is ~330 MB, which is why lists are compiled one after
another rather than at once.

## One content controller per window

The obvious arrangement is one `WKUserContentController` per profile, shared by every page. six does not do that,
because of the per-site allowlist.

WebKit evaluates each rule list on its own and combines what they say. An `ignore-previous-rules` action only undoes
actions from *earlier rules in the same list* — a second, smaller list saying "let this site through" does not
cancel a block from the first. (AdGuard says the same thing about its six Safari blockers: exception rules do not
reliably cross from one to another.) So the standard way to allow a site is to write the exception into every list
and compile them all again: ten seconds of work for one click on a shield.

Instead every window has a controller of its own, and `ContentBlocker` decides what is attached to it from the
address that window is showing:

- blocking off, or the site is on the allowlist → no rule lists at all;
- otherwise → every enabled list.

`BrowserTab` asks for its controller as it builds its page, and the window's navigation decider reports where it is
going *before* the request leaves (`TabNavigationDecider.onNavigate`), which is the last moment early enough to
matter; committed navigations report again, for redirects and back/forward. Turning the shield off is then a reload,
not a recompile — verified end to end: a window walked from an allowed site to a blocked one and back picks up the
right rules on every load.

A page whose window was discarded and built again gets the same controller, so nothing is re-attached and nothing is
lost.

## Off means off

The **Privacy › Block Ads and Trackers** switch is not a filter that lets everything through. With it off six
fetches nothing, converts nothing, compiles nothing and attaches nothing — someone who brings their own blocker is
not paying for ours. (Measured the same way: with the switch off the log has no blocking lines at all and every ad
request loads.)

## The shield

Every window's address field carries it, next to the lock:

- **filled** — the rules are on this page;
- **crossed out** — they are not: either the switch is off, or the site is on the allowlist.

Clicking it allows (or blocks again) every site under this one's host — `example.com` covers `www.example.com` and
`cdn.example.com` — and offers the filter list panel. The same two actions are on `six://settings` ▸ Privacy ▸ Blocking, which also has
**Update Filter Lists Now**.

## What this does not do, and why

- **No blocked counter.** `WKContentRuleList` reports nothing back: WebKit does not say which rule fired, or how
  many did. A number in the title bar would be invented, so there isn't one.
- **No scriptlets, no extended CSS.** `##+js(...)`, `:has-text()`, `:xpath()` and the rest of the advanced syntax
  cannot be expressed in WebKit's JSON at all; they need a JavaScript engine running inside every page, which is a
  feature of its own (see [todo.md](todo.md)). Plain element hiding *does* convert — WebKit has `css-display-none` —
  so the visible half of blocking is here. The converter reports what it left behind: ~12 000 advanced rules in
  AdGuard Base.
- **No anti-adblock circumvention**, which is mostly scriptlets, and follows from the same limit.
- **150 000 rules per list** is WebKit's ceiling. Nothing hits it today (the biggest list converts to ~101 000); the
  panel says so per list when something does.

## Sundries

- Lists live in `~/Library/Application Support/org.deffun.six/Blocking/`: `<id>.txt` as the publisher wrote it, `<id>.json`
  converted, `index.json` for the ETags and counts. Deleting the folder costs one re-download.
- Compiled rule lists are named `six.<list>.<hash of the source>`; when a list changes upstream the old rule list is
  found by that prefix and dropped, so a year of updates is not a year of dead rule lists in WebKit's store.
- Blocking is per window, not per profile, so a private window blocks exactly like an ordinary one.
- In a **Debug** build the converter prints a line for every rule it cannot express (a few hundred, from
  `BlockerEntryFactory`). That is SafariConverterLib's own `#if DEBUG` logging on stdout, and it is silent in
  Release.

## Extensions

Blocking needs no extension, and six has none — `WKWebExtension` is a separate piece of work with a real obstacle
in front of it (`WKWebExtensionTab` requires a `WKWebView`, which `WebPage` does not hand out). What that means and
what would still work is in [todo.md](todo.md#extensions-wkwebextension).
