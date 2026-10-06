# 2. Site icons that sometimes do not load

Rework how a site's icon is fetched.

## How it works now

`Savoia/Browser/SiteIcons.swift`. On `.finished` a script goes into the page, once per host per run. It collects
`<link rel="icon">` and `apple-touch-icon`, sorts them by closeness to 64 px, adds `/favicon.ico` last, then for
each in turn does `fetch()`, draws the result into a 64×64 canvas and leaves a `data:` URL in
`window.__savoiaIcon`. Swift polls that variable 20 times at 150 ms and writes `<host>.icon`.

The page does the fetching on purpose: the request leaves from the page's own profile — its cookies, its blocking
— there is no second visit to the site from outside, and a private window fetches no icons at all. **Keep that
constraint.**

## Why icons go missing — read from the code, not measured

- `fetch()` of an icon on another domain (a CDN, the usual case) is refused by CORS, though an `<img>` would show it.
- The site's CSP: `connect-src` forbids the `fetch`, or `img-src` without `data:` forbids drawing it.
- The icon arrives after the three seconds of polling; the script stores it and nobody reads it.
- The host is marked as asked before the answer, so a failure is not retried until the next launch.
- A `<link rel=icon>` set or changed by script after the load is never seen.

Measure first which of these are real, on 20–30 sites from Artem's history — ask him for the list.

## Where to look for the answer

`WKWebView` has SPI `_iconLoadingDelegate` / `_setIconLoadingDelegate:` on this system: WebKit finds the page's
icons itself and loads them in the page's own network session, which is what Safari does. It would remove the
script altogether ([page-scripts.md](../../page-scripts.md) — fewer scripts in pages is the direction). Verify that
the delegate is called at all for a view `WebPage` owns, that the request carries the profile's cookies, and that a
private window makes none. SPI goes behind `responds(to:)`.

If the SPI does not fit, lay the options out for Artem before writing a loader (AGENTS.md: look for what exists
first).

## Done when

- On the same set of sites: "N of M had an icon before, K of M now", and a reason for each one still without.
- The script is gone, or it is written down why it stayed.
- [page-scripts.md](../../page-scripts.md) and wherever icons are described are updated.
