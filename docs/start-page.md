# Start page

A new window opens on six's own start page instead of loading somebody's home page — so the first thing a window does
isn't a network request. It is a native SwiftUI view (`six/Views/StartPage.swift`), not an HTML page: real keyboard
handling, the profile's colour, no web view to spin up.

One field takes both a query and an address, the same rule the address bar uses (`URL.fromUserInput`). Underneath it:

- an **address row** first when the input looks like one (`apple.com`, `localhost:3000`, anything with a scheme), so
  Enter opens it rather than searching for it;
- then up to two **pages you saved**, matched by meaning rather than by their titles — the section below;
- then up to four **pages from the profile's history** (`HistoryStore.suggest`: a host prefix beats a title prefix
  beats a substring; repeat visits add up, and visits decay over a couple of weeks) — title and host, opened directly.
  A results page of DuckDuckGo or Google shows as the query it was with "*Engine* Search" beside it, the way Chrome
  does, instead of the page's own title;
- then **completions** from the search engine, each labelled "*Engine* Search" so it is clear where Enter goes;
  completions already shown from history are not repeated.

Saved above visited above guessed, and that order is the argument: a page you bookmarked is one you decided to keep, a
page in history is one you happened to open, a completion is what other people are typing. Ten rows in all — the two
local sources first, and the engine's fill whatever room is left, because a list of sixteen rows under a field is not
a list any more.

`↑` `↓` walk the rows, `Enter` opens the selected one (or the raw input when nothing is selected), `Esc` clears the
field, and a click opens a row directly.

## Your own pages first

The saved rows are `PersonalSuggestions` (`six/Browser/`) over the bookmark index — the same hybrid search the
bookmarks window and the agents' `search_bookmarks` use ([bookmarks.md](bookmarks.md)), so the query is embedded by
`multilingual-e5-small` on this Mac and put to the `vec0` table as a KNN. That is what makes it *personalised* rather
than another completion service: it is your library that answers, by meaning, across languages — «плов» finds the
English page about pilaf you saved, «ограничение частоты запросов» finds *Rate limiting*, and neither of those pages
has the query's words anywhere in it. Nothing leaves the machine to do it.

Three rules keep it out of the way:

- **It never wakes the model on its own.** With no bookmarks in scope (`SettingsStore.bookmarkScope` — this profile
  or all, the same setting the assistant reads) the query is dropped without being embedded, so a fresh install does
  not pull 470 MB of weights because somebody typed in the field. Once there *are* bookmarks the weights are already
  down: indexing them needed the same model. An input that looks like an address is dropped too — a host is not a
  question.
- **It waits longer than the engine does** — 240 ms rather than 140, and the query in flight is cancelled by the next
  keystroke, because here a keystroke costs a forward pass on the GPU rather than a request somebody else answers.
- **It would rather show nothing.** A KNN always answers: the nearest page is still the nearest page when nothing is
  near. So the best hit has to clear an absolute floor (0.80) and the rows after it have to be within 0.02 of the
  best, or nothing is shown at all — with a page whose title or address literally contains every word of the query
  let through regardless.

Those two numbers are measured rather than guessed, and `SIX_PERSONAL_SELFTEST="плов; rate limiting"` on launch is how
they were measured: it prints, per query, everything the index answered with its score and then what the field would
show. Against three saved pages the ranking was right for every real query — and *the score was worth nothing on its
own*: «купить билеты в тбилиси», about nothing saved, scored 0.811 against the pilaf page, exactly what «рецепт риса с
бараниной» scored against the same page. E5-small compresses similarity into a narrow band and shifts the whole band
per query, which is why the cutoff is a floor *and* a distance from the best rather than a single threshold. Re-run it
against a real library before touching either number.

A **private window searches nothing of yours**: the star is disabled there, no page is saved from there, and a field
that answered with your bookmarks would hand back the one thing that window was opened to leave behind.

## Suggestions

`SearchEngine` (`six/Browser/SearchEngine.swift`) holds both the search URL and the suggestions URL. DuckDuckGo and
Google answer in the same OpenSearch shape — `["query", ["suggestion", …]]` — so one parser serves both.

Switch engines from the chip on the left of the search field, or from `six://settings` ▸ **General** ▸ Search Engine. Both are
`@AppStorage` on `SearchEngine.defaultsKey`, which is the same `UserDefaults` key behind `SearchEngine.current`
(DuckDuckGo is the default), so the choice takes effect everywhere at once — every open start page, the address bar,
and the assistant's `open_window(query:)`.

`SearchSuggestions` debounces by 140 ms and cancels the request in flight on every keystroke, so a fast typist makes
one request rather than ten, and late answers to stale queries are dropped.

**The query leaves the machine as you type** — that is what a suggestion service is. It goes out over an ephemeral
`URLSession`: no cookies, no cache, nothing tied to a profile's data store. Nothing else on the start page touches the
network.
