# Ads and trackers

Blocking is on out of the box, and it is neither an extension nor a proxy: it is
WebKit itself. Filter lists are compiled once into the engine's own rules and
handed to a page before it starts loading. **A blocked request never happens**,
and the site's own scripts cannot see that anything did.

That is most of blocking but not all of it: about a seventh of a filter list
cannot be said in WebKit's rules at all, and that part [runs inside the
page](#what-runs-inside-the-page).

## The shield in the address field

Next to the lock, on every window:

| | |
|---|---|
| shield filled | the rules are on this page |
| shield crossed out | they are not: either the switch is off, or the site is on the allowlist |

A click allows ads on everything under this host — `example.com` covers
`www.example.com` and `cdn.example.com` — or blocks them again. It is a reload,
not a ten-second recompile: every window has rules of its own.

The same two actions are in the **Privacy** menu.

## The lists

**Settings ▸ Privacy ▸ Blocking**

| list | what it is | default |
|---|---|---|
| AdGuard Base | ads on most of the web | on |
| AdGuard Tracking Protection | trackers, analytics, beacons | on |
| AdGuard Annoyances | cookie notices, overlays, widgets | off |
| AdGuard Russian | ads on Russian-language sites | on when the system prefers Russian |

Any other list can be added by address — EasyList, a regional one, your own. The
panel shows how many rules each has and when it was last updated; **Refresh Now**
re-reads them on demand, and otherwise
it happens by itself every three days.

The "14,676 in the page" in the line under a list counts rules of the second
kind — the ones WebKit does not understand. They are next.

::: tip The first launch is the one that costs
Compiling three lists takes seconds, in the background, while the browser is
already usable. Afterwards WebKit keeps the compiled rules and a launch is three
lookups.
:::

## What runs inside the page

WebKit's rules are a table: block a request, upgrade it to HTTPS, strip a
header, hide an element by CSS selector. A filter list says more than that, and
six runs the remainder itself, inside the page:

| what it is | example | what it is for |
|---|---|---|
| **scriptlets** | `#%#//scriptlet('set-constant', 'adsEnabled', 'false')` | neutralise a counter or an adblock detector before the site can use it |
| **extended CSS** | `#?#.box:has(> div.banner)` | hide a block by what is *inside* it rather than by its class |
| **CSS injection** | `#$#.page { padding-top: 0 !important; }` | remove the banner and the hole it left |

That is 14,676 rules across the three default lists, and it is where
**anti-adblock circumvention** lives: sites that used to say "turn off your
blocker" now simply open.

::: tip Why this works better than an extension can
A scriptlet is only any use if it got there before the site's own scripts. An
extension has to inject a `<script>` tag into the page, which arrives late — and
on strict sites a Content-Security-Policy refuses it outright. six is the
browser: it prepares the code in advance and runs it first, ahead of everything
else on the page. Extended CSS runs in a world of its own, where the site can
see neither the library nor what it is doing.
:::

All of it obeys the same switch and the same allowlist: a shield taken off a
site takes this off too.

What is missing: the rules apply to the page itself but not to frames embedded
in it — ads inside a frame are caught by the network half of blocking.

## Off means off

**Block Ads and Trackers** is not a filter that lets everything
through. With it off, nothing is fetched, converted, compiled or attached to a
page: somebody who brings their own blocker does not pay for ours.

## Sites left alone

The **Sites Left Alone** panel lists everything the shield has allowed and takes
it back. While it is empty it says where entries come from.

## What is not here, and why

- **A blocked counter.** The engine does not report which rule fired or how many
  did. A number in the corner would have to be invented, so there isn't one.
- **HTML filtering** (`$$`). Such a rule rewrites the server's response before
  the browser parses it, and there is no getting between those two moments. It
  is the one kind of rule six throws away.

Blocking is the same in a private window as in an ordinary one.
