# Start page

A new window opens on six's own start page instead of loading somebody's home page — so the first thing a window does
isn't a network request. It is a native SwiftUI view (`six/Views/StartPage.swift`), not an HTML page: real keyboard
handling, the profile's colour, no web view to spin up.

One field takes both a query and an address, the same rule the address bar uses (`URL.fromUserInput`). Underneath it:

- an **address row** first when the input looks like one (`apple.com`, `localhost:3000`, anything with a scheme), so
  Enter opens it rather than searching for it;
- then up to four **pages from the profile's history** (`HistoryStore.suggest`: a host prefix beats a title prefix
  beats a substring; repeat visits add up, and visits decay over a couple of weeks) — title and host, opened directly;
- then **completions** from the search engine.

`↑` `↓` walk the rows, `Enter` opens the selected one (or the raw input when nothing is selected), `Esc` clears the
field, and a click opens a row directly.

## Suggestions

`SearchEngine` (`six/Browser/SearchEngine.swift`) holds both the search URL and the suggestions URL. DuckDuckGo and
Google answer in the same OpenSearch shape — `["query", ["suggestion", …]]` — so one parser serves both.

Switch engines from the chip on the left of the search field, or from **Navigate → Search Engine**. Both are
`@AppStorage` on `SearchEngine.defaultsKey`, which is the same `UserDefaults` key behind `SearchEngine.current`
(DuckDuckGo is the default), so the choice takes effect everywhere at once — every open start page, the address bar,
and the assistant's `open_window(query:)`.

`SearchSuggestions` debounces by 140 ms and cancels the request in flight on every keystroke, so a fast typist makes
one request rather than ten, and late answers to stale queries are dropped.

**The query leaves the machine as you type** — that is what a suggestion service is. It goes out over an ephemeral
`URLSession`: no cookies, no cache, nothing tied to a profile's data store. Nothing else on the start page touches the
network.
