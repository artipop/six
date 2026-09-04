# Content blocking

Ads and trackers are dropped by WebKit's own network layer, before a request leaves the content process. No
extension, no proxy, no script in the page: filter lists are compiled once into a `WKContentRuleList` and handed to
a page through `WebPage.Configuration.userContentController` before it loads. A blocked request never happens, and
the site's own scripts cannot see that anything did.

That is most of blocking but not all of it: about a seventh of a filter list cannot be said in WebKit's JSON at
all, and that part runs inside the page — see [the advanced rules](#the-advanced-rules-what-runs-inside-the-page).

The whole of it is `six/Blocking/` — five files and two JavaScript payloads — plus a shield in every window's
address field and a **Privacy** menu.

```
FilterList          the catalogue: id, title, address, on/off
FilterListStore     an actor: fetch, cache, ETags, the converted JSON and the advanced rules, index.json
RuleConversion      AdGuard/EasyList syntax → WebKit's JSON + what is left over (SafariConverterLib)
AdvancedRules       the leftovers: the lookup engine, the scriptlet compiler, the user scripts
ContentBlocker      compiles, attaches, and decides what each window gets
Payload/            blocking-cosmetic.js (extended CSS), blocking-scriptlets.js (the compiler), the versions
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

| | rules in | Safari rules out | advanced | convert | compile |
|---|---|---|---|---|---|
| AdGuard Base | 138 714 | 98 927 | 11 925 | 3.2 s | 5.2 s |
| AdGuard Tracking Protection | 101 393 | 101 306 | 543 | 1.5 s | 3.6 s |
| AdGuard Russian | 19 017 | 11 720 | 2 208 | 0.4 s | 1.0 s |

Building the advanced engine over all three — 14 676 rules — is another 1.3 s, once, after the lists convert.

That is the *first* launch, in the background, while the browser is already usable. Afterwards WebKit keeps the
compiled rule lists in its own store and a launch is three lookups — a fraction of a millisecond each, no
conversion, no compilation, nothing read but `index.json`. A list is fetched again when it is more than
`blocking.refreshDays` old (3 by default) and on a six-hour timer while the app is up; an ETag or an unchanged hash
means nothing is recompiled. Peak memory during a compile is ~330 MB, which is why lists are compiled one after
another rather than at once.

## The advanced rules: what runs inside the page

WebKit's JSON is a table of triggers and actions. It can block a request, upgrade it to HTTPS, strip a cookie
header and hide an element by CSS selector — and that is the whole vocabulary. A filter list says more than that,
and the converter hands the remainder back as `advancedRulesText` rather than dropping it:

| kind | example | why WebKit cannot |
|---|---|---|
| **scriptlets** | `example.com#%#//scriptlet('set-constant', 'adsEnabled', 'false')` | it is a program, not a rule |
| **extended CSS** | `lenta.ru#?#.box:has(> div.banner)` | `:has-text()`, `:contains()`, `:xpath()`, `:matches-css()` are not CSS |
| **CSS injection** | `habr.com#$#.tm-page.has-p-shaped { padding-top: 0 !important; }` | `css-display-none` can only hide |
| **JS rules** | `example.com#%#window.adBlock = true;` | same as scriptlets |

That is 14 676 rules across the three default lists, and it is where anti-adblock circumvention lives — which is why
that arrives with this and could not have arrived before it.

### Three pieces, and why each is where it is

**The lookup is AdGuard's own `FilterEngine`**, from the same package as the converter. Answering "which of 14 676
rules apply to this URL" is a domain index, a public-suffix comparison and a pile of `$domain`/`$path` exception
logic; it ships in the library, it is the code AdGuard's Safari extension runs, and it serialises to a binary
(`Blocking/.webext/engine.bin`) that deserialises in milliseconds instead of parsing the rules again at every
launch. Building it is a second and a third, on a detached task, and only when the rules actually changed.

**Scriptlets are compiled in the app, not in the page.** AdGuard's scriptlet library is a *compiler*:
`invoke({name, args})` hands back the source of one scriptlet, and the library is 356 KB. Running it inside every
page would mean paying that per page load; six runs it once, in a `JSContext`, and a page carries only the few
kilobytes that came out (0.1–1 ms per scriptlet, memoised by name and arguments; the whole library parses in 14 ms,
lazily, on the first page that needs one).

That has a second consequence, and it is the better one. Because the result is a string of JavaScript rather than a
library call, it can be a **`WKUserScript` at document start in the page's own world** — which means it runs *before*
the page's own scripts, the only moment at which a scriptlet that patches a global is any use, and it is out of
reach of a Content-Security-Policy that would have refused an injected `<script>` tag. A Safari web extension has to
inject a tag and live with both problems; six is the browser and does not.

**Extended CSS runs in six's own content world** (`WKContentWorld.six`), like everything else six puts in a page
([architecture.md](architecture.md#page-side-scripts)): the site cannot see the library, cannot replace the DOM
methods it matches with, and cannot find the style element by looking for one it did not create. The payload is
`blocking-cosmetic.js`, 44 KB, and it is injected only into a page that actually has extended CSS or CSS injection
to apply.

### One engine over every list

This is the one place six's blocking is *better* than WebKit's own. Rule lists are evaluated separately, so an
exception in one cannot undo a rule from another — that is the whole reason for [a controller per
window](#one-content-controller-per-window). The advanced rules of every enabled list go into a **single** engine, so
`@@||example.com^$elemhide` written in a regional list does cancel a cosmetic rule from the base list, exactly as the
filter authors intended.

### The same switch, the same allowlist

A window that gets no rule lists gets no user scripts either: the master switch and the per-site allowlist are one
decision in `ContentBlocker.apply(to:)`, taken from the address the window is about to show. User scripts are read
when a load starts, which is why they are installed from the navigation hook and why turning the shield off reloads.

Because both the blocker and the DevTools capture put user scripts into the same per-window controller, and
`WKUserContentController` can only be emptied rather than asked to drop one script, `PageControllers` keeps them
**by name** and rebuilds the list from everyone's. The blocker registers first, so its scriptlets run ahead of
anything that reads the page.

### The JavaScript payload

`six/Blocking/Payload/` holds two built files and the versions they were built from. They are committed, so building
six needs no Node; `./scripts/blocking-payload.sh` rebuilds them, and is run only when SafariConverterLib moves.

The versions are not a choice. The converter states which `@adguard/scriptlets` and `@adguard/extended-css` its
output was written for (`ContentBlockerConverterVersion`), and a scriptlet the library does not know by that name is
a rule that silently does nothing — the worst failure this feature has. So the script reads them out of the resolved
checkout, writes them beside the payload as `blocking-versions.json`, and six compares the two at launch and says so
in the log if they have drifted.

### What it does not reach

- **Main frame only.** A user script's source is fixed when it is installed, and the rules that apply to a subframe
  are the ones for the subframe's *own* address, which is not known until it loads. Handing a third-party frame the
  top document's cosmetic rules would hide things inside it for no reason, so it is given none. What blocks inside a
  frame is the network half, which is per-request and needs nobody's help.
- **A page already loaded when the engine finishes building** keeps whatever it had; the rules arrive on its next
  load. That is the same bargain the compiled rule lists make at first launch.
- **HTML filtering** (`$$`) is not in the advanced set — it needs to rewrite the response before it is parsed, which
  no `WKWebView`-shaped browser can do.
- `SIX_UI_DEBUG=1` prints a line per navigation with what the page was given: `habr.com: 5 css, 3 extended, 4
  scripts`.

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
- **No HTML filtering** (`$$`). It rewrites the response before the parser sees it, and nothing built on
  `WKWebView` can get between the two. The converter drops these; nothing else in a list is dropped for want of a
  place to run it.
- **150 000 rules per list** is WebKit's ceiling. Nothing hits it today (the biggest list converts to ~101 000); the
  panel says so per list when something does.

## Sundries

- Lists live in `~/Library/Application Support/org.deffun.six/Blocking/`: `<id>.txt` as the publisher wrote it, `<id>.json`
  converted, `<id>.adv.txt` the advanced half, `index.json` for the ETags and counts, and `.webext/` the built
  engine. Deleting the folder costs one re-download.
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
