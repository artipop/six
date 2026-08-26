# TODO

What is planned but not built. Ordered by how much it is missed, not by effort.

## Document windows and Save As

A column that holds text instead of a page, and the browser's oldest command — **Save As…** — for both kinds. Notes
and documents are useful on their own; they are also the half that [deep research](deep-research.md) is missing, which
is where the design lives.

- `TabContent` on `BrowserTab`: `.web(WebPage)` or `.document(TextDocument)`; the layout does not care which.
- Markdown source in a `TextEditor`, rendered preview through a `WebPage` — export to HTML and PDF then comes free.
- Documents in `~/Library/Application Support/six/Documents/<id>.md`, the snapshot keeping id, title and column.
- `⌘S` / **Save As…** over `NSSavePanel` (the app is not sandboxed): documents as `.md` / `.html` / `.pdf`, pages as
  `.webarchive` / `.html` / `.pdf` / `.txt`. Remember the last folder and the document's own file URL.
- Neighbour worth doing at the same time: **downloads** (`WKDownload`), which six does not handle at all yet.

## Fullscreen that keeps the strip

A page should be readable edge to edge — no gaps, no title bar, no top bar — *and* still be part of the strip: `⌥←`
`⌥→` moves to the next window and shows it the same way. niri's own `fullscreen` behaves like this; it is not the same
thing as the green button.

- Layout: a `fullscreen` flag on the focused column (or a width preset beyond `1.0`) that zeroes `outerGap` and the
  column gap, hides `WindowChrome` and the top bar, and keeps `centersFocus` doing its job.
- Moving along the strip stays one window per gesture; the next window arrives already fullscreen, so it reads like a
  slideshow of pages. `⌥F` is taken by "maximize"; `⌥⇧F` or `Esc` is the natural pair for enter/leave.
- Three different things must not be confused: this (a layout state), macOS fullscreen (the green button — the strip
  simply fills a bigger window), and a page's own `requestFullscreen` for video, which WebKit handles inside the web
  view and which must keep working while the scroll monitor is running.
- The overview should show a fullscreen column as it really is, so leaving the overview does not surprise anyone.

## Picture-in-picture

Two different features that both deserve the name:

- **Video PiP** — WebKit's own, for `<video>`: allow it in `WebPage.Configuration` and make sure the floating player
  survives its window being scrolled off screen or turned into a placeholder card (a column far from the viewport
  loses its live `WebView` today — the PiP player must not die with it).
- **Window PiP** — any window as a small always-on-top panel: an `NSPanel` at `.floating` level hosting the page,
  which leaves the strip while it floats and returns to its column when closed. This is niri's floating layer, and the
  same mechanism would later serve a proper floating-window mode.

## Smaller things

- A readable maximum width for the default column on ultra-wide displays: 88 % of a 5K panel is a very long line.
- A way back to the start page after navigating (a "home" affordance, or `⌘⇧H`).
- Downloads UI once `WKDownload` exists: where a file went, and a way to open it.
