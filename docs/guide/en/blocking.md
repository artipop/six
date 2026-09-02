# Ads and trackers

Blocking is on out of the box, and it is neither an extension nor a proxy: it is
WebKit itself. Filter lists are compiled once into the engine's own rules and
handed to a page before it starts loading. **A blocked request never happens**,
and the site's own scripts cannot see that anything did.

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

**Privacy ▸ Filter Lists…**

| list | what it is | default |
|---|---|---|
| AdGuard Base | ads on most of the web | on |
| AdGuard Tracking Protection | trackers, analytics, beacons | on |
| AdGuard Annoyances | cookie notices, overlays, widgets | off |
| AdGuard Russian | ads on Russian-language sites | on when the system prefers Russian |

Any other list can be added by address — EasyList, a regional one, your own. The
panel shows how many rules each has and when it was last updated; **Refresh Now**
and **Privacy ▸ Update Filter Lists Now** re-read them on demand, and otherwise
it happens by itself every three days.

::: tip The first launch is the one that costs
Compiling three lists takes seconds, in the background, while the browser is
already usable. Afterwards WebKit keeps the compiled rules and a launch is three
lookups.
:::

## Off means off

**Privacy ▸ Block Ads and Trackers** is not a filter that lets everything
through. With it off, nothing is fetched, converted, compiled or attached to a
page: somebody who brings their own blocker does not pay for ours.

## Sites left alone

The **Sites Left Alone** panel lists everything the shield has allowed and takes
it back. While it is empty it says where entries come from.

## What is not here, and why

- **A blocked counter.** The engine does not report which rule fired or how many
  did. A number in the corner would have to be invented, so there isn't one.
- **Scriptlets and extended CSS** (`##+js(...)`, `:has-text()`, `:xpath()`).
  Those need JavaScript running inside every page and cannot be expressed in
  WebKit's rules at all. Ordinary element hiding does convert and does work — the
  visible half of blocking is here.
- **Anti-adblock circumvention**, which is mostly scriptlets.

Blocking is the same in a private window as in an ordinary one.
