# Start page

A new window opens on six's own start page instead of loading somebody's home page — so the first thing a window does
isn't a network request. It is a native SwiftUI view (`six/Views/StartPage.swift`), not an HTML page: real keyboard
handling, the profile's colour, no web view to spin up.

One field takes both a query and an address, the same rule the address bar uses (`URL.fromUserInput`). The rows under
it are `AddressSuggestions` (`six/Views/AddressSuggestions.swift`), which the address bar's field shares — see
[The address field](#the-address-field) below. With nothing typed there is no list — erasing the input or `Esc` puts it away. Underneath it, once something is typed:

- an **address row** first when the input looks like one (`apple.com`, `localhost:3000`, anything with a scheme), so
  Enter opens it rather than searching for it;
- then up to three **pages you saved**: first by their letters (`BookmarkStore.suggest` — host prefix, title prefix,
  then a substring from two letters on, answering on the first key with no model loaded), then by meaning — the
  section below, which declines anything under three letters or shaped like an address;
- then up to four **pages from the profile's history** (`HistoryStore.suggest`: a host prefix or the start of a past
  query beats a title prefix beats the start of a word beats a substring; repeat visits add up, and visits decay over
  a couple of weeks) — title and host, opened directly.
  **Matched against what is read, not what is stored.** A search is kept as its results page's address,
  percent-encoded, and DuckDuckGo leaves the visit without a title — so a substring test over the raw address found
  every Latin query and not one Cyrillic one. The query is decoded out of the address (`SearchEngine.search(from:)`)
  and the address percent-decoded before anything is compared. Rows are one per page as a person counts pages
  (`HistoryStore.suggestionKey`): a search is its engine and query whatever the engine appended (`&ia=web`), and a
  page is its address without the fragment, or Telegram's web client would be a row per chat.
  A results page of any engine six knows shows as the query it was with "*Engine* Search" beside it, the way Chrome
  does, instead of the page's own title;
- then **completions** from the search engine, each labelled "*Engine* Search" so it is clear where Enter goes;
  completions already shown from history are not repeated.

Saved above visited above guessed, and that order is the argument: a page you bookmarked is one you decided to keep, a
page in history is one you happened to open, a completion is what other people are typing. Ten rows in all — the two
local sources first, and the engine's fill whatever room is left, because a list of sixteen rows under a field is not
a list any more.

`↑` `↓` walk the rows, `Tab` or `→` fills the field from the highlighted row without opening it: the full address
for a page, the query for a past search or an engine completion. The caret stays at the end so typing can continue.
With no row selected, these keys keep their usual behaviour. `Enter` opens the selected row (or the raw input when
nothing is selected), `Esc` clears the field, and a click opens a row directly.

On macOS the field is `SuggestionTextField`, an `NSTextField` whose delegate handles the field editor's commands.
SwiftUI's `onKeyPress` did not reliably receive Tab/right while editing, and arrow handling could stop after switching
applications. Keeping these commands on the native editor also keeps them working when it regains first responder.
Modified keys and IME composition stay with AppKit. The caret and text selection use the profile's colour; the field
has no extra AppKit focus ring. The standalone integration test posts keyboard events through an AppKit window,
exercises completion, caret movement, submission, and deactivation/reactivation, and compares the field's colours and
font size with the original SwiftUI field in light and dark appearances:

```sh
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  six/Views/SuggestionTextField.swift Tests/StartPageKeyboard/main.swift \
  -o /tmp/six-start-page-keyboard-test
/tmp/six-start-page-keyboard-test
```

## Your own pages first

The saved rows are `PersonalSuggestions` (`six/Browser/`) over the bookmark index — the same hybrid search the
bookmarks window and the agents' `search_bookmarks` use ([bookmarks.md](bookmarks.md)), so the query is embedded by
`multilingual-e5-small` on this Mac and put to the `vec0` table as a KNN. That is what makes it *personalised* rather
than another completion service: it is your library that answers, by meaning, across languages — «плов» finds the
English page about pilaf you saved, «ограничение частоты запросов» finds *Rate limiting*, and neither of those pages
has the query's words anywhere in it. Nothing leaves the machine to do it.

Three rules keep it out of the way:

- **It never wakes the model on its own.** With no bookmarks in scope (`ConfigurationStore.bookmarkScope` — this profile
  or all, the same setting the assistant reads) the query is dropped without being embedded, so a fresh install does
  not pull 470 MB of weights because somebody typed in the field. Once there *are* bookmarks the weights are already
  down: indexing them needed the same model. An input that looks like an address is dropped too — a host is not a
  question.
- **It waits longer than the engine does** — 240 ms rather than 140, and the query in flight is cancelled by the next
  keystroke, because here a keystroke costs a forward pass on the GPU rather than a request somebody else answers.
- **It would rather show nothing.** A KNN always answers: the nearest page is still the nearest page when nothing is
  near. So the best hit has to clear a floor — **0.83 for a single word, 0.80 for more than one** — and the rows after
  it have to be within 0.02 of the best, or nothing is shown at all. A page whose title or address literally contains
  every word of the query is let through regardless, which is what makes `swi` offer the Swift page it is a prefix of.

### The floor moves with the query, and here is why

`SIX_PERSONAL_SELFTEST="плов; руд"` on launch prints, per query, everything the index answered with its score and then
what the field would show. Against three saved pages — one of them an English Wikipedia article about pilaf — every
score below is against *that* page:

| typed | best | | typed | best |
|---|---|---|---|---|
| плов | **0.843** | | руд | 0.821 |
| рецепт | **0.841** | | рудник | 0.823 |
| pilaf | **0.907** | | рудники урала | 0.812 |
| рецепт риса с бараниной | **0.811** | | пло | 0.819 |
| ограничение частоты запросов | **0.830** | | асд | 0.813 |

The left column is what the page is about. The right column is a word about mines, a fragment of one, and three
letters mashed on the keyboard — and **«асд» scores 0.813**, between a real query about mines and a real query about a
recipe. The ranking inside a query is right every time; the number across queries carries an offset that has nothing
to do with the subject. Cyrillic anything leans toward the page whose text has Cyrillic in it; a long document has more
passages and so more chances to hold one near anything; and a query's score *falls* as words are added — «рецепт»
0.841, «рецепт риса с бараниной» 0.811, both about the page they found.

Hence two floors rather than one. A lone word is a prefix until proven otherwise — that is what somebody typing looks
like — and every fragment measured lands at 0.81–0.823 while every real single word lands at 0.84 and up, so 0.83
separates them and «руд» offers nothing. Adding words dilutes the score, so a phrase is held to 0.80 instead.

What survives: nothing at all for `руд`, `рудн`, `рудник`, `пло`, `рец`, `асд`, «квантовая гравитация», «погода в
москве завтра»; the right page and only the right page for «плов», «рецепт», `pilaf`, `swift`, `rate limiting`,
`data race`, «ограничение частоты запросов», «рецепт риса с бараниной». Two queries still miss — «рудники урала» and
«купить билеты в тбилиси» both score 0.812 against the pilaf page, which is what a true query scores, and no threshold
can separate those. That is the residue, and it is one row under a phrase somebody meant to type rather than a row
under a half-typed word.

Both numbers are measured, not reasoned, and neither travels. Re-run the self-test against a real library before
moving either.

A **private window searches nothing of yours**: the star is disabled there, no page is saved from there, and a field
that answered with your bookmarks would hand back the one thing that window was opened to leave behind.

## The field does not move

The name and the field hang from a fixed point — a third of the way down the window — rather than being centred with
the list. Centred, every row that arrived (and the engine's arrive a moment after the local ones) changed the stack's
height and moved the field upward under the caret. Only the list may grow, and it grows downward into the empty half
of the page. In a window too short to hold both, the top inset gives way first, so the last row stays on screen.

## The address field

The top bar's field (`six/Views/AddressBar.swift`) drops the same list, over the page, from its own leading edge — with
`Limits(rows: 8)`. It opens only once the text differs from what six put there (`filled`): ⌘L
selects the page's address mostly to copy it, and a list falling over the page every time would be in the way of
that. `↑` `↓` walk, `Enter` opens the selected row or navigates to the text, and `Esc` first puts the address back,
then lets go of the field. It hangs below the bar because the top bar is drawn in front of the rail (`zIndex(1)` in
`ContentView`).

## Suggestions

`SearchEngine` (`six/Browser/SearchEngine.swift`) holds both the search URL and the suggestions URL. All four engines
— DuckDuckGo, Google, Bing, Yandex — answer in the same OpenSearch shape — `["query", ["suggestion", …]]` — so one
parser serves them all. What they do not agree on is what to call the query in an address: three say `q` and Yandex
says `text`, so the name is the engine's to say, and both building a search and recognising one ask it rather than
assuming.

Switch engines from the chip on the left of the search field, or from `six://configuration` ▸ **General** ▸ Search Engine. Both
bind to `settings.searchEngine` on the observed `ConfigurationStore`, which is the `search.engine` row of the settings table
and the same value `SearchEngine.current` reads (DuckDuckGo is the default), so the choice takes effect everywhere at
once — every open start page, the address bar, and the assistant's `open_window(query:)`.

`SearchSuggestions` debounces by 140 ms and cancels the request in flight on every keystroke, so a fast typist makes
one request rather than ten, and late answers to stale queries are dropped.

**The query leaves the machine as you type** — that is what a suggestion service is. It goes out over an ephemeral
`URLSession`: no cookies, no cache, nothing tied to a profile's data store. Nothing else on the start page touches the
network.
